use crate::media::{find_executable, pack_multi_size_ico_pure_rust, probe_or_fallback};
use crate::models::{
    AppSettings, ToolboxProgressPayload, WallpaperItem, is_reparse_point, strip_verbatim_prefix,
};
use crate::pkg::{decode_tex_file_to_png, unpack_pkg_file};
use crate::process_runner::{
    CANCELLED_ERR, os_args, remove_file_with_retry, run_ffmpeg_progress, run_output, run_status,
};
use crate::scanner::rewrite_as_offline_project_json;
use crate::settings::{calculate_directory_bytes, cache_root, resolve_configured_workshop_roots};
use crate::we_bridge::{
    is_wallpaper_engine_running, send_control_command, try_find_install_directory,
};
use image::ImageFormat;
use serde::Serialize;
use std::collections::HashSet;
use std::ffi::OsStr;
use std::fs;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;
use windows::Win32::Foundation::CloseHandle;
use windows::Win32::Storage::FileSystem::{
    CreateFileW, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_GENERIC_WRITE,
    FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE, GetDiskFreeSpaceExW,
    GetVolumeInformationW, OPEN_EXISTING,
};
use windows::Win32::System::IO::DeviceIoControl;
use windows::Win32::UI::Shell::{
    FOF_ALLOWUNDO, FOF_NOCONFIRMATION, FOF_NOERRORUI, FOF_SILENT, FO_DELETE, SHFILEOPSTRUCTW,
    SHFileOperationW, ShellExecuteW,
};
use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
use windows::core::PCWSTR;

const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0400;
static TEMP_SEQ: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MigrationStatus {
    pub workshop_root: Option<String>,
    pub is_junction: bool,
    pub link_target: Option<String>,
    pub total_bytes: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PickedToolboxFile {
    pub path: String,
    pub name: String,
    pub size: i64,
    pub ext: String,
    pub kind: String,
}

pub fn format_byte_size(bytes: i64) -> String {
    if bytes <= 0 {
        return "0 B".to_string();
    }
    let units = ["B", "KB", "MB", "GB", "TB"];
    let mut val = bytes as f64;
    let mut idx = 0usize;
    while val >= 1024.0 && idx < units.len() - 1 {
        val /= 1024.0;
        idx += 1;
    }
    if idx == 0 {
        format!("{} B", bytes)
    } else if val >= 10.0 {
        let s = format!("{val:.1}");
        let trimmed = s.strip_suffix(".0").unwrap_or(&s);
        format!("{trimmed} {}", units[idx])
    } else {
        let s = format!("{val:.2}");
        let trimmed = s.trim_end_matches('0').trim_end_matches('.');
        format!("{trimmed} {}", units[idx])
    }
}

pub fn get_safe_file_name(value: &str, fallback: &str) -> String {
    let safe: String = value
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
        .to_string();
    let base = if safe.is_empty() {
        fallback.to_string()
    } else {
        safe
    };
    base.chars().take(90).collect::<String>().trim().to_string()
}

pub fn get_unique_destination_path(directory: &Path, file_name: &str) -> PathBuf {
    let p = Path::new(file_name);
    let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("file");
    let ext = p
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| format!(".{e}"))
        .unwrap_or_default();
    let mut cand = directory.join(file_name);
    let mut suffix = 2usize;
    while cand.exists() {
        cand = directory.join(format!("{stem} ({suffix}){ext}"));
        suffix += 1;
    }
    cand
}

pub fn clean_track_title(audio_path: &str) -> String {
    let stem = Path::new(audio_path)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .trim();
    let chars: Vec<char> = stem.chars().collect();
    let trimmed = if chars.len() > 3 && chars[0].is_ascii_digit() && chars[1].is_ascii_digit() && chars[2] == '-' {
        chars[3..].iter().collect::<String>().trim().to_string()
    } else {
        stem.to_string()
    };
    if trimmed.is_empty() {
        stem.to_string()
    } else {
        trimmed
    }
}

pub fn open_wallpaper_folder(source_path: &Path) -> Result<(), String> {
    if !source_path.is_file() {
        return Err(format!("原始壁纸文件已不存在，请重新扫描：{}", source_path.display()));
    }
    let full = std::path::absolute(source_path).unwrap_or_else(|_| source_path.to_path_buf());
    Command::new("explorer.exe")
        .arg("/select,")
        .arg(full)
        .spawn()
        .map_err(|e| format!("打开资源管理器失败：{e}"))?;
    Ok(())
}

pub fn open_explorer_path(raw_path: &str) -> Result<(), String> {
    if raw_path.trim().is_empty() {
        return Err("路径无效。".to_string());
    }
    let p = std::path::absolute(Path::new(raw_path)).unwrap_or_else(|_| PathBuf::from(raw_path));
    if p.is_dir() {
        Command::new("explorer.exe")
            .arg(&p)
            .spawn()
            .map_err(|e| format!("打开文件夹失败：{e}"))?;
    } else if p.is_file() {
        Command::new("explorer.exe")
            .arg("/select,")
            .arg(&p)
            .spawn()
            .map_err(|e| format!("定位文件失败：{e}"))?;
    } else {
        return Err("目标路径不存在。".to_string());
    }
    Ok(())
}

pub fn open_steam_workshop_page(workshop_id: &str) -> Result<(), String> {
    if workshop_id.is_empty() || !workshop_id.chars().all(|c| c.is_ascii_digit()) {
        return Err("当前壁纸缺少有效的创意工坊 ID。".to_string());
    }
    let steam_uri = format!("steam://url/CommunityFilePage/{workshop_id}");
    if !shell_open_url(&steam_uri) {
        let https_url = format!("https://steamcommunity.com/sharedfiles/filedetails/?id={workshop_id}");
        if !shell_open_url(&https_url) {
            return Err("无法启动 Steam 或浏览器打开创意工坊页面。".to_string());
        }
    }
    Ok(())
}

pub fn open_external_url(url: &str) -> Result<(), String> {
    let trimmed = url.trim();
    if !trimmed.starts_with("https://") && !trimmed.starts_with("http://") {
        return Err("仅支持打开 http/https 链接。".to_string());
    }
    if shell_open_url(trimmed) {
        Ok(())
    } else {
        Err("无法唤起系统默认浏览器。".to_string())
    }
}

fn parse_semver_tuple(raw: &str) -> Option<(u64, u64, u64)> {
    let cleaned = raw
        .trim()
        .trim_start_matches(['v', 'V'])
        .split(['-', '+'])
        .next()?;
    let mut parts = cleaned.split('.');
    let major = parts.next()?.parse::<u64>().ok()?;
    let minor = parts.next().unwrap_or("0").parse::<u64>().ok()?;
    let patch = parts.next().unwrap_or("0").parse::<u64>().ok()?;
    Some((major, minor, patch))
}

pub fn is_newer_version(latest: &str, current: &str) -> bool {
    match (parse_semver_tuple(latest), parse_semver_tuple(current)) {
        (Some(l), Some(c)) => l > c,
        _ => false,
    }
}

pub fn extract_release_tag_from_location(location: &str) -> Option<(String, String)> {
    let cleaned = location.trim();
    let without_query = cleaned.split(['?', '#']).next().unwrap_or(cleaned);
    let trimmed = without_query.trim_end_matches('/');
    const MARKER: &str = "/releases/tag/";
    let idx = trimmed.find(MARKER)?;
    let tag = trimmed[idx + MARKER.len()..].trim();
    if tag.is_empty() || tag.contains('/') {
        return None;
    }
    let html_url = if trimmed.starts_with("https://") || trimmed.starts_with("http://") {
        trimmed.to_string()
    } else if trimmed.starts_with('/') {
        format!("https://github.com{trimmed}")
    } else {
        "https://github.com/XiaonanXY/WallPull/releases".to_string()
    };
    Some((tag.to_string(), html_url))
}

