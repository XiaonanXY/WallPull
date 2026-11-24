use crate::actions::is_archived_offline;
use crate::duplicates::compute_visual_profile;
use crate::media::{
    create_image_thumbnail_cancellable, detect_media_type, find_executable,
    is_recognized_media_path, probe_or_fallback_cancellable, try_create_video_preview_cancellable,
    try_create_video_preview_clip_cancellable,
};
use crate::models::{
    ItemPrecomputedMeta, ResolvedMediaAsset, WallpaperItem, WallpaperScanCache,
    WallpaperScanCacheProject, WallpaperScanEntry, WallpaperScanReport, WallpaperScanResult,
    WorkshopExtraMetadata, WorkshopPropertyOption, WorkshopUserProperty, clean_path_str,
    is_reparse_point, strip_verbatim_prefix,
};
use crate::pkg::extract_scene_assets_cancellable;
use crate::scene_studio::has_inspectable_2d_scene;
use crate::settings::{cache_root, locate_workshop_roots};
use rayon::prelude::*;
use regex::Regex;
use serde_json::{Map, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy)]
pub struct ScanProgressInfo<'a> {
    pub message: &'a str,
    pub phase: &'a str,
    pub current: usize,
    pub total: usize,
}

fn enrich_item_visual_profile(item: &mut WallpaperItem) {
    if item.color_bucket.is_some() && item.visual_fingerprint.is_some() {
        return;
    }
    let img_path = if Path::new(&item.preview_path).is_file() {
        Some(Path::new(&item.preview_path))
    } else if item.item_type == "image" && Path::new(&item.source_path).is_file() {
        Some(Path::new(&item.source_path))
    } else {
        None
    };
    let Some(img_path) = img_path else {
        return;
    };
    let src_opt = if Path::new(&item.source_path).is_file() {
        Some(Path::new(&item.source_path))
    } else {
        None
    };
    if let Some((bucket, fp)) = compute_visual_profile(img_path, src_opt) {
        if item.color_bucket.is_none() {
            item.color_bucket = Some(bucket);
        }
        if item.visual_fingerprint.is_none() {
            item.visual_fingerprint = Some(fp);
        }
    }
}

fn is_cancelled(cancel: Option<&AtomicBool>) -> bool {
    cancel.map(|c| c.load(Ordering::SeqCst)).unwrap_or(false)
}

fn html_tag_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"<.*?>").expect("valid html tag regex"))
}

pub fn inspect_workshop_extra(workshop_dir: &str) -> WorkshopExtraMetadata {
    if workshop_dir.trim().is_empty() {
        return WorkshopExtraMetadata::default();
    }
    let project_json = Path::new(workshop_dir).join("project.json");
    let Ok(bytes) = fs::read(&project_json) else {
        return WorkshopExtraMetadata::default();
    };
    let Ok(root) = serde_json::from_slice::<Value>(&bytes) else {
        return WorkshopExtraMetadata::default();
    };
    if !root.is_object() {
        return WorkshopExtraMetadata::default();
    }
    WorkshopExtraMetadata {
        content_rating: parse_content_rating(&root),
        tags: parse_tags(&root),
        properties: parse_properties(&root),
    }
}

pub fn rewrite_as_offline_project_json(
    src_project_json: &Path,
    dest_project_json: &Path,
    title_prefix: Option<&str>,
) -> Result<(), String> {
    let bytes =
        fs::read(src_project_json).map_err(|e| format!("读取 project.json 失败：{e}"))?;
    let mut root: Value =
        serde_json::from_slice(&bytes).map_err(|e| format!("解析 project.json 失败：{e}"))?;
    let obj = root
        .as_object_mut()
        .ok_or_else(|| "project.json 内容无效。".to_string())?;
    obj.remove("workshopid");
    obj.remove("steamworkshopid");

    if let Some(prefix) = title_prefix.filter(|p| !p.is_empty()) {
        let existing = obj
            .get("title")
            .and_then(|v| v.as_str())
            .unwrap_or("Offline Wallpaper");
        if !existing.starts_with(prefix) {
            obj.insert(
                "title".to_string(),
                Value::String(format!("{prefix}{existing}")),
            );
        }
    }

    if let Some(parent) = dest_project_json.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("无法创建目标目录：{e}"))?;
    }
    let formatted =
        serde_json::to_vec_pretty(&root).map_err(|e| format!("序列化 project.json 失败：{e}"))?;
    fs::write(dest_project_json, formatted).map_err(|e| format!("写出 project.json 失败：{e}"))
}

fn parse_content_rating(root: &Value) -> String {
    let rating = root
        .get("contentrating")
        .and_then(|v| v.as_str())
        .map(str::trim);
    let mut normalized = match rating.map(|s| s.to_ascii_lowercase()).as_deref() {
        Some("mature") => "Mature".to_string(),
        Some("questionable") => "Questionable".to_string(),
        _ => "Everyone".to_string(),
    };
    if normalized == "Everyone" {
        if let Some(sex) = root.get("ratingsex").and_then(|v| v.as_str()) {
            let trimmed = sex.trim();
            if !trimmed.is_empty() && !trimmed.eq_ignore_ascii_case("none") {
                normalized = "Questionable".to_string();
            }
        }
    }
    normalized
}

fn parse_tags(root: &Value) -> Vec<String> {
    let Some(arr) = root.get("tags").and_then(|v| v.as_array()) else {
        return Vec::new();
    };
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for v in arr {
        if let Some(s) = v.as_str().map(str::trim).filter(|s| !s.is_empty()) {
            if seen.insert(s.to_ascii_lowercase()) {
                out.push(s.to_string());
            }
        }
    }
    out
}

