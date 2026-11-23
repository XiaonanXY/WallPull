use crate::media::{
    detect_media_type, probe_or_fallback_cancellable, try_create_video_preview_cancellable,
    try_create_video_preview_clip_cancellable,
};
use crate::models::{MediaInfo, ResolvedMediaAsset, clean_path_str};
use crate::scene_studio::{PkgSlice, try_composite_2d_scene, try_read_pkg_header};
use crate::settings::cache_root;
use crate::tex::{is_sprite_sheet_tex, try_decode_to_png};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

const EXTRACTOR_VERSION: i32 = 7;
const DOTNET_EPOCH_TICKS: i64 = 621_355_968_000_000_000;

const AUXILIARY_TERMS: &[&str] = &[
    "mask", "particle", "effect", "noise", "lut", "gradient", "displace",
    "flow", "normal", "alpha", "blur", "light_map", "shake",
];

#[derive(Debug, Clone)]
pub struct PkgUnpackSummary {
    pub extracted_files: usize,
    pub decoded_textures: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "PascalCase")]
struct ExtractionMarker {
    file_length: u64,
    last_write_ticks: i64,
    extractor_version: i32,
}

pub fn decode_tex_file_to_png(tex_path: &Path, dest_png: &Path) -> bool {
    let Ok(bytes) = fs::read(tex_path) else {
        return false;
    };
    try_decode_to_png(&bytes, dest_png)
}

pub fn unpack_pkg_file(
    pkg_file_path: &Path,
    output_dir: &Path,
    decode_tex: bool,
) -> Result<PkgUnpackSummary, String> {
    if !pkg_file_path.is_file() {
        return Err(format!("找不到指定的 .pkg 文件：{}", pkg_file_path.display()));
    }
    let full_out = std::path::absolute(output_dir).unwrap_or_else(|_| output_dir.to_path_buf());
    fs::create_dir_all(&full_out).map_err(|e| format!("无法创建输出目录：{e}"))?;

    let mut file = File::open(pkg_file_path).map_err(|e| format!("无法读取 PKG：{e}"))?;
    let total_len = file.metadata().map_err(|e| e.to_string())?.len();
    if total_len < 16 {
        return Err("PKG 文件体积过小或已损坏。".to_string());
    }

    let entries = read_pkg_entry_list(&mut file, total_len)
        .ok_or_else(|| "不是有效的 Wallpaper Engine PKGV 包或目录表损坏。".to_string())?;

    let mut extracted = 0usize;
    let mut decoded_tex = 0usize;

    for (entry_path, slice) in entries {
        let Some(dest_path) = resolve_safe_sub_path(&full_out, &entry_path) else {
            continue;
        };
        if let Some(parent) = dest_path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        if !copy_file_range_to_path(&mut file, slice.abs_offset, slice.length, &dest_path) {
            continue;
        }
        extracted += 1;

        if decode_tex
            && slice.length <= 256 * 1024 * 1024
            && dest_path
                .extension()
                .and_then(|e| e.to_str())
                .map(|e| e.eq_ignore_ascii_case("tex"))
                .unwrap_or(false)
        {
            if let Ok(payload) = fs::read(&dest_path) {
                let png_path = dest_path.with_extension("png");
                if try_decode_to_png(&payload, &png_path) {
                    decoded_tex += 1;
                }
            }
        }
    }

    Ok(PkgUnpackSummary {
        extracted_files: extracted,
        decoded_textures: decoded_tex,
    })
}

pub fn extract_scene_assets(
    workshop_id: &str,
    scene_pkg_path: &Path,
    fallback_preview_path: &Path,
    ffmpeg_path: Option<&Path>,
    ffprobe_path: Option<&Path>,
    use_hw_decode: bool,
) -> Vec<ResolvedMediaAsset> {
    extract_scene_assets_cancellable(
        workshop_id,
        scene_pkg_path,
        fallback_preview_path,
        ffmpeg_path,
        ffprobe_path,
        use_hw_decode,
        None,
    )
}