pub fn check_latest_release(current_version: &str) -> Result<(bool, String, String), String> {
    const LATEST_WEB_URL: &str = "https://github.com/XiaonanXY/WallPull/releases/latest";
    const LATEST_API_URL: &str = "https://api.github.com/repos/XiaonanXY/WallPull/releases/latest";
    const FALLBACK_RELEASE_URL: &str = "https://github.com/XiaonanXY/WallPull/releases";

    let user_agent = format!("WallPull/{current_version}");
    let redirect_agent = ureq::AgentBuilder::new()
        .redirects(0)
        .timeout(Duration::from_secs(8))
        .build();

    let head_resp = redirect_agent
        .head(LATEST_WEB_URL)
        .set("User-Agent", &user_agent)
        .call();

    match head_resp {
        Ok(resp) if matches!(resp.status(), 301 | 302 | 303 | 307 | 308) => {
            if let Some(loc) = resp.header("location") {
                if let Some((tag_name, html_url)) = extract_release_tag_from_location(loc) {
                    let has_update = is_newer_version(&tag_name, current_version);
                    return Ok((has_update, tag_name, html_url));
                }
                let clean_loc = loc
                    .trim()
                    .split(['?', '#'])
                    .next()
                    .unwrap_or("")
                    .trim_end_matches('/');
                if clean_loc.ends_with("/releases") {
                    return Err("暂未在 GitHub Releases 找到已发布版本，请稍后再试。".to_string());
                }
            }
        }
        Ok(_) => {}
        Err(ureq::Error::Status(404, _)) => {
            return Err("暂未在 GitHub Releases 找到已发布版本，请稍后再试。".to_string());
        }
        Err(ureq::Error::Transport(_)) => {
            return Err("无法连接到 GitHub 检查更新，请检查网络或代理设置后重试。".to_string());
        }
        Err(ureq::Error::Status(_, _)) => {}
    }

    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(8))
        .build();
    let response = agent
        .get(LATEST_API_URL)
        .set("User-Agent", &user_agent)
        .set("Accept", "application/vnd.github+json")
        .call()
        .map_err(|err| match err {
            ureq::Error::Status(403, _) => {
                "GitHub API 当前触发频率限制，请稍后重试或点击「GitHub 链接」查看最新版本。".to_string()
            }
            ureq::Error::Status(404, _) => {
                "暂未在 GitHub Releases 找到已发布版本，请稍后再试。".to_string()
            }
            ureq::Error::Status(code, _) => {
                format!("检查更新失败（GitHub 返回状态码 {code}），请稍后再试。")
            }
            ureq::Error::Transport(_) => {
                "无法连接到 GitHub 检查更新，请检查网络或代理设置后重试。".to_string()
            }
        })?;

    let body: serde_json::Value = response
        .into_json()
        .map_err(|_| "解析 GitHub 版本响应失败，请稍后再试。".to_string())?;
    let tag_name = body
        .get("tag_name")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| "GitHub 响应中缺少版本号信息。".to_string())?
        .to_string();
    let html_url = body
        .get("html_url")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| s.starts_with("https://") || s.starts_with("http://"))
        .unwrap_or(FALLBACK_RELEASE_URL)
        .to_string();

    let has_update = is_newer_version(&tag_name, current_version);
    Ok((has_update, tag_name, html_url))
}

fn shell_open_url(url: &str) -> bool {
    let op: Vec<u16> = OsStr::new("open").encode_wide().chain(Some(0)).collect();
    let target: Vec<u16> = OsStr::new(url).encode_wide().chain(Some(0)).collect();
    let h = unsafe {
        ShellExecuteW(
            None,
            PCWSTR(op.as_ptr()),
            PCWSTR(target.as_ptr()),
            PCWSTR::null(),
            PCWSTR::null(),
            SW_SHOWNORMAL,
        )
    };
    (h.0 as isize) > 32
}

pub fn export_wallpapers<FProgress>(
    items: &[WallpaperItem],
    destination_root: &Path,
    format: Option<&str>,
    cancel: Option<&AtomicBool>,
    mut on_progress: FProgress,
) -> Result<(usize, String), String>
where
    FProgress: FnMut(&str),
{
    if items.is_empty() {
        return Err("请先选择要导出的壁纸。".to_string());
    }
    let normalized_fmt = format
        .map(|f| f.trim().trim_start_matches('.').to_ascii_lowercase())
        .filter(|f| !f.is_empty() && f != "original");

    let export_root =
        std::path::absolute(destination_root).unwrap_or_else(|_| destination_root.to_path_buf());
    fs::create_dir_all(&export_root).map_err(|e| format!("无法创建导出目录：{e}"))?;

    let mut exported_count = 0usize;
    for wallpaper in items {
        if cancel.map(|c| c.load(Ordering::SeqCst)).unwrap_or(false) {
            return Err("导出任务已被新任务取消。".to_string());
        }
        let type_folder = export_root.join(if wallpaper.item_type == "video" {
            "视频"
        } else {
            "图片"
        });
        fs::create_dir_all(&type_folder).map_err(|e| e.to_string())?;

        let fallback_assets = vec![wallpaper.source_path.clone()];
        let assets = wallpaper
            .asset_paths
            .as_ref()
            .filter(|a| !a.is_empty())
            .unwrap_or(&fallback_assets);

        let dest_dir = if assets.len() > 1 {
            let sub = type_folder.join(format!(
                "{} [{}]",
                get_safe_file_name(&wallpaper.title, &wallpaper.workshop_id),
                wallpaper.workshop_id
            ));
            fs::create_dir_all(&sub).map_err(|e| e.to_string())?;
            sub
        } else {
            type_folder
        };

        for src_str in assets {
            if cancel.map(|c| c.load(Ordering::SeqCst)).unwrap_or(false) {
                return Err("导出任务已被新任务取消。".to_string());
            }
            let src = Path::new(src_str);
            if !src.is_file() {
                continue;
            }
            let src_ext = src
                .extension()
                .and_then(|e| e.to_str())
                .map(|e| e.to_ascii_lowercase())
                .unwrap_or_default();
            let target_ext = normalized_fmt.as_deref().unwrap_or(&src_ext);
            let needs_convert = normalized_fmt.is_some()
                && !target_ext.eq_ignore_ascii_case(&src_ext)
                && !(target_ext == "jpg" && src_ext == "jpeg");

            let base_name = if assets.len() == 1 {
                get_safe_file_name(&wallpaper.title, &wallpaper.workshop_id)
            } else {
                src.file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("asset")
                    .to_string()
            };
            let dest_path = get_unique_destination_path(&dest_dir, &format!("{base_name}.{target_ext}"));

            if needs_convert {
                on_progress(&format!(
                    "正在转换为 {} 并导出…",
                    target_ext.to_ascii_uppercase()
                ));
                convert_export_file(src, &dest_path, target_ext, cancel)?;
            } else {
                fs::copy(src, &dest_path).map_err(|e| format!("复制文件失败：{e}"))?;
            }
            exported_count += 1;
        }
    }

    Ok((exported_count, export_root.to_string_lossy().into_owned()))
}

fn convert_export_file(
    src: &Path,
    dest: &Path,
    target_fmt: &str,
    cancel: Option<&AtomicBool>,
) -> Result<(), String> {
    if matches!(target_fmt, "png" | "jpg" | "jpeg" | "webp" | "bmp") {
        let img = image::open(src).map_err(|e| format!("解码原图片失败：{e}"))?;
        let fmt = match target_fmt {
            "jpg" | "jpeg" => ImageFormat::Jpeg,
            "webp" => ImageFormat::WebP,
            "bmp" => ImageFormat::Bmp,
            _ => ImageFormat::Png,
        };
        img.save_with_format(dest, fmt)
            .map_err(|e| format!("保存转换图片失败：{e}"))?;
        return Ok(());
    }

    let ffmpeg = find_executable("ffmpeg.exe").ok_or_else(|| {
        format!(
            "转换为 {} 格式需要 ffmpeg.exe，请将 ffmpeg.exe 放在软件同级 Tools 目录或系统 PATH 中。",
            target_fmt.to_ascii_uppercase()
        )
    })?;
    let mut args = vec![
        "-y".to_string(),
        "-i".to_string(),
        src.to_string_lossy().into_owned(),
    ];
    match target_fmt {
        "mp4" => args.extend([
            "-c:v".into(),
            "libx264".into(),
            "-crf".into(),
            "18".into(),
            "-pix_fmt".into(),
            "yuv420p".into(),
            "-movflags".into(),
            "+faststart".into(),
        ]),
        "webm" => args.extend([
            "-c:v".into(),
            "libvpx-vp9".into(),
            "-crf".into(),
            "28".into(),
            "-b:v".into(),
            "0".into(),
        ]),
        "gif" => args.extend(["-vf".into(), "fps=20,scale=720:-1:flags=lanczos".into()]),
        _ => {}
    }
    args.push(dest.to_string_lossy().into_owned());

    let ok = match run_output(&ffmpeg, &os_args(&args), None, Duration::from_secs(600), cancel) {
        Ok(out) => out.status.success(),
        Err(err) => {
            let _ = fs::remove_file(dest);
            return Err(err);
        }
    };
    if !ok || !dest.is_file() {
        let _ = fs::remove_file(dest);
        return Err("格式转换失败：未生成目标文件。".to_string());
    }
    Ok(())
}