fn parse_properties(root: &Value) -> Vec<WorkshopUserProperty> {
    let Some(props) = root
        .get("general")
        .and_then(|g| g.get("properties"))
        .and_then(|p| p.as_object())
    else {
        return Vec::new();
    };

    let mut raw_items: Vec<(i64, i64, bool, WorkshopUserProperty)> = Vec::new();
    for (key, val) in props {
        let Some(obj) = val.as_object() else {
            continue;
        };
        let raw_type = obj
            .get("type")
            .and_then(|v| v.as_str())
            .map(|s| s.trim().to_ascii_lowercase())
            .unwrap_or_default();
        if !matches!(
            raw_type.as_str(),
            "bool" | "combo" | "slider" | "textinput" | "color"
        ) {
            continue;
        }
        let raw_text = obj.get("text").and_then(|v| v.as_str());
        let is_generic_scheme = key.eq_ignore_ascii_case("schemecolor")
            && raw_text
                .map(|t| t.eq_ignore_ascii_case("ui_browse_properties_scheme_color"))
                .unwrap_or(false);
        let clean_label = if is_generic_scheme {
            "主题配色".to_string()
        } else {
            clean_label(raw_text, key)
        };
        let default_value = obj.get("value").cloned().unwrap_or(Value::Null);
        let options = parse_options(obj);
        let min = obj.get("min").and_then(|v| v.as_f64());
        let max = obj.get("max").and_then(|v| v.as_f64());
        let order = obj.get("order").and_then(|v| v.as_i64()).unwrap_or(1000);
        let index = obj.get("index").and_then(|v| v.as_i64()).unwrap_or(1000);

        raw_items.push((
            order,
            index,
            is_generic_scheme,
            WorkshopUserProperty {
                key: key.clone(),
                label: clean_label,
                prop_type: raw_type,
                default_value,
                options,
                min,
                max,
            },
        ));
    }

    let has_custom = raw_items.iter().any(|item| !item.2);
    raw_items.retain(|item| !(has_custom && item.2));
    raw_items.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
    raw_items.into_iter().map(|t| t.3).collect()
}

fn parse_options(prop_obj: &Map<String, Value>) -> Vec<WorkshopPropertyOption> {
    let Some(opts) = prop_obj.get("options").and_then(|v| v.as_array()) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for opt in opts {
        let Some(obj) = opt.as_object() else {
            continue;
        };
        let Some(val_el) = obj.get("value") else {
            continue;
        };
        let val_str = match val_el.as_str() {
            Some(s) => s.to_string(),
            None => val_el.to_string(),
        };
        let label = obj
            .get("label")
            .and_then(|v| v.as_str())
            .map(|raw| clean_label(Some(raw), &val_str))
            .unwrap_or_else(|| val_str.clone());
        out.push(WorkshopPropertyOption {
            label,
            value: val_str,
        });
    }
    out
}

fn clean_label(text: Option<&str>, fallback: &str) -> String {
    let Some(t) = text else {
        return fallback.to_string();
    };
    let stripped = html_tag_regex().replace_all(t, "");
    let trimmed = stripped.trim();
    if trimmed.is_empty() {
        fallback.to_string()
    } else {
        trimmed.to_string()
    }
}

pub fn get_official_titles(workshop_ids: &[String], fetch_online: bool) -> HashMap<String, String> {
    let titles_path = cache_root().join("workshop-titles.json");
    let mut cached: HashMap<String, String> = fs::read(&titles_path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default();

    if !fetch_online || workshop_ids.is_empty() {
        return cached;
    }

    let mut seen = HashSet::new();
    let uncached: Vec<String> = workshop_ids
        .iter()
        .filter(|id| !id.is_empty() && id.chars().all(|c| c.is_ascii_digit()))
        .filter(|id| !cached.contains_key(*id))
        .filter(|id| seen.insert((*id).clone()))
        .cloned()
        .collect();

    if uncached.is_empty() {
        return cached;
    }

    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(6))
        .build();

    let mut updated = false;
    for chunk in uncached.chunks(100) {
        let mut form: Vec<(String, String)> = Vec::with_capacity(1 + chunk.len());
        form.push(("itemcount".to_string(), chunk.len().to_string()));
        for (i, id) in chunk.iter().enumerate() {
            form.push((format!("publishedfileids[{i}]"), id.clone()));
        }
        let form_refs: Vec<(&str, &str)> = form
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        let Ok(resp) = agent
            .post("https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")
            .send_form(&form_refs)
        else {
            continue;
        };
        let Ok(doc) = resp.into_json::<Value>() else {
            continue;
        };
        let Some(details) = doc
            .get("response")
            .and_then(|r| r.get("publishedfiledetails"))
            .and_then(|d| d.as_array())
        else {
            continue;
        };
        for detail in details {
            let id = detail.get("publishedfileid").and_then(|v| v.as_str());
            let title = detail.get("title").and_then(|v| v.as_str());
            if let (Some(id), Some(title)) = (id, title) {
                let t = title.trim();
                if !id.trim().is_empty() && !t.is_empty() {
                    cached.insert(id.to_string(), t.to_string());
                    updated = true;
                }
            }
        }
    }

    if updated {
        if let Some(dir) = titles_path.parent() {
            let _ = fs::create_dir_all(dir);
        }
        if let Ok(bytes) = serde_json::to_vec_pretty(&cached) {
            let _ = fs::write(&titles_path, bytes);
        }
    }
    cached
}

pub fn compute_items_meta(
    items: &[WallpaperItem],
    export_dir: &str,
) -> HashMap<String, ItemPrecomputedMeta> {
    let mut unique_dirs: Vec<(String, WallpaperItem)> = Vec::new();
    let mut seen = HashSet::new();
    for item in items {
        let key = item.workshop_directory.to_ascii_lowercase();
        if !key.is_empty() && seen.insert(key) {
            unique_dirs.push((item.workshop_directory.clone(), item.clone()));
        }
    }

    unique_dirs
        .into_par_iter()
        .map(|(dir, sample)| {
            let has_scene_layers = items
                .iter()
                .any(|i| i.workshop_directory.eq_ignore_ascii_case(&dir) && i.item_type == "image")
                && has_inspectable_2d_scene(&dir);
            let extra = inspect_workshop_extra(&dir);
            let archived = is_archived_offline(&sample, export_dir);
            (
                dir.to_ascii_lowercase(),
                ItemPrecomputedMeta {
                    has_scene_layers,
                    is_archived_offline: archived,
                    extra,
                },
            )
        })
        .collect()
}