pub fn extract_scene_assets_cancellable(
    workshop_id: &str,
    scene_pkg_path: &Path,
    fallback_preview_path: &Path,
    ffmpeg_path: Option<&Path>,
    ffprobe_path: Option<&Path>,
    use_hw_decode: bool,
    cancel: Option<&AtomicBool>,
) -> Vec<ResolvedMediaAsset> {
    if !scene_pkg_path.is_file() || cancel.map(|c| c.load(Ordering::SeqCst)).unwrap_or(false) {
        return Vec::new();
    }
    let scenes_root = cache_root().join("scenes");
    let Some(extraction_root) = ensure_extracted(workshop_id, scene_pkg_path, &scenes_root) else {
        return Vec::new();
    };
    if cancel.map(|c| c.load(Ordering::SeqCst)).unwrap_or(false) {
        return Vec::new();
    }

    let audio_dir = extraction_root.join("audio");
    let mut audio_files = Vec::new();
    if let Ok(entries) = fs::read_dir(&audio_dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_file() && is_audio_ext(&p) {
                audio_files.push(clean_path_str(&p));
            }
        }
    }
    audio_files.sort_by_key(|a| a.to_ascii_lowercase());
    let resolved_audio = if audio_files.is_empty() {
        None
    } else {
        Some(audio_files)
    };

    let all_files = collect_files_recursive(&extraction_root);
    let mut videos: Vec<PathBuf> = all_files
        .iter()
        .filter(|p| is_video_ext(p))
        .cloned()
        .collect();
    videos.sort_by_key(|p| std::cmp::Reverse(fs::metadata(p).map(|m| m.len()).unwrap_or(0)));

    if let Some(primary) = videos.first() {
        let info = probe_or_fallback_cancellable(primary, ffprobe_path, cancel);
        let key = format!("{workshop_id}-scene-video-1");
        let preview = try_create_video_preview_cancellable(
            primary,
            &key,
            ffmpeg_path,
            use_hw_decode,
            cancel,
        )
        .filter(|p| Path::new(p).is_file())
        .unwrap_or_else(|| {
            if detect_media_type(fallback_preview_path) == Some("image") {
                clean_path_str(fallback_preview_path)
            } else {
                clean_path_str(primary)
            }
        });
        let preview_clip = try_create_video_preview_clip_cancellable(
            primary,
            &key,
            ffmpeg_path,
            use_hw_decode,
            cancel,
        );
        let src_str = clean_path_str(primary);
        return vec![ResolvedMediaAsset {
            media_type: "video".to_string(),
            source_path: src_str.clone(),
            preview_path: preview,
            media_info: info,
            asset_paths: vec![src_str],
            preview_video_path: preview_clip,
            audio_paths: resolved_audio,
        }];
    }

    let mut ranked_images: Vec<(PathBuf, i32, i32, i64, f64)> = all_files
        .iter()
        .filter(|p| is_image_ext(p))
        .filter_map(|p| {
            let (w, h) = crate::media::read_image_dimensions(p);
            let len = fs::metadata(p).map(|m| m.len() as i64).unwrap_or(0);
            let score = score_image(p, w, h, len);
            if score > 0.0 {
                Some((p.clone(), w, h, len, score))
            } else {
                None
            }
        })
        .collect();

    ranked_images.sort_by(|a, b| b.4.partial_cmp(&a.4).unwrap_or(std::cmp::Ordering::Equal));
    let Some(best) = ranked_images.first() else {
        return Vec::new();
    };

    let min_variant_score = best.4 * 0.45;
    let mut variants: Vec<String> = ranked_images
        .iter()
        .filter(|c| c.4 >= min_variant_score && c.1 >= 720 && c.2 >= 720)
        .take(6)
        .map(|c| clean_path_str(&c.0))
        .collect();
    let best_str = clean_path_str(&best.0);
    if variants.is_empty() {
        variants.push(best_str.clone());
    }

    vec![ResolvedMediaAsset {
        media_type: "image".to_string(),
        source_path: best_str.clone(),
        preview_path: best_str,
        media_info: MediaInfo {
            width: best.1,
            height: best.2,
            duration_seconds: None,
            file_size: best.3,
        },
        asset_paths: variants,
        preview_video_path: None,
        audio_paths: resolved_audio,
    }]
}