pub fn export_wallpaper_audio(
    wallpaper: &WallpaperItem,
    track_index: Option<usize>,
    export_directory: &str,
) -> Result<(usize, Option<String>), String> {
    let tracks: Vec<&String> = wallpaper
        .audio_paths
        .as_ref()
        .map(|list| list.iter().filter(|p| Path::new(p).is_file()).collect())
        .unwrap_or_default();
    if tracks.is_empty() {
        return Err("当前壁纸包内未检测到可导出的音频文件。".to_string());
    }

    let selected: Vec<&String> = match track_index {
        Some(idx) if idx < tracks.len() => vec![tracks[idx]],
        _ => tracks,
    };

    let audio_dir = std::path::absolute(Path::new(export_directory))
        .unwrap_or_else(|_| PathBuf::from(export_directory))
        .join("音频");
    fs::create_dir_all(&audio_dir).map_err(|e| format!("无法创建音频目录：{e}"))?;

    let safe_title = get_safe_file_name(&wallpaper.title, &wallpaper.workshop_id);
    let mut last_name = None;
    let mut exported = 0usize;

    for track_path in &selected {
        let src = Path::new(track_path);
        let ext = src
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| format!(".{e}"))
            .unwrap_or_default();
        let clean_track = get_safe_file_name(&clean_track_title(track_path), "bgm");
        let base_name = if selected.len() == 1 && clean_track.eq_ignore_ascii_case(&safe_title) {
            safe_title.clone()
        } else {
            format!("{safe_title} - {clean_track}")
        };
        let dest = get_unique_destination_path(&audio_dir, &format!("{base_name}{ext}"));
        fs::copy(src, &dest).map_err(|e| format!("导出音频失败：{e}"))?;
        last_name = dest.file_name().and_then(|n| n.to_str()).map(ToString::to_string);
        exported += 1;
    }

    Ok((exported, last_name))
}

pub fn is_archived_offline(item: &WallpaperItem, export_directory: &str) -> bool {
    if let Some(we_dir) = try_find_install_directory(Some(&item.workshop_directory)) {
        let my_projects = we_dir.join("projects").join("myprojects");
        let prefix = format!("WallPull_{}_", item.workshop_id);
        if let Ok(entries) = fs::read_dir(&my_projects) {
            for e in entries.flatten() {
                if e.path().is_dir()
                    && e.file_name()
                        .to_str()
                        .map(|n| n.starts_with(&prefix))
                        .unwrap_or(false)
                {
                    return true;
                }
            }
        }
    }

    let vault_dir = Path::new(export_directory).join("离线永久保险箱");
    let needle = format!("[{}]", item.workshop_id);
    if let Ok(entries) = fs::read_dir(&vault_dir) {
        for e in entries.flatten() {
            if e.path().is_dir()
                && e.file_name()
                    .to_str()
                    .map(|n| n.contains(&needle))
                    .unwrap_or(false)
            {
                return true;
            }
        }
    }
    false
}

pub fn resolve_archive_directory(
    settings: &AppSettings,
    detected_roots: &[String],
    items: &[WallpaperItem],
) -> PathBuf {
    let hint = settings
        .workshop_root
        .as_deref()
        .or_else(|| detected_roots.first().map(String::as_str))
        .or_else(|| items.first().map(|w| w.workshop_directory.as_str()));

    let my_projects = try_find_install_directory(hint).and_then(|we_dir| {
        if we_dir.join("projects").is_dir() {
            Some(we_dir.join("projects").join("myprojects"))
        } else {
            None
        }
    });

    let vault_dir = std::path::absolute(Path::new(&settings.export_directory))
        .unwrap_or_else(|_| PathBuf::from(&settings.export_directory))
        .join("离线永久保险箱");

    if let Some(ref mp) = my_projects {
        if let Ok(entries) = fs::read_dir(mp) {
            if entries.flatten().any(|e| {
                e.path().is_dir()
                    && e.file_name()
                        .to_str()
                        .map(|n| n.starts_with("WallPull_"))
                        .unwrap_or(false)
            }) {
                return mp.clone();
            }
        }
    }

    if let Ok(entries) = fs::read_dir(&vault_dir) {
        if entries.flatten().any(|e| {
            e.path().is_dir()
                && e.file_name()
                    .to_str()
                    .map(|n| n.contains('[') && n.contains(']'))
                    .unwrap_or(false)
        }) {
            return vault_dir;
        }
    }

    my_projects.unwrap_or(vault_dir)
}

pub fn archive_wallpapers_offline<FProgress>(
    items: &[WallpaperItem],
    export_directory: &str,
    cancel: Option<&AtomicBool>,
    mut on_progress: FProgress,
) -> Result<(Vec<String>, String, bool), String>
where
    FProgress: FnMut(ToolboxProgressPayload),
{
    if items.is_empty() {
        return Err("请先选择或收藏至少一张要加入离线保险箱的壁纸。".to_string());
    }
    let hint = items.first().map(|w| w.workshop_directory.as_str());
    let (archive_base, into_we) = if let Some(we_dir) = try_find_install_directory(hint) {
        if we_dir.join("projects").is_dir() {
            let dir = we_dir.join("projects").join("myprojects");
            fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
            (dir, true)
        } else {
            let dir = Path::new(export_directory).join("离线永久保险箱");
            fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
            (dir, false)
        }
    } else {
        let dir = Path::new(export_directory).join("离线永久保险箱");
        fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        (dir, false)
    };

    let mut archived_ids = Vec::new();
    let total = items.len();
    for (idx, item) in items.iter().enumerate() {
        if cancel.map(|c| c.load(Ordering::SeqCst)).unwrap_or(false) {
            return Err(CANCELLED_ERR.to_string());
        }
        let src_dir = Path::new(&item.workshop_directory);
        if item.workshop_directory.trim().is_empty() || !src_dir.is_dir() {
            continue;
        }
        let overall = ((idx as f64 / total.max(1) as f64) * 100.0).clamp(0.0, 99.5);
        on_progress(ToolboxProgressPayload {
            task_kind: "archive".to_string(),
            message: format!("正在离线典藏 ({}/{total}): {}", idx + 1, item.title),
            current_index: idx + 1,
            total_count: total,
            file_percent: None,
            overall_percent: Some(overall),
            saved_bytes: None,
            eta_seconds: None,
            cancellable: true,
        });
        let safe_title = get_safe_file_name(&item.title, &item.workshop_id);
        let folder_name = if into_we {
            format!("WallPull_{}_{}", item.workshop_id, safe_title)
        } else {
            format!("{safe_title} [{}]", item.workshop_id)
        };
        let dest_dir = archive_base.join(folder_name);
        if !dest_dir.exists() {
            copy_dir_recursive(src_dir, &dest_dir)?;
            let src_pj = src_dir.join("project.json");
            let dst_pj = dest_dir.join("project.json");
            if src_pj.is_file() {
                rewrite_as_offline_project_json(&src_pj, &dst_pj, Some("[离线典藏] "))?;
            }
        }
        archived_ids.push(item.id.clone());
    }

    if archived_ids.is_empty() {
        return Err("所选壁纸缺少有效的工坊原始目录，无法离线归档。".to_string());
    }
    Ok((
        archived_ids,
        archive_base.to_string_lossy().into_owned(),
        into_we,
    ))
}