fn sanitize_item_paths(item: &mut WallpaperItem) {
    item.preview_path = strip_verbatim_prefix(&item.preview_path);
    item.source_path = strip_verbatim_prefix(&item.source_path);
    item.workshop_directory = strip_verbatim_prefix(&item.workshop_directory);
    item.preview_video_path = item
        .preview_video_path
        .as_deref()
        .map(strip_verbatim_prefix);
    item.asset_paths = item
        .asset_paths
        .take()
        .map(|v| v.into_iter().map(|s| strip_verbatim_prefix(&s)).collect());
    item.audio_paths = item
        .audio_paths
        .take()
        .map(|v| v.into_iter().map(|s| strip_verbatim_prefix(&s)).collect());
}

#[allow(clippy::too_many_arguments)]
pub fn scan_wallpapers<FProgress, FBatch>(
    workshop_roots: &[String],
    parse_scenes: bool,
    force_rescan: bool,
    fetch_online_titles: bool,
    use_hw_decode: bool,
    cache_path_override: Option<&Path>,
    cancel: Option<&AtomicBool>,
    on_progress: FProgress,
    on_batch: FBatch,
) -> WallpaperScanResult
where
    FProgress: Fn(&str) + Sync,
    FBatch: Fn(&[WallpaperItem]) + Sync,
{
    scan_wallpapers_with_progress(
        workshop_roots,
        parse_scenes,
        force_rescan,
        fetch_online_titles,
        use_hw_decode,
        cache_path_override,
        cancel,
        |info| on_progress(info.message),
        on_batch,
    )
}