fn ensure_extracted(workshop_id: &str, scene_pkg: &Path, cache_base: &Path) -> Option<PathBuf> {
    fs::create_dir_all(cache_base).ok()?;
    let safe_id: String = workshop_id.chars().filter(|c| c.is_ascii_digit()).collect();
    if safe_id.is_empty() {
        return None;
    }
    let project_root = cache_base.join(&safe_id);
    let marker_path = project_root.join(".native-source.json");

    let meta = fs::metadata(scene_pkg).ok()?;
    let expected = ExtractionMarker {
        file_length: meta.len(),
        last_write_ticks: meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| (d.as_nanos() / 100) as i64 + DOTNET_EPOCH_TICKS)
            .unwrap_or(0),
        extractor_version: EXTRACTOR_VERSION,
    };

    if project_root.is_dir() && marker_path.is_file() {
        if let Ok(bytes) = fs::read(&marker_path) {
            if let Ok(existing) = serde_json::from_slice::<ExtractionMarker>(&bytes) {
                if existing == expected {
                    return Some(project_root);
                }
            }
        }
    }

    let tmp_name = format!(
        ".native-{safe_id}-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    );
    let tmp_root = cache_base.join(tmp_name);
    fs::create_dir_all(&tmp_root).ok()?;

    let ok = extract_package_media(scene_pkg, &tmp_root);
    if !ok {
        let _ = fs::remove_dir_all(&tmp_root);
        return None;
    }

    if let Ok(marker_bytes) = serde_json::to_vec(&expected) {
        let _ = fs::write(tmp_root.join(".native-source.json"), marker_bytes);
    }

    if project_root.is_dir() {
        let _ = fs::remove_dir_all(&project_root);
    }
    if fs::rename(&tmp_root, &project_root).is_err() {
        let _ = fs::remove_dir_all(&tmp_root);
        return None;
    }
    Some(project_root)
}

fn extract_package_media(scene_pkg: &Path, output_root: &Path) -> bool {
    let Ok(mut file) = File::open(scene_pkg) else {
        return false;
    };
    let Ok(total_len) = file.metadata().map(|m| m.len()) else {
        return false;
    };
    if total_len < 16 {
        return false;
    }
    let Some(entries) = read_pkg_entry_list(&mut file, total_len) else {
        return false;
    };

    extract_package_audio(&mut file, &entries, output_root);
    let mut extracted_count = 0usize;

    // 1. Direct video files first
    let mut direct_videos: Vec<&(String, PkgSlice)> = entries
        .iter()
        .filter(|(p, _)| is_video_ext(Path::new(p)))
        .collect();
    direct_videos.sort_by_key(|a| std::cmp::Reverse(a.1.length));
    for (p, slice) in direct_videos.into_iter().take(2) {
        let out = build_safe_output_path(output_root, p, None, extracted_count);
        if try_copy_range(&mut file, *slice, &out) {
            return true;
        }
    }

    // 2. Embedded MP4 inside .tex containers
    let mut tex_entries: Vec<&(String, PkgSlice)> = entries
        .iter()
        .filter(|(p, _)| {
            Path::new(p)
                .extension()
                .and_then(|e| e.to_str())
                .map(|e| e.eq_ignore_ascii_case("tex"))
                .unwrap_or(false)
                && !is_auxiliary_name(p)
        })
        .collect();
    tex_entries.sort_by_key(|a| std::cmp::Reverse(a.1.length));
    let tex_top: Vec<&(String, PkgSlice)> = tex_entries.into_iter().take(12).collect();

    for (p, slice) in &tex_top {
        if slice.length > 128 * 1024 * 1024 {
            continue;
        }
        let probe_len = slice.length.min(512);
        let mut probe = vec![0u8; probe_len];
        if file.seek(SeekFrom::Start(slice.abs_offset)).is_err()
            || file.read_exact(&mut probe).is_err()
        {
            continue;
        }
        if let Some((".mp4", sig_off)) = detect_embedded_media(&probe) {
            let mut payload = vec![0u8; slice.length];
            if file.seek(SeekFrom::Start(slice.abs_offset)).is_ok()
                && file.read_exact(&mut payload).is_ok()
            {
                let sliced = slice_embedded_payload(&payload, sig_off, ".mp4");
                if sliced.len() >= 256 {
                    let out = build_safe_output_path(output_root, p, Some(".mp4"), extracted_count);
                    if fs::write(&out, sliced).is_ok() {
                        return true;
                    }
                }
            }
        }
    }

    // 3. Multi-layer 2D scene composition
    let _ = file.seek(SeekFrom::Start(0));
    if let Some(entry_map) = try_read_pkg_header(&mut file) {
        let comp_path = output_root.join("00-scene-composite.png");
        if try_composite_2d_scene(&mut file, &entry_map, &comp_path) {
            return true;
        }
        let _ = fs::remove_file(&comp_path);
    }

    // 4. Direct image files
    let mut direct_images: Vec<&(String, PkgSlice)> = entries
        .iter()
        .filter(|(p, _)| is_image_ext(Path::new(p)) && !is_auxiliary_name(p))
        .collect();
    direct_images.sort_by_key(|a| std::cmp::Reverse(a.1.length));
    for (p, slice) in direct_images.into_iter().take(6) {
        let out = build_safe_output_path(output_root, p, None, extracted_count);
        if try_copy_range(&mut file, *slice, &out) {
            extracted_count += 1;
        }
    }

    // 5. Embedded or raw images inside .tex containers
    for (p, slice) in &tex_top {
        if slice.length > 128 * 1024 * 1024 {
            continue;
        }
        let probe_len = slice.length.min(512);
        let mut probe = vec![0u8; probe_len];
        if file.seek(SeekFrom::Start(slice.abs_offset)).is_err()
            || file.read_exact(&mut probe).is_err()
        {
            continue;
        }
        if is_sprite_sheet_tex(&probe) {
            continue;
        }
        let mut payload = vec![0u8; slice.length];
        if file.seek(SeekFrom::Start(slice.abs_offset)).is_err()
            || file.read_exact(&mut payload).is_err()
        {
            continue;
        }

        if let Some((ext, sig_off)) = detect_embedded_media(&probe) {
            let sliced = slice_embedded_payload(&payload, sig_off, ext);
            if sliced.len() >= 256 {
                let out = build_safe_output_path(output_root, p, Some(ext), extracted_count);
                if fs::write(&out, sliced).is_ok() {
                    extracted_count += 1;
                }
            }
        } else {
            let out = build_safe_output_path(output_root, p, Some(".png"), extracted_count);
            if try_decode_to_png(&payload, &out) {
                extracted_count += 1;
            }
        }
    }

    extracted_count > 0
}