pub fn recycle_workshop_wallpapers(
    targets: &[WallpaperItem],
    allowed_roots: &[String],
    export_directory: &str,
) -> Result<(HashSet<String>, usize, usize, i64), String> {
    if targets.is_empty() {
        return Err("找不到可清理的创意工坊壁纸文件夹。".to_string());
    }

    let mut seen_dirs = HashSet::new();
    let mut validated: Vec<(PathBuf, String, i64)> = Vec::new();
    for item in targets {
        if item.workshop_directory.trim().is_empty() {
            continue;
        }
        let abs = std::path::absolute(Path::new(&item.workshop_directory))
            .unwrap_or_else(|_| PathBuf::from(&item.workshop_directory));
        let key = abs
            .to_string_lossy()
            .trim_end_matches(['\\', '/'])
            .to_ascii_lowercase();
        if !abs.is_dir() || !seen_dirs.insert(key) {
            continue;
        }
        if !is_direct_child_of_allowed_root(&abs, allowed_roots) {
            return Err(format!("拒绝删除非创意工坊根目录下的路径：{}", abs.display()));
        }
        let size = if item.folder_size > 0 {
            item.folder_size
        } else {
            item.file_size
        };
        validated.push((abs, item.workshop_id.clone(), size));
    }

    if validated.is_empty() {
        return Err("找不到可清理的创意工坊壁纸文件夹。".to_string());
    }

    let we_install = try_find_install_directory(
        validated[0].0.to_str(),
    );
    let mut deleted_dirs = HashSet::new();
    let mut deleted_ws_ids = HashSet::new();
    let mut freed_bytes = 0i64;
    let mut attempted_close_we = false;

    for (dir, ws_id, size) in &validated {
        let key = dir
            .to_string_lossy()
            .trim_end_matches(['\\', '/'])
            .to_ascii_lowercase();
        if try_send_to_recycle_bin(dir) {
            deleted_dirs.insert(key);
            if !ws_id.is_empty() {
                deleted_ws_ids.insert(ws_id.clone());
            }
            freed_bytes += *size;
            continue;
        }

        if !attempted_close_we && is_wallpaper_engine_running() {
            attempted_close_we = true;
            send_control_command("closeWallpaper", &[]);
            std::thread::sleep(std::time::Duration::from_millis(350));
            if try_send_to_recycle_bin(dir) {
                deleted_dirs.insert(key);
                if !ws_id.is_empty() {
                    deleted_ws_ids.insert(ws_id.clone());
                }
                freed_bytes += *size;
            }
        }
    }

    if deleted_dirs.is_empty() {
        return Err("未能将所选壁纸移入回收站，请确认文件未被 Wallpaper Engine 或其他程序占用后重试。".to_string());
    }

    cleanup_deleted_artifacts(&deleted_ws_ids, we_install.as_deref(), export_directory);

    let total_targets = validated.len();
    let recycled_count = deleted_dirs.len();
    Ok((deleted_dirs, recycled_count, total_targets, freed_bytes))
}

fn cleanup_deleted_artifacts(
    deleted_ws_ids: &HashSet<String>,
    we_install: Option<&Path>,
    export_directory: &str,
) {
    if deleted_ws_ids.is_empty() {
        return;
    }
    if let Some(we_dir) = we_install {
        let my_proj = we_dir.join("projects").join("myprojects");
        if let Ok(entries) = fs::read_dir(&my_proj) {
            for e in entries.flatten() {
                let p = e.path();
                if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                    if deleted_ws_ids
                        .iter()
                        .any(|id| name.starts_with(&format!("WallPull_{id}_")))
                    {
                        let _ = try_send_to_recycle_bin(&p);
                    }
                }
            }
        }
    }

    let vault_dir = Path::new(export_directory).join("离线永久保险箱");
    if let Ok(entries) = fs::read_dir(&vault_dir) {
        for e in entries.flatten() {
            let p = e.path();
            if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                if deleted_ws_ids
                    .iter()
                    .any(|id| name.contains(&format!("[{id}]")))
                {
                    let _ = try_send_to_recycle_bin(&p);
                }
            }
        }
    }

    let cache = cache_root();
    let scenes = cache.join("scenes");
    for id in deleted_ws_ids {
        let s_dir = scenes.join(id);
        if s_dir.is_dir() {
            let _ = fs::remove_dir_all(s_dir);
        }
    }
    for sub in ["video-previews", "video-clips"] {
        let sub_dir = cache.join(sub);
        if let Ok(entries) = fs::read_dir(&sub_dir) {
            for e in entries.flatten() {
                let p = e.path();
                if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                    if deleted_ws_ids
                        .iter()
                        .any(|id| name.starts_with(&format!("{id}-")))
                    {
                        let _ = fs::remove_file(p);
                    }
                }
            }
        }
    }
}

fn is_direct_child_of_allowed_root(full_dir: &Path, allowed_roots: &[String]) -> bool {
    let Some(parent) = full_dir.parent() else {
        return false;
    };
    let parent_key = parent
        .to_string_lossy()
        .trim_end_matches(['\\', '/'])
        .to_ascii_lowercase();

    for root in allowed_roots {
        let norm = std::path::absolute(Path::new(root))
            .unwrap_or_else(|_| PathBuf::from(root))
            .to_string_lossy()
            .trim_end_matches(['\\', '/'])
            .to_ascii_lowercase();
        if norm == parent_key {
            return true;
        }
        if let Ok(canon) = fs::canonicalize(root) {
            let canon_key = canon
                .to_string_lossy()
                .trim_start_matches(r"\\?\")
                .trim_end_matches(['\\', '/'])
                .to_ascii_lowercase();
            if canon_key == parent_key {
                return true;
            }
        }
    }
    false
}

pub fn try_send_to_recycle_bin(path: &Path) -> bool {
    if !path.exists() {
        return false;
    }
    let abs = std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf());
    let mut from_wide: Vec<u16> = abs.as_os_str().encode_wide().collect();
    from_wide.push(0);
    from_wide.push(0);

    let mut op = SHFILEOPSTRUCTW {
        hwnd: Default::default(),
        wFunc: FO_DELETE,
        pFrom: PCWSTR(from_wide.as_ptr()),
        pTo: PCWSTR::null(),
        fFlags: (FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI).0 as u16,
        fAnyOperationsAborted: false.into(),
        hNameMappings: std::ptr::null_mut(),
        lpszProgressTitle: PCWSTR::null(),
    };
    let res = unsafe { SHFileOperationW(&mut op) };
    res == 0 && !op.fAnyOperationsAborted.as_bool()
}

pub fn resolve_primary_workshop_root(
    settings: &AppSettings,
    detected_roots: &[String],
) -> Option<String> {
    let configured = resolve_configured_workshop_roots(settings.workshop_root.as_deref());
    configured
        .into_iter()
        .next()
        .or_else(|| detected_roots.first().cloned())
}