#[allow(clippy::too_many_arguments)]
pub fn scan_wallpapers_with_progress<FProgress, FBatch>(
    workshop_roots: &[String],
    parse_scenes: bool,
    force_rescan: bool,
    fetch_online_titles: bool,
    use_hw_decode: bool,
    cache_path_override: Option<&Path>,
    cancel: Option<&AtomicBool>,
    on_progress: FProgress,
    on_batch: FBatch,
) -> WallpaperScanResult
where
    FProgress: Fn(ScanProgressInfo<'_>) + Sync,
    FBatch: Fn(&[WallpaperItem]) + Sync,
{
    let catalog_path = cache_path_override
        .map(PathBuf::from)
        .unwrap_or_else(|| cache_root().join("wallpaper-catalog.json"));

    let roots = if workshop_roots.is_empty() {
        locate_workshop_roots(None)
    } else {
        workshop_roots.to_vec()
    };

    let scan_cache: WallpaperScanCache = fs::read(&catalog_path)
        .ok()
        .and_then(|b| serde_json::from_slice::<WallpaperScanCache>(&b).ok())
        .filter(|c| c.version == 5 || c.version == WallpaperScanCache::CURRENT_VERSION)
        .unwrap_or_else(WallpaperScanCache::empty);

    let mut cached_map: HashMap<String, WallpaperScanCacheProject> = HashMap::new();
    for mut p in scan_cache.projects {
        p.project_directory = strip_verbatim_prefix(&p.project_directory);
        for it in &mut p.items {
            sanitize_item_paths(it);
        }
        let key = normalize_project_key(&p.project_directory);
        if !key.is_empty() {
            cached_map.insert(key, p);
        }
    }

    let ffmpeg_path = find_executable("ffmpeg.exe");
    let ffprobe_path = find_executable("ffprobe.exe");
    let has_ffmpeg = ffmpeg_path.is_some() && ffprobe_path.is_some();

    let mut discovered_projects = 0usize;
    let mut items: Vec<WallpaperItem> = Vec::new();
    let mut entries: Vec<WallpaperScanEntry> = Vec::new();
    let mut live_projects: HashMap<String, (String, String)> = HashMap::new();
    let mut pending: Vec<(String, String, String)> = Vec::new();
    let mut freshly_parsed_ids: HashSet<String> = HashSet::new();
    let mut reused_batch_buf: Vec<WallpaperItem> = Vec::with_capacity(200);
    let mut backfill_indices: Vec<usize> = Vec::new();

    for root in &roots {
        let Ok(dir_entries) = fs::read_dir(root) else {
            entries.push(WallpaperScanEntry {
                workshop_id: Path::new(root)
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("workshop")
                    .to_string(),
                title: root.clone(),
                state: "failed".to_string(),
                message: format!("无法读取创意工坊目录：{root}"),
                item_count: 0,
            });
            continue;
        };

        for entry in dir_entries.flatten() {
            if is_cancelled(cancel) {
                break;
            }
            let p = entry.path();
            if !p.is_dir() {
                continue;
            }
            let Some(ws_id) = p.file_name().and_then(|n| n.to_str()).map(ToString::to_string)
            else {
                continue;
            };
            if ws_id.is_empty() || !ws_id.chars().all(|c| c.is_ascii_digit()) {
                continue;
            }
            discovered_projects += 1;
            let p_str = clean_path_str(&p);
            let key = normalize_project_key(&p_str);
            live_projects.insert(key.clone(), (ws_id.clone(), p_str.clone()));

            if !force_rescan {
                if let Some(cached) = cached_map.get(&key) {
                    if can_reuse_cached(cached, &ws_id, has_ffmpeg) {
                        if !cached.items.is_empty() && !is_cancelled(cancel) {
                            for it in &cached.items {
                                let idx = items.len();
                                if it.color_bucket.is_none() || it.visual_fingerprint.is_none() {
                                    backfill_indices.push(idx);
                                }
                                items.push(it.clone());
                                reused_batch_buf.push(it.clone());
                            }
                            if reused_batch_buf.len() >= 200 {
                                on_batch(&reused_batch_buf);
                                reused_batch_buf.clear();
                            }
                        }
                        let mut reused_entry = cached.entry.clone();
                        reused_entry.state = if reused_entry.state == "warning" {
                            "warning".to_string()
                        } else {
                            "success".to_string()
                        };
                        reused_entry.message = "已复用上次解析结果".to_string();
                        reused_entry.item_count = cached.items.len();
                        entries.push(reused_entry);
                        continue;
                    }
                }
            }
            pending.push((ws_id, p_str, key));
        }
    }

    if !reused_batch_buf.is_empty() && !is_cancelled(cancel) {
        on_batch(&reused_batch_buf);
        reused_batch_buf.clear();
    }

    let worker_threads = std::thread::available_parallelism()
        .map(|n| (n.get() / 2).clamp(4, 8))
        .unwrap_or(4);
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(worker_threads)
        .build()
        .ok();

    if !backfill_indices.is_empty() && !is_cancelled(cancel) {
        let total = backfill_indices.len();
        on_progress(ScanProgressInfo {
            message: &format!("正在构建色彩光谱与视觉指纹 (0 / {total})…"),
            phase: "color-index",
            current: 0,
            total,
        });
        let done_counter = AtomicUsize::new(0);
        let last_emit = Mutex::new(Instant::now());
        let snapshots: Vec<(usize, WallpaperItem)> = backfill_indices
            .iter()
            .map(|&idx| (idx, items[idx].clone()))
            .collect();

        let run_backfill = || {
            snapshots
                .into_par_iter()
                .filter_map(|(idx, mut it)| {
                    if is_cancelled(cancel) {
                        return None;
                    }
                    enrich_item_visual_profile(&mut it);
                    let done = done_counter.fetch_add(1, Ordering::SeqCst) + 1;
                    let should_emit = done == total
                        || last_emit
                            .lock()
                            .map(|mut t| {
                                if t.elapsed() >= Duration::from_millis(60) {
                                    *t = Instant::now();
                                    true
                                } else {
                                    false
                                }
                            })
                            .unwrap_or(false);
                    if should_emit {
                        on_progress(ScanProgressInfo {
                            message: &format!("正在构建色彩光谱与视觉指纹 ({done} / {total})…"),
                            phase: "color-index",
                            current: done,
                            total,
                        });
                    }
                    Some((idx, it))
                })
                .collect::<Vec<_>>()
        };

        let enriched = match &pool {
            Some(p) => p.install(run_backfill),
            None => run_backfill(),
        };
        if !is_cancelled(cancel) {
            let mut updated_batch = Vec::with_capacity(enriched.len());
            for (idx, it) in enriched {
                items[idx] = it.clone();
                updated_batch.push(it);
            }
            for chunk in updated_batch.chunks(200) {
                on_batch(chunk);
            }
        }
    }

    if !pending.is_empty() && !is_cancelled(cancel) {
        let total = pending.len();
        on_progress(ScanProgressInfo {
            message: &format!("正在解析壁纸 (0 / {total})…"),
            phase: "scan",
            current: 0,
            total,
        });
        let done_counter = AtomicUsize::new(0);
        let last_emit = Mutex::new(Instant::now());
        let pending_batch_buf: Mutex<Vec<WallpaperItem>> = Mutex::new(Vec::with_capacity(24));

        let run_pending = || {
            pending
                .par_iter()
                .filter_map(|(ws_id, proj_dir, _key)| {
                    if is_cancelled(cancel) {
                        return None;
                    }
                    let (parsed_items, entry) = try_read_project(
                        ws_id,
                        Path::new(proj_dir),
                        parse_scenes,
                        ffmpeg_path.as_deref(),
                        ffprobe_path.as_deref(),
                        use_hw_decode,
                        cancel,
                    );
                    if is_cancelled(cancel) {
                        return None;
                    }
                    if !parsed_items.is_empty() {
                        let flush_chunk = pending_batch_buf.lock().ok().and_then(|mut buf| {
                            buf.extend(parsed_items.iter().cloned());
                            if buf.len() >= 16 {
                                Some(std::mem::take(&mut *buf))
                            } else {
                                None
                            }
                        });
                        if let Some(chunk) = flush_chunk {
                            on_batch(&chunk);
                        }
                    }
                    let done = done_counter.fetch_add(1, Ordering::SeqCst) + 1;
                    let should_emit = done == total
                        || last_emit
                            .lock()
                            .map(|mut t| {
                                if t.elapsed() >= Duration::from_millis(60) {
                                    *t = Instant::now();
                                    true
                                } else {
                                    false
                                }
                            })
                            .unwrap_or(false);
                    if should_emit {
                        on_progress(ScanProgressInfo {
                            message: &format!("正在解析壁纸 ({done} / {total})…"),
                            phase: "scan",
                            current: done,
                            total,
                        });
                    }
                    Some((ws_id.clone(), parsed_items, entry))
                })
                .collect::<Vec<_>>()
        };

        let outcomes = match &pool {
            Some(p) => p.install(run_pending),
            None => run_pending(),
        };

        if let Ok(mut buf) = pending_batch_buf.lock() {
            if !buf.is_empty() && !is_cancelled(cancel) {
                on_batch(&buf);
                buf.clear();
            }
        }

        for (ws_id, parsed_items, entry) in outcomes {
            if !parsed_items.is_empty() && matches!(entry.state.as_str(), "success" | "warning") {
                freshly_parsed_ids.insert(ws_id);
            }
            items.extend(parsed_items);
            entries.push(entry);
        }
    }

    if !is_cancelled(cancel)
        && fetch_online_titles
        && !freshly_parsed_ids.is_empty()
        && !items.is_empty()
    {
        let ids: Vec<String> = freshly_parsed_ids.iter().cloned().collect();
        let official_titles = get_official_titles(&ids, true);
        for item in &mut items {
            if freshly_parsed_ids.contains(&item.workshop_id) {
                if let Some(t) = official_titles.get(&item.workshop_id) {
                    if !t.trim().is_empty() {
                        item.title = t.trim().to_string();
                    }
                }
            }
        }
    }

    let mut title_by_ws: HashMap<String, String> = HashMap::new();
    for item in &items {
        title_by_ws
            .entry(item.workshop_id.clone())
            .or_insert_with(|| item.title.clone());
    }
    for entry in &mut entries {
        if let Some(t) = title_by_ws.get(&entry.workshop_id) {
            entry.title = t.clone();
        }
    }

    items.sort_by(|a, b| {
        a.title
            .to_lowercase()
            .cmp(&b.title.to_lowercase())
            .then_with(|| a.id.cmp(&b.id))
    });

    entries.sort_by(|a, b| {
        let rank = |s: &str| match s {
            "failed" => 0,
            "warning" => 1,
            _ => 2,
        };
        rank(&a.state)
            .cmp(&rank(&b.state))
            .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
    });

    let successful = entries
        .iter()
        .filter(|e| matches!(e.state.as_str(), "success" | "warning"))
        .count();
    let failed = entries.iter().filter(|e| e.state == "failed").count();
    let skipped = entries.iter().filter(|e| e.state == "skipped").count();

    let report = WallpaperScanReport {
        discovered_projects,
        successful_projects: successful,
        failed_projects: failed,
        skipped_projects: skipped,
        entries: entries.clone(),
    };

    if !is_cancelled(cancel) {
        try_save_catalog(&items, &entries, &live_projects, &catalog_path);
    }
    WallpaperScanResult { items, report }
}

fn try_read_project(
    workshop_id: &str,
    project_dir: &Path,
    parse_scenes: bool,
    ffmpeg: Option<&Path>,
    ffprobe: Option<&Path>,
    use_hw_decode: bool,
    cancel: Option<&AtomicBool>,
) -> (Vec<WallpaperItem>, WallpaperScanEntry) {
    let project_file = project_dir.join("project.json");
    if !project_file.is_file() {
        return (
            Vec::new(),
            WallpaperScanEntry {
                workshop_id: workshop_id.to_string(),
                title: format!("创意工坊项目 {workshop_id}"),
                state: "failed".to_string(),
                message: "缺少 project.json".to_string(),
                item_count: 0,
            },
        );
    }

    let Ok(bytes) = fs::read(&project_file) else {
        return (
            Vec::new(),
            WallpaperScanEntry {
                workshop_id: workshop_id.to_string(),
                title: format!("创意工坊项目 {workshop_id}"),
                state: "failed".to_string(),
                message: "读取 project.json 失败".to_string(),
                item_count: 0,
            },
        );
    };
    let Ok(root) = serde_json::from_slice::<Value>(&bytes) else {
        return (
            Vec::new(),
            WallpaperScanEntry {
                workshop_id: workshop_id.to_string(),
                title: format!("创意工坊项目 {workshop_id}"),
                state: "failed".to_string(),
                message: "project.json JSON 格式损坏".to_string(),
                item_count: 0,
            },
        );
    };

    let original_type = root
        .get("type")
        .and_then(|v| v.as_str())
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_else(|| "unknown".to_string());
    let title = root
        .get("title")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToString::to_string)
        .unwrap_or_else(|| format!("创意工坊项目 {workshop_id}"));

    let preview_path = find_preview(project_dir);
    let folder_size = crate::settings::calculate_directory_bytes(project_dir) as i64;
    let loose_audio = discover_project_audio(project_dir);

    let rel_source = root.get("file").and_then(|v| v.as_str());
    let source_path = rel_source
        .and_then(|rel| resolve_existing_file(project_dir, rel))
        .or_else(|| find_primary_source(project_dir, &original_type));

    let Some(source_path) = source_path else {
        return (
            Vec::new(),
            WallpaperScanEntry {
                workshop_id: workshop_id.to_string(),
                title,
                state: "failed".to_string(),
                message: "没有找到可解析的原图、原视频或场景包".to_string(),
                item_count: 0,
            },
        );
    };

    let detected_type = detect_media_type(&source_path);
    let is_scene = detected_type.is_none()
        && (original_type == "scene"
            || source_path
                .extension()
                .and_then(|e| e.to_str())
                .map(|e| e.eq_ignore_ascii_case("pkg"))
                .unwrap_or(false));

    if is_scene {
        if !parse_scenes {
            return (
                Vec::new(),
                WallpaperScanEntry {
                    workshop_id: workshop_id.to_string(),
                    title,
                    state: "skipped".to_string(),
                    message: "场景解析已跳过".to_string(),
                    item_count: 0,
                },
            );
        }

        let fallback_prev = preview_path.as_deref().unwrap_or(&source_path);
        let assets = extract_scene_assets_cancellable(
            workshop_id,
            &source_path,
            fallback_prev,
            ffmpeg,
            ffprobe,
            use_hw_decode,
            cancel,
        );
        if assets.is_empty() {
            return (
                Vec::new(),
                WallpaperScanEntry {
                    workshop_id: workshop_id.to_string(),
                    title,
                    state: "skipped".to_string(),
                    message: "场景包含过多图层或没有可确定的主画面，未强行猜测".to_string(),
                    item_count: 0,
                },
            );
        }

        let count = assets.len();
        let mut resolved_items = Vec::with_capacity(count);
        let mut gen_scene_preview = false;

        for (index, mut asset) in assets.into_iter().enumerate() {
            let verified_type = detect_media_type(Path::new(&asset.source_path))
                .map(ToString::to_string)
                .unwrap_or_else(|| asset.media_type.clone());
            asset.media_type = verified_type.clone();
            let mut has_prev = is_image_preview(Path::new(&asset.preview_path));

            if verified_type == "video" {
                if let Some(gp) = try_create_video_preview_cancellable(
                    Path::new(&asset.source_path),
                    &format!("{workshop_id}-scene-video-{}", index + 1),
                    ffmpeg,
                    use_hw_decode,
                    cancel,
                ) {
                    asset.preview_path = gp;
                    has_prev = true;
                    gen_scene_preview = true;
                }
            }
            if verified_type == "image" {
                if let Some(thumb) = create_image_thumbnail_cancellable(
                    Path::new(&asset.source_path),
                    &format!("{workshop_id}-scene-img-{}", index + 1),
                    ffmpeg,
                    cancel,
                ) {
                    asset.preview_path = thumb;
                    has_prev = true;
                }
            }
            if verified_type == "video"
                && asset
                    .preview_video_path
                    .as_deref()
                    .map(|s| s.is_empty())
                    .unwrap_or(true)
            {
                asset.preview_video_path = try_create_video_preview_clip_cancellable(
                    Path::new(&asset.source_path),
                    &format!("{workshop_id}-scene-video-{}", index + 1),
                    ffmpeg,
                    use_hw_decode,
                    cancel,
                );
            }

            let merged_audio = merge_audio_paths(asset.audio_paths.take(), &loose_audio);
            resolved_items.push(to_wallpaper_item(
                workshop_id,
                &title,
                &original_type,
                project_dir,
                asset,
                count,
                index,
                has_prev,
                folder_size,
                merged_audio,
            ));
        }

        let msg = if preview_path.is_none() {
            "已从场景包解析原始媒体；项目本身没有预览图"
        } else if gen_scene_preview {
            "已从场景包解析原始媒体，并从原视频生成清晰首帧预览"
        } else {
            "已从场景包解析原始媒体"
        };
        return (
            resolved_items,
            WallpaperScanEntry {
                workshop_id: workshop_id.to_string(),
                title,
                state: "success".to_string(),
                message: msg.to_string(),
                item_count: count,
            },
        );
    }

    let Some(effective_type) = detected_type else {
        return (
            Vec::new(),
            WallpaperScanEntry {
                workshop_id: workshop_id.to_string(),
                title,
                state: "failed".to_string(),
                message: "原文件不是可识别的图片或视频".to_string(),
                item_count: 0,
            },
        );
    };

    let media_info = probe_or_fallback_cancellable(&source_path, ffprobe, cancel);
    let src_str = clean_path_str(&source_path);
    let mut gen_video_preview = false;
    let mut resolved_preview = if effective_type == "image" {
        Some(src_str.clone())
    } else if let Some(gp) = try_create_video_preview_cancellable(
        &source_path,
        &format!("{workshop_id}-direct-video"),
        ffmpeg,
        use_hw_decode,
        cancel,
    ) {
        gen_video_preview = true;
        Some(gp)
    } else {
        preview_path
            .as_ref()
            .filter(|p| is_image_preview(p))
            .map(|p| clean_path_str(p))
    };

    if effective_type == "image" {
        if let Some(thumb) = create_image_thumbnail_cancellable(
            &source_path,
            &format!("{workshop_id}-direct-img"),
            ffmpeg,
            cancel,
        ) {
            resolved_preview = Some(thumb);
        }
    }

    let has_preview = effective_type == "image" || resolved_preview.is_some();
    let final_preview = resolved_preview.unwrap_or_else(|| src_str.clone());
    let preview_clip = if effective_type == "video" {
        try_create_video_preview_clip_cancellable(
            &source_path,
            &format!("{workshop_id}-direct-video"),
            ffmpeg,
            use_hw_decode,
            cancel,
        )
    } else {
        None
    };

    let item = to_wallpaper_item(
        workshop_id,
        &title,
        &original_type,
        project_dir,
        ResolvedMediaAsset {
            media_type: effective_type.to_string(),
            source_path: src_str.clone(),
            preview_path: final_preview,
            media_info,
            asset_paths: vec![src_str],
            preview_video_path: preview_clip,
            audio_paths: None,
        },
        1,
        0,
        has_preview,
        folder_size,
        merge_audio_paths(None, &loose_audio),
    );

    let mut notes = Vec::new();
    if matches!(original_type.as_str(), "image" | "video")
        && !original_type.eq_ignore_ascii_case(effective_type)
    {
        notes.push(format!(
            "资料写的是{}，实际文件是{}，已自动纠正",
            if original_type == "video" {
                "视频"
            } else {
                "图片"
            },
            if effective_type == "video" {
                "视频"
            } else {
                "图片"
            }
        ));
    }
    if preview_path.is_none() {
        notes.push(if gen_video_preview {
            "没有 preview 文件，已从原视频生成本地首帧预览".to_string()
        } else {
            "没有 preview 文件，已保留原始媒体".to_string()
        });
    } else if gen_video_preview {
        notes.push("已从原视频生成清晰首帧预览".to_string());
    }

    let state = if notes.is_empty() {
        "success"
    } else {
        "warning"
    };
    let msg = if notes.is_empty() {
        "解析成功".to_string()
    } else {
        notes.join("；")
    };

    (
        vec![item],
        WallpaperScanEntry {
            workshop_id: workshop_id.to_string(),
            title,
            state: state.to_string(),
            message: msg,
            item_count: 1,
        },
    )
}