fn read_pkg_entry_list(file: &mut File, total_len: u64) -> Option<Vec<(String, PkgSlice)>> {
    file.seek(SeekFrom::Start(0)).ok()?;
    let mut len_buf = [0u8; 4];
    file.read_exact(&mut len_buf).ok()?;
    let magic_len = i32::from_le_bytes(len_buf) as usize;
    if magic_len == 0 || magic_len > 64 {
        return None;
    }
    let mut magic_buf = vec![0u8; magic_len];
    file.read_exact(&mut magic_buf).ok()?;
    if !String::from_utf8_lossy(&magic_buf).starts_with("PKGV") {
        return None;
    }

    file.read_exact(&mut len_buf).ok()?;
    let count = i32::from_le_bytes(len_buf);
    if count <= 0 || count > 50_000 {
        return None;
    }

    let mut raw = Vec::with_capacity(count as usize);
    for _ in 0..count {
        file.read_exact(&mut len_buf).ok()?;
        let path_len = i32::from_le_bytes(len_buf) as usize;
        if path_len == 0 || path_len > 1024 {
            return None;
        }
        let mut pbuf = vec![0u8; path_len];
        file.read_exact(&mut pbuf).ok()?;
        let entry_path = String::from_utf8_lossy(&pbuf).into_owned();
        file.read_exact(&mut len_buf).ok()?;
        let rel_off = i32::from_le_bytes(len_buf);
        file.read_exact(&mut len_buf).ok()?;
        let length = i32::from_le_bytes(len_buf);
        if rel_off >= 0 && length > 0 {
            raw.push((entry_path, rel_off as u64, length as usize));
        }
    }

    let data_start = file.stream_position().ok()?;
    let out = raw
        .into_iter()
        .filter_map(|(p, off, len)| {
            let abs = data_start + off;
            if abs >= data_start && abs + (len as u64) <= total_len {
                Some((
                    p,
                    PkgSlice {
                        abs_offset: abs,
                        length: len,
                    },
                ))
            } else {
                None
            }
        })
        .collect();
    Some(out)
}

fn extract_package_audio(file: &mut File, entries: &[(String, PkgSlice)], output_root: &Path) {
    let mut audio_entries: Vec<&(String, PkgSlice)> = entries
        .iter()
        .filter(|(p, s)| {
            is_audio_ext(Path::new(p)) && (64 * 1024..=64 * 1024 * 1024).contains(&s.length)
        })
        .collect();
    if audio_entries.is_empty() {
        return;
    }
    audio_entries.sort_by_key(|a| std::cmp::Reverse(a.1.length));
    let audio_dir = output_root.join("audio");
    if fs::create_dir_all(&audio_dir).is_err() {
        return;
    }
    for (idx, (p, slice)) in audio_entries.into_iter().take(6).enumerate() {
        let out = build_safe_output_path(&audio_dir, p, None, idx);
        let _ = try_copy_range(file, *slice, &out);
    }
}