pub fn get_migration_status(
    settings: &AppSettings,
    detected_roots: &[String],
    wallpapers: &[WallpaperItem],
) -> MigrationStatus {
    let primary = resolve_primary_workshop_root(settings, detected_roots);
    let Some(root_str) = primary.as_deref() else {
        return MigrationStatus {
            workshop_root: None,
            is_junction: false,
            link_target: None,
            total_bytes: 0,
        };
    };

    let p = Path::new(root_str);
    if !p.is_dir() {
        return MigrationStatus {
            workshop_root: Some(root_str.to_string()),
            is_junction: false,
            link_target: None,
            total_bytes: 0,
        };
    }

    let is_junction = fs::symlink_metadata(p)
        .map(|m| (m.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
        .unwrap_or(false);
    let link_target = if is_junction {
        fs::canonicalize(p)
            .ok()
            .map(|c| c.to_string_lossy().trim_start_matches(r"\\?\").to_string())
    } else {
        None
    };

    let mut total_bytes = 0i64;
    let mut seen_ws = HashSet::new();
    for w in wallpapers {
        if seen_ws.insert(w.workshop_id.as_str()) {
            total_bytes += if w.folder_size > 0 { w.folder_size } else { w.file_size };
        }
    }

    MigrationStatus {
        workshop_root: Some(root_str.to_string()),
        is_junction,
        link_target,
        total_bytes,
    }
}

pub fn migrate_workshop_with_junction<FProgress>(
    primary_root: &str,
    picked_dest_base: &Path,
    mut on_progress: FProgress,
) -> Result<(String, u64), String>
where
    FProgress: FnMut(&str),
{
    let src = std::path::absolute(Path::new(primary_root))
        .unwrap_or_else(|_| PathBuf::from(primary_root));
    if !src.is_dir() {
        return Err("未检测到可迁移的 Steam 创意工坊 431960 目录。".to_string());
    }
    let is_junc = fs::symlink_metadata(&src)
        .map(|m| (m.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
        .unwrap_or(false);
    if is_junc {
        return Err("当前工坊目录已经是跨盘联接，无需重复迁移。".to_string());
    }

    let dst_base = std::path::absolute(picked_dest_base)
        .unwrap_or_else(|_| picked_dest_base.to_path_buf());
    let src_lower = src.to_string_lossy().trim_end_matches('\\').to_ascii_lowercase();
    let dst_lower = dst_base.to_string_lossy().trim_end_matches('\\').to_ascii_lowercase();
    if src_lower == dst_lower || dst_lower.starts_with(&format!("{src_lower}\\")) {
        return Err("目标文件夹不能位于原 431960 目录内部。".to_string());
    }

    let root_anc = dst_base
        .ancestors()
        .last()
        .ok_or_else(|| "无法识别目标磁盘驱动器。".to_string())?;
    let mut root_str = root_anc.to_string_lossy().into_owned();
    if !root_str.ends_with('\\') {
        root_str.push('\\');
    }
    let drive_wide: Vec<u16> = OsStr::new(&root_str).encode_wide().chain(Some(0)).collect();
    let mut fs_name_buf = [0u16; 32];
    unsafe {
        GetVolumeInformationW(
            PCWSTR(drive_wide.as_ptr()),
            None,
            None,
            None,
            None,
            Some(&mut fs_name_buf),
        )
        .map_err(|e| format!("读取目标磁盘分区信息失败：{e}"))?;
    }
    let end = fs_name_buf
        .iter()
        .position(|&c| c == 0)
        .unwrap_or(fs_name_buf.len());
    let fs_name = String::from_utf16_lossy(&fs_name_buf[..end]);
    if !fs_name.eq_ignore_ascii_case("NTFS") {
        return Err(format!("目标磁盘为 {fs_name} 格式，NTFS 目录联接需要 NTFS 分区。"));
    }

    let mut avail = 0u64;
    unsafe {
        GetDiskFreeSpaceExW(PCWSTR(drive_wide.as_ptr()), Some(&mut avail), None, None)
            .map_err(|e| format!("检查目标磁盘可用空间失败：{e}"))?;
    }
    let needed = calculate_directory_bytes(&src);
    if avail < needed.saturating_add(512 * 1024 * 1024) {
        return Err(format!(
            "目标磁盘可用空间不足（需要至少 {}）。",
            format_byte_size(needed as i64)
        ));
    }

    let target_ws_dir = dst_base.join("WallpaperEngine_431960");
    if target_ws_dir.exists()
        && fs::read_dir(&target_ws_dir)
            .map(|mut d| d.next().is_some())
            .unwrap_or(false)
    {
        return Err(format!(
            "目标目录 {} 已存在且非空，请换一个空文件夹。",
            target_ws_dir.display()
        ));
    }

    on_progress(&format!("正在复制工坊文件到 {}…", target_ws_dir.display()));
    if let Err(e) = copy_dir_recursive(&src, &target_ws_dir) {
        let _ = fs::remove_dir_all(&target_ws_dir);
        return Err(e);
    }

    let clean_src = strip_verbatim_prefix(&src.to_string_lossy());
    let backup_orig = PathBuf::from(format!(
        "{}.wallpull_bak_{}",
        clean_src.trim_end_matches(['\\', '/']),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    if let Err(e) = fs::rename(&src, &backup_orig) {
        let _ = fs::remove_dir_all(&target_ws_dir);
        return Err(format!(
            "原目录被 Steam 或 Wallpaper Engine 占用，请先完全退出 Steam 与 Wallpaper Engine 后再执行搬家：{e}"
        ));
    }

    if let Err(err) = create_ntfs_junction(&src, &target_ws_dir) {
        let _ = fs::remove_dir(&src);
        if !src.exists() && backup_orig.exists() {
            let _ = fs::rename(&backup_orig, &src);
        }
        let _ = fs::remove_dir_all(&target_ws_dir);
        return Err(err);
    }

    let _ = try_send_to_recycle_bin(&backup_orig);
    Ok((target_ws_dir.to_string_lossy().into_owned(), needed))
}

pub fn create_ntfs_junction(junction_path: &Path, target_dir: &Path) -> Result<(), String> {
    const FSCTL_SET_REPARSE_POINT: u32 = 0x0009_00A4;
    const IO_REPARSE_TAG_MOUNT_POINT: u32 = 0xA000_0003;

    let abs_target = std::path::absolute(target_dir).unwrap_or_else(|_| target_dir.to_path_buf());
    let clean_target = strip_verbatim_prefix(&abs_target.to_string_lossy());
    let print_target = if clean_target.len() > 3 {
        clean_target.trim_end_matches(['\\', '/']).to_string()
    } else {
        clean_target
    };
    let substitute_target = format!(r"\??\{print_target}");

    let sub_units: Vec<u16> = OsStr::new(&substitute_target).encode_wide().collect();
    let print_units: Vec<u16> = OsStr::new(&print_target).encode_wide().collect();
    let sub_len_bytes = sub_units
        .len()
        .checked_mul(2)
        .and_then(|n| u16::try_from(n).ok())
        .ok_or_else(|| "目标路径过长，无法创建目录联接。".to_string())?;
    let print_len_bytes = print_units
        .len()
        .checked_mul(2)
        .and_then(|n| u16::try_from(n).ok())
        .ok_or_else(|| "目标路径过长，无法创建目录联接。".to_string())?;
    let print_offset_bytes = sub_len_bytes
        .checked_add(2)
        .ok_or_else(|| "目标路径过长。".to_string())?;
    let path_buf_bytes = (sub_units.len() + 1 + print_units.len() + 1) * 2;
    let reparse_data_length = u16::try_from(8 + path_buf_bytes)
        .map_err(|_| "目录联接重解析缓冲区超限。".to_string())?;

    let mut buffer = Vec::with_capacity(8 + reparse_data_length as usize);
    buffer.extend_from_slice(&IO_REPARSE_TAG_MOUNT_POINT.to_le_bytes());
    buffer.extend_from_slice(&reparse_data_length.to_le_bytes());
    buffer.extend_from_slice(&0u16.to_le_bytes());
    buffer.extend_from_slice(&0u16.to_le_bytes());
    buffer.extend_from_slice(&sub_len_bytes.to_le_bytes());
    buffer.extend_from_slice(&print_offset_bytes.to_le_bytes());
    buffer.extend_from_slice(&print_len_bytes.to_le_bytes());
    for u in &sub_units {
        buffer.extend_from_slice(&u.to_le_bytes());
    }
    buffer.extend_from_slice(&0u16.to_le_bytes());
    for u in &print_units {
        buffer.extend_from_slice(&u.to_le_bytes());
    }
    buffer.extend_from_slice(&0u16.to_le_bytes());

    fs::create_dir(junction_path).map_err(|e| format!("创建目录联接挂载点失败：{e}"))?;

    let junction_wide: Vec<u16> = junction_path
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    let handle = match unsafe {
        CreateFileW(
            PCWSTR(junction_wide.as_ptr()),
            FILE_GENERIC_WRITE.0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            None,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            None,
        )
    } {
        Ok(h) => h,
        Err(e) => {
            let _ = fs::remove_dir(junction_path);
            return Err(format!("打开目录联接句柄失败：{e}"));
        }
    };

    let mut bytes_returned = 0u32;
    let io_res = unsafe {
        DeviceIoControl(
            handle,
            FSCTL_SET_REPARSE_POINT,
            Some(buffer.as_ptr() as *const _),
            buffer.len() as u32,
            None,
            0,
            Some(&mut bytes_returned),
            None,
        )
    };
    unsafe {
        let _ = CloseHandle(handle);
    }
    if let Err(e) = io_res {
        let _ = fs::remove_dir(junction_path);
        return Err(format!("创建 NTFS 目录联接失败：{e}"));
    }
    Ok(())
}

pub fn slim_workshop_videos<FProgress>(
    targets: &[WallpaperItem],
    cancel: Option<&AtomicBool>,
    mut on_progress: FProgress,
) -> Result<(usize, i64), String>
where
    FProgress: FnMut(ToolboxProgressPayload),
{
    if targets.is_empty() {
        return Err("当前没有找到需要瘦身压制的大体积 MP4 视频壁纸。".to_string());
    }
    let ffmpeg = find_executable("ffmpeg.exe")
        .ok_or_else(|| "未找到 ffmpeg.exe，无法进行 H.265 无损感瘦身压制。".to_string())?;
    let ffprobe = find_executable("ffprobe.exe");

    let mut slimmed = 0usize;
    let mut saved = 0i64;
    let total = targets.len();

    for (i, item) in targets.iter().enumerate() {
        if cancel.map(|c| c.load(Ordering::SeqCst)).unwrap_or(false) {
            return Err(CANCELLED_ERR.to_string());
        }
        let src = Path::new(&item.source_path);
        if !src.is_file() {
            continue;
        }
        let old_bytes = fs::metadata(src).map(|m| m.len() as i64).unwrap_or(0);
        let duration_secs = probe_or_fallback(src, ffprobe.as_deref())
            .duration_seconds
            .filter(|d| *d > 0.05);
        let stem = src.file_stem().and_then(|s| s.to_str()).unwrap_or("video");
        let seq = TEMP_SEQ.fetch_add(1, Ordering::Relaxed);
        let parent = src.parent().unwrap_or(Path::new("."));
        let tmp = parent.join(format!(".{stem}.h265_tmp_{}_{}.mp4", std::process::id(), seq));

        let base_overall = ((i as f64 / total as f64) * 100.0).clamp(0.0, 99.5);
        on_progress(ToolboxProgressPayload {
            task_kind: "slim-videos".to_string(),
            message: format!("正在压制 ({}/{})：{}", i + 1, total, item.title),
            current_index: i + 1,
            total_count: total,
            file_percent: duration_secs.map(|_| 0.0),
            overall_percent: Some(base_overall),
            saved_bytes: (saved > 0).then_some(saved),
            eta_seconds: None,
            cancellable: true,
        });
        let mut args = os_args(["-y", "-i"]);
        args.push(src.as_os_str().to_os_string());
        args.extend(os_args([
            "-c:v",
            "libx265",
            "-crf",
            "23",
            "-preset",
            "medium",
            "-tag:v",
            "hvc1",
            "-c:a",
            "copy",
            "-movflags",
            "+faststart",
        ]));
        args.push(tmp.as_os_str().to_os_string());

        let started = std::time::Instant::now();
        let ok = match run_ffmpeg_progress(
            &ffmpeg,
            &args,
            None,
            Duration::from_secs(900),
            cancel,
            |tick| {
                let file_pct = duration_secs
                    .map(|dur| ((tick.out_time_secs / dur) * 100.0).clamp(0.0, 99.5));
                let overall_pct = if let Some(fp) = file_pct {
                    (((i as f64) + fp / 100.0) / (total as f64) * 100.0).clamp(0.0, 99.8)
                } else {
                    base_overall
                };
                let eta_seconds = duration_secs.and_then(|dur| {
                    let remain = (dur - tick.out_time_secs).max(0.0);
                    if let Some(sp) = tick.speed_factor {
                        if sp > 0.01 {
                            return Some((remain / sp).ceil() as u64);
                        }
                    }
                    let frac = (tick.out_time_secs / dur).clamp(0.0, 1.0);
                    if frac >= 0.03 {
                        let elapsed = started.elapsed().as_secs_f64();
                        Some(((elapsed / frac) * (1.0 - frac)).ceil() as u64)
                    } else {
                        None
                    }
                });
                on_progress(ToolboxProgressPayload {
                    task_kind: "slim-videos".to_string(),
                    message: format!("正在压制 ({}/{})：{}", i + 1, total, item.title),
                    current_index: i + 1,
                    total_count: total,
                    file_percent: file_pct,
                    overall_percent: Some(overall_pct),
                    saved_bytes: (saved > 0).then_some(saved),
                    eta_seconds,
                    cancellable: true,
                });
            },
        ) {
            Ok(success) => success,
            Err(err) => {
                remove_file_with_retry(&tmp);
                return Err(err);
            }
        };

        if !ok || !tmp.is_file() {
            remove_file_with_retry(&tmp);
            continue;
        }
        let new_bytes = fs::metadata(&tmp).map(|m| m.len() as i64).unwrap_or(0);
        if new_bytes <= 1024 || new_bytes >= (old_bytes as f64 * 0.92) as i64 {
            remove_file_with_retry(&tmp);
            continue;
        }

        let bak = parent.join(format!(".{stem}.orig_bak_{}_{}.mp4", std::process::id(), seq));
        if fs::rename(src, &bak).is_err() {
            remove_file_with_retry(&tmp);
            continue;
        }
        if fs::rename(&tmp, src).is_err() {
            let _ = fs::rename(&bak, src);
            remove_file_with_retry(&tmp);
            continue;
        }
        if !try_send_to_recycle_bin(&bak) {
            remove_file_with_retry(&bak);
        }
        saved += old_bytes - new_bytes;
        slimmed += 1;
    }

    Ok((slimmed, saved))
}

pub fn pick_toolbox_media_files() -> Vec<PickedToolboxFile> {
    let picked = rfd::FileDialog::new()
        .add_filter(
            "媒体文件",
            &[
                "png", "jpg", "jpeg", "webp", "avif", "bmp", "gif", "ico", "mp4", "webm", "mkv",
                "mov", "avi", "mp3", "flac", "wav", "ogg", "m4a",
            ],
        )
        .pick_files();
    let Some(paths) = picked else {
        return Vec::new();
    };
    paths
        .into_iter()
        .filter(|p| p.is_file())
        .map(|p| {
            let ext = p
                .extension()
                .and_then(|e| e.to_str())
                .map(|e| e.to_ascii_lowercase())
                .unwrap_or_default();
            let kind = match ext.as_str() {
                "png" | "jpg" | "jpeg" | "webp" | "avif" | "bmp" | "gif" | "ico" => "image",
                "mp4" | "webm" | "mkv" | "mov" | "avi" => "video",
                _ => "audio",
            }
            .to_string();
            let size = fs::metadata(&p).map(|m| m.len() as i64).unwrap_or(0);
            let name = p
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("file")
                .to_string();
            PickedToolboxFile {
                path: p.to_string_lossy().into_owned(),
                name,
                size,
                ext,
                kind,
            }
        })
        .collect()
}

pub fn convert_toolbox_media<FProgress>(
    paths: &[String],
    target_format: &str,
    strip_metadata: bool,
    trim_transparency: bool,
    export_directory: &str,
    cancel: Option<&AtomicBool>,
    mut on_progress: FProgress,
) -> Result<(usize, String), String>
where
    FProgress: FnMut(ToolboxProgressPayload),
{
    let valid_paths: Vec<PathBuf> = paths
        .iter()
        .map(PathBuf::from)
        .filter(|p| p.is_file())
        .collect();
    if valid_paths.is_empty() {
        return Err("没有找到有效的待转换文件。".to_string());
    }

    let out_folder = std::path::absolute(Path::new(export_directory))
        .unwrap_or_else(|_| PathBuf::from(export_directory))
        .join("格式工坊");
    fs::create_dir_all(&out_folder).map_err(|e| format!("无法创建格式工坊目录：{e}"))?;

    let fmt = target_format.trim().to_ascii_lowercase();
    let ffprobe = find_executable("ffprobe.exe");
    let mut success_count = 0usize;
    let total = valid_paths.len();

    for (i, src) in valid_paths.iter().enumerate() {
        if cancel.map(|c| c.load(Ordering::SeqCst)).unwrap_or(false) {
            return Err(CANCELLED_ERR.to_string());
        }
        let name = src
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("file");
        let base_name = get_safe_file_name(
            src.file_stem().and_then(|s| s.to_str()).unwrap_or("item"),
            &format!("item-{}", i + 1),
        );
        let base_overall = ((i as f64 / total as f64) * 100.0).clamp(0.0, 99.5);
        on_progress(ToolboxProgressPayload {
            task_kind: "convert".to_string(),
            message: format!("格式工坊处理中 ({}/{}): {name}", i + 1, total),
            current_index: i + 1,
            total_count: total,
            file_percent: None,
            overall_percent: Some(base_overall),
            saved_bytes: None,
            eta_seconds: None,
            cancellable: true,
        });

        if fmt == "ico" {
            let dest_ico = get_unique_destination_path(&out_folder, &format!("{base_name}.ico"));
            pack_multi_size_ico_pure_rust(src, &dest_ico)?;
            success_count += 1;
            continue;
        }

        if matches!(fmt.as_str(), "png" | "jpg" | "webp") && !trim_transparency {
            if let Ok(img) = image::open(src) {
                let (ext, img_fmt) = match fmt.as_str() {
                    "jpg" => ("jpg", ImageFormat::Jpeg),
                    "webp" => ("webp", ImageFormat::WebP),
                    _ => ("png", ImageFormat::Png),
                };
                let dest = get_unique_destination_path(&out_folder, &format!("{base_name}.{ext}"));
                if img.save_with_format(&dest, img_fmt).is_ok() {
                    success_count += 1;
                    continue;
                }
            }
        }

        let ffmpeg = find_executable("ffmpeg.exe").ok_or_else(|| {
            "该高级音视频/特效格式转换需要 ffmpeg.exe，请放入同级 Tools 目录或配置系统 PATH。".to_string()
        })?;
        let duration_secs = probe_or_fallback(src, ffprobe.as_deref())
            .duration_seconds
            .filter(|d| *d > 0.05);
        let (out_ext, args) = build_ffmpeg_args(src, &fmt, strip_metadata, trim_transparency);
        let dest = get_unique_destination_path(&out_folder, &format!("{base_name}.{out_ext}"));
        let mut full_args = args;
        full_args.push(dest.to_string_lossy().into_owned());

        let started = std::time::Instant::now();
        let ok = run_ffmpeg_progress(
            &ffmpeg,
            &os_args(&full_args),
            None,
            Duration::from_secs(600),
            cancel,
            |tick| {
                let file_pct = duration_secs
                    .map(|dur| ((tick.out_time_secs / dur) * 100.0).clamp(0.0, 99.5));
                let overall_pct = if let Some(fp) = file_pct {
                    (((i as f64) + fp / 100.0) / (total as f64) * 100.0).clamp(0.0, 99.8)
                } else {
                    base_overall
                };
                let eta_seconds = duration_secs.and_then(|dur| {
                    let remain = (dur - tick.out_time_secs).max(0.0);
                    if let Some(sp) = tick.speed_factor {
                        if sp > 0.01 {
                            return Some((remain / sp).ceil() as u64);
                        }
                    }
                    let frac = (tick.out_time_secs / dur).clamp(0.0, 1.0);
                    if frac >= 0.03 {
                        let elapsed = started.elapsed().as_secs_f64();
                        Some(((elapsed / frac) * (1.0 - frac)).ceil() as u64)
                    } else {
                        None
                    }
                });
                on_progress(ToolboxProgressPayload {
                    task_kind: "convert".to_string(),
                    message: format!("格式工坊处理中 ({}/{}): {name}", i + 1, total),
                    current_index: i + 1,
                    total_count: total,
                    file_percent: file_pct,
                    overall_percent: Some(overall_pct),
                    saved_bytes: None,
                    eta_seconds,
                    cancellable: true,
                });
            },
        )
        .inspect_err(|_| {
            remove_file_with_retry(&dest);
        })?;
        if !ok || !dest.is_file() {
            remove_file_with_retry(&dest);
            return Err(format!("转换 {name} 失败。"));
        }
        success_count += 1;
    }

    Ok((success_count, out_folder.to_string_lossy().into_owned()))
}

fn build_ffmpeg_args(
    src: &Path,
    fmt: &str,
    strip_metadata: bool,
    _trim_transparency: bool,
) -> (&'static str, Vec<String>) {
    let mut args = vec![
        "-y".to_string(),
        "-i".to_string(),
        src.to_string_lossy().into_owned(),
    ];
    if strip_metadata {
        args.extend(["-map_metadata".into(), "-1".into()]);
    }
    match fmt {
        "jpg" => {
            args.extend(["-q:v".into(), "2".into()]);
            ("jpg", args)
        }
        "webp" => {
            args.extend(["-quality".into(), "92".into()]);
            ("webp", args)
        }
        "avif" => {
            args.extend([
                "-c:v".into(),
                "libaom-av1".into(),
                "-still-picture".into(),
                "1".into(),
                "-crf".into(),
                "24".into(),
                "-b:v".into(),
                "0".into(),
            ]);
            ("avif", args)
        }
        "mp4" => {
            args.extend([
                "-c:v".into(),
                "libx264".into(),
                "-crf".into(),
                "18".into(),
                "-pix_fmt".into(),
                "yuv420p".into(),
                "-movflags".into(),
                "+faststart".into(),
            ]);
            ("mp4", args)
        }
        "mp4-h265" => {
            args.extend([
                "-c:v".into(),
                "libx265".into(),
                "-crf".into(),
                "23".into(),
                "-tag:v".into(),
                "hvc1".into(),
                "-c:a".into(),
                "copy".into(),
                "-movflags".into(),
                "+faststart".into(),
            ]);
            ("mp4", args)
        }
        "webm" => {
            args.extend([
                "-c:v".into(),
                "libvpx-vp9".into(),
                "-crf".into(),
                "28".into(),
                "-b:v".into(),
                "0".into(),
            ]);
            ("webm", args)
        }
        "gif" => {
            args.extend([
                "-vf".into(),
                "fps=18,scale=640:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse".into(),
            ]);
            ("gif", args)
        }
        "extract-mp3" | "mp3" => {
            args.extend(["-vn".into(), "-c:a".into(), "libmp3lame".into(), "-b:a".into(), "320k".into()]);
            ("mp3", args)
        }
        "extract-flac" | "flac" => {
            args.extend(["-vn".into(), "-c:a".into(), "flac".into()]);
            ("flac", args)
        }
        "mute-mp4" => {
            args.extend(["-c:v".into(), "copy".into(), "-an".into(), "-movflags".into(), "+faststart".into()]);
            ("mp4", args)
        }
        "wav" => {
            args.extend(["-vn".into(), "-c:a".into(), "pcm_s16le".into()]);
            ("wav", args)
        }
        "ogg" => {
            args.extend(["-vn".into(), "-c:a".into(), "libvorbis".into(), "-q:a".into(), "7".into()]);
            ("ogg", args)
        }
        _ => ("png", args),
    }
}

pub fn unpack_external_packages<FProgress>(
    export_directory: &str,
    cancel: Option<&AtomicBool>,
    mut on_progress: FProgress,
) -> Result<Option<(usize, usize, String)>, String>
where
    FProgress: FnMut(ToolboxProgressPayload),
{
    let Some(picked) = rfd::FileDialog::new()
        .add_filter("Wallpaper Engine 包 (.pkg, .tex)", &["pkg", "tex"])
        .pick_files()
    else {
        return Ok(None);
    };
    if picked.is_empty() {
        return Ok(None);
    }

    let unpack_root = std::path::absolute(Path::new(export_directory))
        .unwrap_or_else(|_| PathBuf::from(export_directory))
        .join("野生解包");
    fs::create_dir_all(&unpack_root).map_err(|e| format!("无法创建解包输出目录：{e}"))?;

    let mut total_files = 0usize;
    let mut total_textures = 0usize;
    let total = picked.len();

    for (idx, src) in picked.into_iter().enumerate() {
        if cancel.map(|c| c.load(Ordering::SeqCst)).unwrap_or(false) {
            return Err(CANCELLED_ERR.to_string());
        }
        if !src.is_file() {
            continue;
        }
        let file_name = src
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("package");
        let overall = ((idx as f64 / total.max(1) as f64) * 100.0).clamp(0.0, 99.5);
        on_progress(ToolboxProgressPayload {
            task_kind: "unpack".to_string(),
            message: format!("正在解包 ({}/{total})：{file_name}", idx + 1),
            current_index: idx + 1,
            total_count: total,
            file_percent: None,
            overall_percent: Some(overall),
            saved_bytes: None,
            eta_seconds: None,
            cancellable: true,
        });
        let safe_name = get_safe_file_name(
            src.file_stem().and_then(|s| s.to_str()).unwrap_or("package"),
            "package",
        );
        let ext = src
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| e.to_ascii_lowercase())
            .unwrap_or_default();

        if ext == "tex" {
            let dest_png = get_unique_destination_path(&unpack_root, &format!("{safe_name}.png"));
            if decode_tex_file_to_png(&src, &dest_png) {
                total_files += 1;
                total_textures += 1;
            } else if let Some(ffmpeg) = find_executable("ffmpeg.exe") {
                let mut ff_args = os_args(["-y", "-i"]);
                ff_args.push(src.as_os_str().to_os_string());
                ff_args.extend(os_args(["-frames:v", "1"]));
                ff_args.push(dest_png.as_os_str().to_os_string());
                let ok = run_status(&ffmpeg, &ff_args, None, Duration::from_secs(30), cancel)
                    .inspect_err(|_| remove_file_with_retry(&dest_png))
                    .unwrap_or(false);
                if ok && fs::metadata(&dest_png).map(|m| m.len() > 0).unwrap_or(false) {
                    total_files += 1;
                    total_textures += 1;
                } else {
                    remove_file_with_retry(&dest_png);
                }
            }
        } else if ext == "pkg" {
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs() % 100_000)
                .unwrap_or(0);
            let pkg_out = unpack_root.join(format!("{safe_name} [{stamp}]"));
            let summary = unpack_pkg_file(&src, &pkg_out, true)?;
            total_files += summary.extracted_files;
            total_textures += summary.decoded_textures;
        }
    }

    if total_files == 0 {
        return Err("未能从所选外部包内解出有效图像或资源。".to_string());
    }
    Ok(Some((
        total_files,
        total_textures,
        unpack_root.to_string_lossy().into_owned(),
    )))
}

fn copy_dir_recursive(src: &Path, dst: &Path) -> Result<(), String> {
    copy_dir_recursive_inner(src, dst, 0)
}

fn copy_dir_recursive_inner(src: &Path, dst: &Path, depth: u32) -> Result<(), String> {
    if depth > 16 {
        return Err("目录嵌套层级过深，已中止复制以防止无限递归。".to_string());
    }
    fs::create_dir_all(dst).map_err(|e| format!("创建目录失败：{e}"))?;
    let entries = fs::read_dir(src).map_err(|e| format!("读取目录失败：{e}"))?;
    for entry in entries.flatten() {
        let p = entry.path();
        if is_reparse_point(&p) {
            continue;
        }
        let Ok(meta) = fs::symlink_metadata(&p) else {
            continue;
        };
        let target = dst.join(entry.file_name());
        if meta.is_dir() {
            copy_dir_recursive_inner(&p, &target, depth + 1)?;
        } else if meta.is_file() {
            fs::copy(&p, &target).map_err(|e| format!("复制文件失败：{e}"))?;
        }
    }
    Ok(())
}

pub fn resolve_target_items(
    ids: &[String],
    wallpapers: &std::collections::HashMap<String, WallpaperItem>,
) -> Vec<WallpaperItem> {
    let mut seen_ids = HashSet::new();
    let mut out = Vec::new();
    for id in ids {
        if let Some(item) = wallpapers.get(id) {
            if seen_ids.insert(item.id.clone()) {
                out.push(item.clone());
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_ntfs_junction_works_with_shell_metacharacters() {
        let base = std::env::temp_dir().join(format!("wallpull_junc_{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        let target = base.join("Target & (Test) ! ^ %TEMP%");
        let junc = base.join("Link & Mount");
        fs::create_dir_all(&target).unwrap();
        fs::write(target.join("hello.txt"), b"junction_ok").unwrap();

        create_ntfs_junction(&junc, &target).expect("create native NTFS junction");
        assert!(is_reparse_point(&junc));
        let read_back = fs::read(junc.join("hello.txt")).expect("read through junction");
        assert_eq!(&read_back, b"junction_ok");

        // Remove junction only (must preserve target files) and test loop guard
        let _ = fs::remove_dir(&junc);
        assert!(target.join("hello.txt").is_file());
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn copy_dir_recursive_skips_child_reparse_loops() {
        let base = std::env::temp_dir().join(format!("wallpull_loop_{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        let src = base.join("src");
        let dst = base.join("dst");
        fs::create_dir_all(&src).unwrap();
        fs::write(src.join("real.txt"), b"ok").unwrap();
        let loop_junc = src.join("self_loop");
        create_ntfs_junction(&loop_junc, &src).expect("create self-loop junction");

        copy_dir_recursive(&src, &dst).expect("copy must terminate despite loop junction");
        assert!(dst.join("real.txt").is_file());
        assert!(!dst.join("self_loop").exists());

        let _ = fs::remove_dir(&loop_junc);
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn semver_comparison_detects_newer_releases() {
        assert!(is_newer_version("v1.0.1", "1.0.0"));
        assert!(is_newer_version("v1.1.0", "1.0.9"));
        assert!(is_newer_version("V2.0.0", "1.9.9"));
        assert!(!is_newer_version("v1.0.0", "1.0.0"));
        assert!(!is_newer_version("1.0.0", "1.0.1"));
        assert!(!is_newer_version("v0.9.9", "1.0.0"));
        assert!(!is_newer_version("v1.0.0-beta.1", "1.0.0"));
        assert!(is_newer_version("v1.0.1-rc.1", "1.0.0"));
    }

    #[test]
    fn extract_release_tag_parses_absolute_and_relative_locations() {
        assert_eq!(
            extract_release_tag_from_location("https://github.com/XiaonanXY/WallPull/releases/tag/v1.0.0"),
            Some((
                "v1.0.0".to_string(),
                "https://github.com/XiaonanXY/WallPull/releases/tag/v1.0.0".to_string()
            ))
        );
        assert_eq!(
            extract_release_tag_from_location("/XiaonanXY/WallPull/releases/tag/v1.2.3/"),
            Some((
                "v1.2.3".to_string(),
                "https://github.com/XiaonanXY/WallPull/releases/tag/v1.2.3".to_string()
            ))
        );
        assert_eq!(
            extract_release_tag_from_location("https://github.com/XiaonanXY/WallPull/releases"),
            None
        );
    }

    #[test]
    #[ignore]
    fn live_github_release_redirect_check() {
        let (has_update, tag, url) =
            check_latest_release("1.0.0").expect("live release check should succeed via redirect");
        assert!(!has_update);
        assert!(!tag.is_empty());
        assert!(url.contains("/releases/tag/"));
    }
}