#[allow(clippy::too_many_arguments)]
fn to_wallpaper_item(
    workshop_id: &str,
    title: &str,
    original_type: &str,
    project_dir: &Path,
    asset: ResolvedMediaAsset,
    asset_count: usize,
    index: usize,
    has_preview: bool,
    folder_size: i64,
    audio_paths: Option<Vec<String>>,
) -> WallpaperItem {
    let id = if asset_count == 1 {
        workshop_id.to_string()
    } else {
        format!("{workshop_id}:{}:{}", asset.media_type, index + 1)
    };
    let mut item = WallpaperItem {
        id,
        workshop_id: workshop_id.to_string(),
        title: title.to_string(),
        item_type: asset.media_type,
        preview_path: strip_verbatim_prefix(&asset.preview_path),
        source_path: strip_verbatim_prefix(&asset.source_path),
        workshop_directory: clean_path_str(project_dir),
        original_type: original_type.to_string(),
        resolution: asset.media_info.resolution(),
        duration: asset.media_info.duration_seconds.map(format_duration),
        file_size: asset.media_info.file_size,
        asset_paths: Some(
            asset
                .asset_paths
                .into_iter()
                .map(|s| strip_verbatim_prefix(&s))
                .collect(),
        ),
        has_preview,
        preview_video_path: asset
            .preview_video_path
            .as_deref()
            .map(strip_verbatim_prefix),
        folder_size,
        audio_paths: audio_paths.map(|v| v.into_iter().map(|s| strip_verbatim_prefix(&s)).collect()),
        color_bucket: None,
        visual_fingerprint: None,
    };
    enrich_item_visual_profile(&mut item);
    item
}