fn detect_embedded_media(header: &[u8]) -> Option<(&'static str, usize)> {
    const PNG_SIG: &[u8] = &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    const JPG_SIG: &[u8] = &[0xFF, 0xD8, 0xFF];
    const MP4_SIG: &[u8] = b"ftyp";

    if let Some(pos) = find_subslice(header, PNG_SIG) {
        return Some((".png", pos));
    }
    if let Some(pos) = find_subslice(header, JPG_SIG) {
        return Some((".jpg", pos));
    }
    if let Some(pos) = find_subslice(header, MP4_SIG) {
        if pos >= 4 {
            return Some((".mp4", pos - 4));
        }
    }
    None
}

fn slice_embedded_payload<'a>(buffer: &'a [u8], sig_off: usize, ext: &str) -> &'a [u8] {
    let remaining = buffer.len().saturating_sub(sig_off);
    if remaining == 0 {
        return &[];
    }
    if sig_off >= 4 {
        let declared = i32::from_le_bytes(
            buffer[sig_off - 4..sig_off]
                .try_into()
                .unwrap_or([0; 4]),
        );
        if declared > 256 && (declared as usize) <= remaining {
            return &buffer[sig_off..sig_off + (declared as usize)];
        }
    }
    if ext == ".png" {
        if let Some(iend_pos) = rfind_subslice(&buffer[sig_off..], b"IEND") {
            if sig_off + iend_pos + 8 <= buffer.len() {
                return &buffer[sig_off..sig_off + iend_pos + 8];
            }
        }
    }
    &buffer[sig_off..]
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn rfind_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).rposition(|w| w == needle)
}

fn try_copy_range(src: &mut File, slice: PkgSlice, dest: &Path) -> bool {
    if src.seek(SeekFrom::Start(slice.abs_offset)).is_err() {
        return false;
    }
    let Ok(mut out) = File::create(dest) else {
        return false;
    };
    let mut buf = [0u8; 65536];
    let mut rem = slice.length;
    while rem > 0 {
        let chunk = rem.min(buf.len());
        let Ok(n) = src.read(&mut buf[..chunk]) else {
            return false;
        };
        if n == 0 {
            break;
        }
        if out.write_all(&buf[..n]).is_err() {
            return false;
        }
        rem -= n;
    }
    rem == 0
}

fn build_safe_output_path(
    output_root: &Path,
    entry_path: &str,
    override_ext: Option<&str>,
    index: usize,
) -> PathBuf {
    let p = Path::new(entry_path);
    let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    let safe_base: String = stem
        .chars()
        .map(|c| {
            if matches!(c, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*') || c.is_control()
            {
                '_'
            } else {
                c
            }
        })
        .collect::<String>()
        .trim()
        .trim_end_matches('.')
        .chars()
        .take(64)
        .collect();
    let final_base = if safe_base.is_empty() {
        format!("asset-{}", index + 1)
    } else {
        safe_base
    };
    let ext = override_ext
        .map(|s| s.to_string())
        .or_else(|| {
            p.extension()
                .and_then(|e| e.to_str())
                .map(|e| format!(".{e}"))
        })
        .unwrap_or_default();
    output_root.join(format!("{:02}-{}{}", index + 1, final_base, ext))
}

fn resolve_safe_sub_path(output_root: &Path, relative_entry_path: &str) -> Option<PathBuf> {
    let normalized = relative_entry_path
        .replace(['/', '\\'], std::path::MAIN_SEPARATOR_STR)
        .trim_start_matches(std::path::MAIN_SEPARATOR)
        .to_string();
    if normalized.trim().is_empty() {
        return None;
    }
    let mut clean = output_root.to_path_buf();
    for comp in Path::new(&normalized).components() {
        match comp {
            std::path::Component::Normal(s) => clean.push(s),
            _ => return None,
        }
    }
    if clean == output_root {
        None
    } else {
        Some(clean)
    }
}

fn copy_file_range_to_path(
    src_file: &mut File,
    abs_offset: u64,
    length: usize,
    dest_path: &Path,
) -> bool {
    if src_file.seek(SeekFrom::Start(abs_offset)).is_err() {
        return false;
    }
    let Ok(mut out_file) = File::create(dest_path) else {
        return false;
    };
    let mut buf = [0u8; 64 * 1024];
    let mut remaining = length;
    while remaining > 0 {
        let chunk_len = remaining.min(buf.len());
        if src_file.read_exact(&mut buf[..chunk_len]).is_err() {
            let _ = fs::remove_file(dest_path);
            return false;
        }
        if out_file.write_all(&buf[..chunk_len]).is_err() {
            let _ = fs::remove_file(dest_path);
            return false;
        }
        remaining -= chunk_len;
    }
    out_file.flush().is_ok()
}

fn collect_files_recursive(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![(root.to_path_buf(), 0u32)];
    while let Some((dir, depth)) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let p = entry.path();
            if crate::models::is_reparse_point(&p) {
                continue;
            }
            let Ok(meta) = fs::symlink_metadata(&p) else {
                continue;
            };
            if meta.is_dir() {
                if depth < 16 {
                    stack.push((p, depth + 1));
                }
            } else if meta.is_file() {
                out.push(p);
            }
        }
    }
    out
}