fn format_duration(seconds: f64) -> String {
    let total = seconds.round().max(0.0) as u64;
    let hrs = total / 3600;
    let mins = (total % 3600) / 60;
    let secs = total % 60;
    if hrs > 0 {
        format!("{hrs}:{mins:02}:{secs:02}")
    } else {
        format!("{mins}:{secs:02}")
    }
}

fn find_preview(project_dir: &Path) -> Option<PathBuf> {
    let mut matches = Vec::new();
    let entries = fs::read_dir(project_dir).ok()?;
    for entry in entries.flatten() {
        let p = entry.path();
        if !p.is_file() {
            continue;
        }
        let Some(name) = p.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if !name.to_ascii_lowercase().starts_with("preview.") {
            continue;
        }
        let ext = p
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| e.to_ascii_lowercase());
        if matches!(
            ext.as_deref(),
            Some("jpg" | "jpeg" | "png" | "webp" | "gif")
        ) {
            if let Some(resolved) = resolve_existing_file(project_dir, name) {
                matches.push(resolved);
            }
        }
    }
    matches.sort_by_key(|a| a.to_string_lossy().to_ascii_lowercase());
    matches.into_iter().next()
}

fn find_primary_source(project_dir: &Path, original_type: &str) -> Option<PathBuf> {
    if original_type == "scene" {
        if let Some(scene) = resolve_existing_file(project_dir, "scene.pkg") {
            return Some(scene);
        }
    }
    let entries = fs::read_dir(project_dir).ok()?;
    let mut best: Option<(u64, PathBuf)> = None;
    for entry in entries.flatten() {
        let p = entry.path();
        if !p.is_file() {
            continue;
        }
        let name = p
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if name.starts_with("preview.") || !is_recognized_media_path(&p) {
            continue;
        }
        let len = entry.metadata().map(|m| m.len()).unwrap_or(0);
        if best.as_ref().map(|b| len > b.0).unwrap_or(true) {
            best = Some((len, p));
        }
    }
    best.map(|b| PathBuf::from(clean_path_str(&b.1)))
}

pub fn resolve_existing_file(root_dir: &Path, relative_path: &str) -> Option<PathBuf> {
    let trimmed = relative_path.trim();
    if trimmed.is_empty() || Path::new(trimmed).is_absolute() {
        return None;
    }
    let root_canon = fs::canonicalize(root_dir).ok()?;
    let rel_norm = trimmed.replace(['/', '\\'], std::path::MAIN_SEPARATOR_STR);
    let cand = fs::canonicalize(root_canon.join(rel_norm)).ok()?;
    if cand.starts_with(&root_canon) && cand.is_file() {
        Some(PathBuf::from(strip_verbatim_prefix(&cand.to_string_lossy())))
    } else {
        None
    }
}

fn discover_project_audio(project_dir: &Path) -> Vec<String> {
    let mut list: Vec<(u64, String)> = Vec::new();
    let mut stack = vec![(project_dir.to_path_buf(), 0u32)];
    while let Some((dir, depth)) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let p = entry.path();
            if is_reparse_point(&p) {
                continue;
            }
            let Ok(meta) = fs::symlink_metadata(&p) else {
                continue;
            };
            if meta.is_dir() {
                if depth < 12 {
                    stack.push((p, depth + 1));
                }
            } else if meta.is_file() {
                let ext = p
                    .extension()
                    .and_then(|e| e.to_str())
                    .map(|e| e.to_ascii_lowercase());
                if matches!(ext.as_deref(), Some("mp3" | "ogg" | "wav" | "flac" | "m4a")) {
                    let len = meta.len();
                    if len >= 64 * 1024 {
                        list.push((len, clean_path_str(&p)));
                    }
                }
            }
        }
    }
    list.sort_by(|a, b| b.0.cmp(&a.0));
    list.into_iter().take(6).map(|(_, p)| p).collect()
}

fn merge_audio_paths(extracted: Option<Vec<String>>, loose: &[String]) -> Option<Vec<String>> {
    let mut merged = Vec::new();
    let mut seen = HashSet::new();
    if let Some(ext) = extracted {
        for p in ext {
            if Path::new(&p).is_file() && seen.insert(p.to_ascii_lowercase()) {
                merged.push(p);
            }
        }
    }
    for p in loose {
        if Path::new(p).is_file() && seen.insert(p.to_ascii_lowercase()) {
            merged.push(p.clone());
        }
    }
    if merged.is_empty() {
        None
    } else {
        Some(merged)
    }
}

fn is_image_preview(p: &Path) -> bool {
    p.is_file() && detect_media_type(p) == Some("image")
}

fn can_reuse_cached(
    cached: &WallpaperScanCacheProject,
    workshop_id: &str,
    has_ffmpeg: bool,
) -> bool {
    if cached.workshop_id != workshop_id
        || cached.type_override.is_some()
        || cached.items.is_empty()
    {
        return false;
    }
    cached.items.iter().all(|item| {
        item.workshop_id == workshop_id
            && Path::new(&item.source_path).is_file()
            && (!item.has_preview || Path::new(&item.preview_path).is_file())
            && item
                .asset_paths
                .as_ref()
                .map(|a| a.iter().all(|p| Path::new(p).is_file()))
                .unwrap_or(true)
            && item
                .audio_paths
                .as_ref()
                .map(|a| a.iter().all(|p| Path::new(p).is_file()))
                .unwrap_or(true)
            && (!has_ffmpeg
                || item.item_type != "video"
                || (item
                    .preview_path
                    .to_ascii_lowercase()
                    .ends_with("-square-v3.jpg")
                    && Path::new(&item.preview_path).is_file()
                    && item
                        .preview_video_path
                        .as_deref()
                        .map(|p| !p.is_empty() && Path::new(p).is_file())
                        .unwrap_or(false)))
            && (item.item_type != "image"
                || (item
                    .preview_path
                    .to_ascii_lowercase()
                    .ends_with("-img-thumb-v2.jpg")
                    && Path::new(&item.preview_path).is_file()))
    })
}