fn is_auxiliary_name(path: &str) -> bool {
    let lower = path.to_ascii_lowercase();
    AUXILIARY_TERMS.iter().any(|t| lower.contains(t))
}

fn score_image(path: &Path, width: i32, height: i32, file_size: i64) -> f64 {
    if width < 256 || height < 256 {
        return 0.0;
    }
    let max_d = width.max(height) as f64;
    let min_d = width.min(height).max(1) as f64;
    if max_d / min_d > 4.0 {
        return 0.0;
    }
    let mut score = (width as f64) * (height as f64) + (file_size as f64) * 0.1;
    if is_auxiliary_name(&path.to_string_lossy()) {
        score *= 0.1;
    }
    score
}

fn is_image_ext(path: &Path) -> bool {
    matches!(
        path.extension()
            .and_then(|e| e.to_str())
            .map(|e| e.to_ascii_lowercase())
            .as_deref(),
        Some("png" | "jpg" | "jpeg" | "webp")
    )
}

fn is_video_ext(path: &Path) -> bool {
    matches!(
        path.extension()
            .and_then(|e| e.to_str())
            .map(|e| e.to_ascii_lowercase())
            .as_deref(),
        Some("mp4" | "webm" | "mkv" | "avi" | "mov")
    )
}

fn is_audio_ext(path: &Path) -> bool {
    matches!(
        path.extension()
            .and_then(|e| e.to_str())
            .map(|e| e.to_ascii_lowercase())
            .as_deref(),
        Some("mp3" | "ogg" | "wav" | "flac" | "m4a")
    )
}

#[allow(dead_code)]
fn _keep(_: HashMap<String, PkgSlice>) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkg_unpack_rejects_traversal_and_extracts_valid_entries() {
        let dir = std::env::temp_dir().join(format!("wallpull_pkg_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let pkg_path = dir.join("test.pkg");
        let e1_path = b"scene.json";
        let e1_data = b"{\"ok\":true}";
        let e2_path = b"../evil.txt";
        let e2_data = b"bad";

        let mut pkg = Vec::new();
        let magic = b"PKGV0002";
        pkg.extend_from_slice(&(magic.len() as i32).to_le_bytes());
        pkg.extend_from_slice(magic);
        pkg.extend_from_slice(&2i32.to_le_bytes());

        pkg.extend_from_slice(&(e1_path.len() as i32).to_le_bytes());
        pkg.extend_from_slice(e1_path);
        pkg.extend_from_slice(&0i32.to_le_bytes());
        pkg.extend_from_slice(&(e1_data.len() as i32).to_le_bytes());

        pkg.extend_from_slice(&(e2_path.len() as i32).to_le_bytes());
        pkg.extend_from_slice(e2_path);
        pkg.extend_from_slice(&(e1_data.len() as i32).to_le_bytes());
        pkg.extend_from_slice(&(e2_data.len() as i32).to_le_bytes());

        pkg.extend_from_slice(e1_data);
        pkg.extend_from_slice(e2_data);
        fs::write(&pkg_path, pkg).unwrap();

        let out_dir = dir.join("out");
        let summary = unpack_pkg_file(&pkg_path, &out_dir, false).unwrap();
        assert_eq!(summary.extracted_files, 1);
        assert!(out_dir.join("scene.json").is_file());
        assert!(!dir.join("evil.txt").exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn extraction_marker_uses_csharp_pascal_case() {
        let marker = ExtractionMarker {
            file_length: 12345,
            last_write_ticks: 638000000000000000,
            extractor_version: EXTRACTOR_VERSION,
        };
        let json = serde_json::to_string(&marker).unwrap();
        assert!(json.contains("\"FileLength\":12345"));
        assert!(json.contains("\"LastWriteTicks\":638000000000000000"));
        assert!(json.contains("\"ExtractorVersion\":7"));
    }
}