fn normalize_project_key(project_dir: &str) -> String {
    strip_verbatim_prefix(&clean_path_str(Path::new(project_dir)))
        .trim_end_matches(['\\', '/'])
        .to_ascii_lowercase()
}

fn try_save_catalog(
    items: &[WallpaperItem],
    entries: &[WallpaperScanEntry],
    live_projects: &HashMap<String, (String, String)>,
    catalog_path: &Path,
) {
    let mut entry_by_ws: HashMap<String, WallpaperScanEntry> = HashMap::new();
    for e in entries {
        if matches!(e.state.as_str(), "success" | "warning") {
            entry_by_ws.insert(e.workshop_id.clone(), e.clone());
        }
    }

    let mut grouped: HashMap<String, Vec<WallpaperItem>> = HashMap::new();
    for item in items {
        let key = normalize_project_key(&item.workshop_directory);
        if !key.is_empty() {
            grouped.entry(key).or_default().push(item.clone());
        }
    }

    let mut projects = Vec::new();
    for (key, proj_items) in grouped {
        let Some((ws_id, orig_dir)) = live_projects.get(&key) else {
            continue;
        };
        let Some(mut entry) = entry_by_ws.get(ws_id).cloned() else {
            continue;
        };
        entry.item_count = proj_items.len();
        projects.push(WallpaperScanCacheProject {
            workshop_id: ws_id.clone(),
            project_directory: orig_dir.clone(),
            type_override: None,
            items: proj_items,
            entry,
        });
    }

    if let Some(dir) = catalog_path.parent() {
        let _ = fs::create_dir_all(dir);
    }
    let cache = WallpaperScanCache {
        version: WallpaperScanCache::CURRENT_VERSION,
        projects,
    };
    if let Ok(bytes) = serde_json::to_vec(&cache) {
        let tmp = catalog_path.with_extension(format!("{}.tmp", std::process::id()));
        if fs::write(&tmp, bytes).is_ok() {
            if fs::rename(&tmp, catalog_path).is_err() {
                let _ = fs::remove_file(catalog_path);
                let _ = fs::rename(&tmp, catalog_path);
            }
        }
        let _ = fs::remove_file(tmp);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scanner_isolates_malformed_and_rejects_traversal() {
        let base = std::env::temp_dir().join(format!("wallpull_scan_{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        let ws = base.join("431960");
        let p_good = ws.join("1001");
        let p_trav = ws.join("1002");
        let p_bad = ws.join("1003");
        fs::create_dir_all(&p_good).unwrap();
        fs::create_dir_all(&p_trav).unwrap();
        fs::create_dir_all(&p_bad).unwrap();

        let img = image::RgbaImage::from_pixel(32, 32, image::Rgba([20, 40, 200, 255]));
        img.save(p_good.join("wall.png")).unwrap();
        fs::write(
            p_good.join("project.json"),
            r#"{"title":"Valid Img","type":"image","file":"wall.png"}"#,
        )
        .unwrap();

        fs::write(ws.join("outside.png"), b"fake").unwrap();
        fs::write(
            p_trav.join("project.json"),
            r#"{"title":"Bad Traversal","type":"image","file":"../outside.png"}"#,
        )
        .unwrap();
        fs::write(p_bad.join("project.json"), b"{invalid").unwrap();

        let catalog = base.join("catalog.json");
        let res = scan_wallpapers(
            &[ws.to_string_lossy().into_owned()],
            true,
            true,
            false,
            false,
            Some(&catalog),
            None,
            |_| {},
            |_| {},
        );
        assert_eq!(res.items.len(), 1);
        assert_eq!(res.items[0].workshop_id, "1001");
        assert!(!res.items[0].source_path.starts_with(r"\\?\"));
        assert!(!res.items[0].preview_path.starts_with(r"\\?\"));
        assert!(res.report.failed_projects >= 2);
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn strip_verbatim_removes_windows_unc_and_drive_prefixes() {
        assert_eq!(
            strip_verbatim_prefix(r"\\?\C:\Steam\steamapps\workshop\content\431960\preview.gif"),
            r"C:\Steam\steamapps\workshop\content\431960\preview.gif"
        );
        assert_eq!(
            strip_verbatim_prefix(r"\\?\UNC\server\share\file.png"),
            r"\\server\share\file.png"
        );
    }

    #[test]
    fn optional_local_workshop_smoke_test_produces_clean_non_verbatim_previews() {
        let Ok(raw_dirs) = std::env::var("WALLPULL_TEST_WORKSHOP_DIRS") else {
            return;
        };
        let dirs: Vec<PathBuf> = raw_dirs
            .split(';')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(PathBuf::from)
            .filter(|p| p.is_dir())
            .collect();
        if dirs.is_empty() {
            return;
        }
        let ffmpeg = find_executable("ffmpeg.exe");
        let ffprobe = find_executable("ffprobe.exe");
        if ffmpeg.is_none() || ffprobe.is_none() {
            return;
        }
        for dir in &dirs {
            let ws_id = dir
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("sample");
            let (items, entry) = try_read_project(
                ws_id,
                dir,
                true,
                ffmpeg.as_deref(),
                ffprobe.as_deref(),
                true,
                None,
            );
            assert_eq!(items.len(), 1, "expected 1 item for {ws_id}, got entry: {:?}", entry);
            let item = &items[0];
            assert_eq!(item.item_type, "video");
            assert!(!item.source_path.starts_with(r"\\?\"));
            assert!(!item.preview_path.starts_with(r"\\?\"));
            assert!(!item.workshop_directory.starts_with(r"\\?\"));
            assert!(
                item.preview_path.to_ascii_lowercase().ends_with("-square-v3.jpg"),
                "expected clean extracted 1024px frame for {ws_id}, got {}",
                item.preview_path
            );
            let dims = image::image_dimensions(&item.preview_path).expect("valid preview jpg");
            assert_eq!(dims, (1024, 1024));
            let clip = item.preview_video_path.as_deref().expect("expected 480p clip");
            assert!(clip.to_ascii_lowercase().ends_with("-480p-v1.mp4"));
            assert!(Path::new(clip).is_file());
        }
    }
}
