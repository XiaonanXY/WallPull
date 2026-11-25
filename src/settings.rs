use crate::models::{AppSettings, GpuAdapterInfo, default_export_directory};
use regex::Regex;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use winreg::RegKey;
use winreg::enums::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE};
use windows::Win32::Storage::FileSystem::{GetDriveTypeW, GetLogicalDrives};
use windows::core::PCWSTR;

const WALLPAPER_ENGINE_APP_ID: &str = "431960";
const DISPLAY_CLASS_KEY: &str =
    r"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}";

pub fn local_app_data_root() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::var_os("USERPROFILE")
                .map(|p| PathBuf::from(p).join("AppData").join("Local"))
                .unwrap_or_else(std::env::temp_dir)
        });
    base.join("WallpaperVault")
}

pub fn cache_root() -> PathBuf {
    local_app_data_root().join("Cache")
}

pub fn settings_file_path() -> PathBuf {
    local_app_data_root().join("settings.json")
}

pub fn load_settings_from(path: &Path) -> AppSettings {
    let Ok(bytes) = fs::read(path) else {
        return AppSettings::default();
    };
    serde_json::from_slice::<AppSettings>(&bytes)
        .map(sanitize_settings)
        .unwrap_or_default()
}

pub fn save_settings_to(path: &Path, settings: &AppSettings) -> Result<(), String> {
    let dir = path
        .parent()
        .ok_or_else(|| "设置文件目录无效。".to_string())?;
    fs::create_dir_all(dir).map_err(|e| format!("无法创建设置目录：{e}"))?;

    let tmp_name = format!(
        ".settings.{}.{}.tmp",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    );
    let tmp_path = dir.join(tmp_name);
    let json = serde_json::to_vec_pretty(settings)
        .map_err(|e| format!("序列化设置失败：{e}"))?;
    fs::write(&tmp_path, json).map_err(|e| format!("写入设置失败：{e}"))?;
    if let Err(err) = fs::rename(&tmp_path, path) {
        let _ = fs::remove_file(path);
        if let Err(err2) = fs::rename(&tmp_path, path) {
            let _ = fs::remove_file(&tmp_path);
            return Err(format!("保存设置失败：{err} / {err2}"));
        }
    }
    Ok(())
}

pub fn sanitize_settings(updated: AppSettings) -> AppSettings {
    let export_dir = if updated.export_directory.trim().is_empty() {
        default_export_directory()
    } else {
        normalize_path_str(updated.export_directory.trim())
    };

    let workshop_root = updated
        .workshop_root
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(normalize_path_str);

    let spark_color = if is_hex_color(&updated.spark_color) {
        updated.spark_color
    } else {
        "#7c3aed".to_string()
    };

    let mut fav_seen = HashSet::new();
    let favorite_ids = updated
        .favorite_ids
        .into_iter()
        .filter(|id| !id.trim().is_empty())
        .filter(|id| fav_seen.insert(id.clone()))
        .collect();

    AppSettings {
        workshop_root,
        export_directory: export_dir,
        auto_scan: updated.auto_scan,
        parse_scenes: true,
        high_quality_video_previews: true,
        hover_video_preview: updated.hover_video_preview,
        card_mode: if matches!(updated.card_mode.as_str(), "magnet" | "tilt") {
            updated.card_mode
        } else {
            "tilt".to_string()
        },
        spark_size_percent: updated.spark_size_percent.max(0),
        spark_color,
        selection_border_mode: if matches!(updated.selection_border_mode.as_str(), "snake" | "orbit")
        {
            updated.selection_border_mode
        } else {
            "snake".to_string()
        },
        hardware_acceleration_mode: if updated.hardware_acceleration_mode == "cpu" {
            "cpu".to_string()
        } else {
            "gpu".to_string()
        },
        theme_mode: if updated.theme_mode == "dark" {
            "dark".to_string()
        } else {
            "light".to_string()
        },
        navigation_style: if updated.navigation_style == "drawer" {
            "drawer".to_string()
        } else {
            "island".to_string()
        },
        toolbox_layout: if matches!(updated.toolbox_layout.as_str(), "sidebar" | "bento" | "dual") {
            updated.toolbox_layout
        } else {
            "bento".to_string()
        },
        close_to_tray: updated.close_to_tray,
        show_archived_badge: updated.show_archived_badge,
        favorite_ids,
        localsend_enabled: updated.localsend_enabled,
        localsend_alias: {
            let trimmed = updated.localsend_alias.trim();
            if trimmed.is_empty() {
                "WallPull PC".to_string()
            } else {
                trimmed.chars().take(48).collect()
            }
        },
        media_filter: if matches!(updated.media_filter.as_str(), "all" | "image" | "video" | "favorite") {
            updated.media_filter
        } else {
            "all".to_string()
        },
        spec_filter: if matches!(updated.spec_filter.as_str(), "all" | "4k" | "landscape" | "portrait" | "audio" | "layered") {
            updated.spec_filter
        } else {
            "all".to_string()
        },
        rating_filter: if matches!(updated.rating_filter.as_str(), "all" | "everyone" | "mature") {
            updated.rating_filter
        } else {
            "all".to_string()
        },
        sort_by: if matches!(updated.sort_by.as_str(), "default" | "size" | "resolution" | "title") {
            updated.sort_by
        } else {
            "default".to_string()
        },
        color_filter: updated.color_filter.filter(|c| {
            matches!(c.as_str(), "dark" | "light" | "blue" | "purple" | "green" | "warm")
        }),
    }
}

pub fn normalize_path_str(input: &str) -> String {
    crate::models::clean_path_str(Path::new(input))
}

pub fn is_hex_color(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 7 && bytes[0] == b'#' && bytes[1..].iter().all(|b| b.is_ascii_hexdigit())
}

pub fn calculate_cache_size_bytes() -> i64 {
    let root = cache_root();
    if !root.exists() {
        return 0;
    }
    calculate_directory_bytes(&root) as i64
}

pub fn calculate_directory_bytes(dir: &Path) -> u64 {
    let mut total = 0u64;
    let mut stack = vec![(dir.to_path_buf(), 0u32)];
    while let Some((cur, depth)) = stack.pop() {
        let Ok(entries) = fs::read_dir(&cur) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if crate::models::is_reparse_point(&path) {
                continue;
            }
            let Ok(meta) = fs::symlink_metadata(&path) else {
                continue;
            };
            if meta.is_dir() {
                if depth < 16 {
                    stack.push((path, depth + 1));
                }
            } else if meta.is_file() {
                total = total.saturating_add(meta.len());
            }
        }
    }
    total
}

pub fn clear_media_cache() -> (f64, i64) {
    let root = cache_root();
    let before = calculate_cache_size_bytes();
    for sub in [
        "frame-captures",
        "layer-studio",
        "drag-staging",
        "video-previews",
        "video-clips",
        "previews",
    ] {
        let sub_dir = root.join(sub);
        if sub_dir.exists() && !crate::models::is_reparse_point(&sub_dir) {
            remove_files_in_dir(&sub_dir, 0);
        }
    }
    let catalog = root.join("wallpaper-catalog.json");
    if catalog.exists() {
        let _ = fs::remove_file(&catalog);
    }
    let after = calculate_cache_size_bytes();
    let freed_mb = ((before - after).max(0) as f64) / (1024.0 * 1024.0);
    (freed_mb, after)
}

fn remove_files_in_dir(dir: &Path, depth: u32) {
    if depth > 16 {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if crate::models::is_reparse_point(&path) {
            continue;
        }
        let Ok(meta) = fs::symlink_metadata(&path) else {
            continue;
        };
        if meta.is_dir() {
            remove_files_in_dir(&path, depth + 1);
        } else if meta.is_file() {
            let _ = fs::remove_file(&path);
        }
    }
}

pub fn get_gpu_adapters() -> Vec<GpuAdapterInfo> {
    let virtual_keywords = [
        "virtual",
        "basic render",
        "gameviewer",
        "parsec",
        "indirect",
        "mirror",
        "remote",
        "sunshine",
    ];
    let mut adapters: Vec<GpuAdapterInfo> = Vec::new();
    let mut seen_names: HashSet<String> = HashSet::new();

    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let Ok(class_key) = hklm.open_subkey(DISPLAY_CLASS_KEY) else {
        return adapters;
    };

    for sub_name in class_key.enum_keys().flatten() {
        if sub_name.len() != 4 || !sub_name.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        let Ok(adapter_key) = class_key.open_subkey(&sub_name) else {
            continue;
        };
        let Ok(desc): Result<String, _> = adapter_key.get_value("DriverDesc") else {
            continue;
        };
        let trimmed = desc.trim();
        if trimmed.is_empty() {
            continue;
        }
        let lower = trimmed.to_ascii_lowercase();
        if virtual_keywords.iter().any(|kw| lower.contains(kw)) {
            continue;
        }
        if !seen_names.insert(lower) {
            continue;
        }

        let mem = read_adapter_memory_bytes(&adapter_key);
        adapters.push(GpuAdapterInfo {
            name: trimmed.to_string(),
            memory_bytes: mem,
        });
    }

    adapters.sort_by(|a, b| b.memory_bytes.cmp(&a.memory_bytes));
    adapters.truncate(1);
    adapters
}

fn read_adapter_memory_bytes(key: &RegKey) -> i64 {
    if let Ok(qw) = key.get_value::<u64, _>("HardwareInformation.qwMemorySize") {
        if qw > 0 {
            return qw as i64;
        }
    }
    if let Ok(dw) = key.get_value::<u32, _>("HardwareInformation.MemorySize") {
        if dw > 0 {
            return dw as i64;
        }
    }
    if let Ok(val) = key.get_raw_value("HardwareInformation.MemorySize") {
        if val.bytes.len() >= 8 {
            let v = u64::from_le_bytes(val.bytes[0..8].try_into().unwrap_or([0; 8]));
            if v > 0 {
                return v as i64;
            }
        } else if val.bytes.len() >= 4 {
            let v = u32::from_le_bytes(val.bytes[0..4].try_into().unwrap_or([0; 4]));
            if v > 0 {
                return v as i64;
            }
        }
    }
    0
}

fn library_path_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"(?i)"path"\s+"([^"]+)""#).expect("valid vdf regex"))
}

pub fn discover_steam_library_roots() -> Vec<PathBuf> {
    collect_steam_library_roots(None)
}

fn collect_steam_library_roots(seed_roots: Option<&[PathBuf]>) -> Vec<PathBuf> {
    let steam_roots = if let Some(seeds) = seed_roots {
        seeds.to_vec()
    } else {
        discover_steam_roots()
    };

    let mut lib_roots: Vec<PathBuf> = Vec::new();
    let mut seen_lib_keys: HashSet<String> = HashSet::new();

    for steam_root in steam_roots {
        add_dir_if_valid(&mut lib_roots, &mut seen_lib_keys, &steam_root);
        let vdf = steam_root.join("steamapps").join("libraryfolders.vdf");
        if let Ok(content) = fs::read_to_string(&vdf) {
            for cap in library_path_regex().captures_iter(&content) {
                if let Some(m) = cap.get(1) {
                    let unescaped = m.as_str().replace(r"\\", r"\");
                    add_dir_if_valid(&mut lib_roots, &mut seen_lib_keys, Path::new(&unescaped));
                }
            }
        }
    }
    lib_roots
}

pub fn locate_workshop_roots(seed_roots: Option<&[PathBuf]>) -> Vec<String> {
    let lib_roots = collect_steam_library_roots(seed_roots);

    let mut seen_ws: HashSet<String> = HashSet::new();
    let mut workshop_roots: Vec<String> = Vec::new();
    for lib in lib_roots {
        let ws = lib
            .join("steamapps")
            .join("workshop")
            .join("content")
            .join(WALLPAPER_ENGINE_APP_ID);
        if ws.is_dir() {
            let s = ws.to_string_lossy().into_owned();
            if seen_ws.insert(s.to_ascii_lowercase()) {
                workshop_roots.push(s);
            }
        }
    }
    workshop_roots.sort_by_key(|a| a.to_ascii_lowercase());
    workshop_roots
}

pub fn resolve_configured_workshop_roots(configured: Option<&str>) -> Vec<String> {
    let Some(raw) = configured.map(str::trim).filter(|s| !s.is_empty()) else {
        return Vec::new();
    };
    let full = Path::new(raw);
    let candidates = [
        full.to_path_buf(),
        full.join("steamapps")
            .join("workshop")
            .join("content")
            .join(WALLPAPER_ENGINE_APP_ID),
        full.join("workshop")
            .join("content")
            .join(WALLPAPER_ENGINE_APP_ID),
    ];

    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for cand in candidates {
        if !cand.is_dir() {
            continue;
        }
        let is_431960 = cand
            .file_name()
            .and_then(|n| n.to_str())
            .map(|n| n.eq_ignore_ascii_case(WALLPAPER_ENGINE_APP_ID))
            .unwrap_or(false);
        if !is_431960 {
            continue;
        }
        let norm = std::path::absolute(&cand)
            .unwrap_or(cand)
            .to_string_lossy()
            .into_owned();
        if seen.insert(norm.to_ascii_lowercase()) {
            out.push(norm);
        }
    }
    out
}

fn discover_steam_roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    let mut seen = HashSet::new();

    if let Ok(hkcu) = RegKey::predef(HKEY_CURRENT_USER).open_subkey(r"Software\Valve\Steam") {
        if let Ok(path) = hkcu.get_value::<String, _>("SteamPath") {
            add_dir_if_valid(&mut roots, &mut seen, Path::new(&path));
        }
    }
    for key_path in [r"SOFTWARE\WOW6432Node\Valve\Steam", r"SOFTWARE\Valve\Steam"] {
        if let Ok(hk) = RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey(key_path) {
            if let Ok(path) = hk.get_value::<String, _>("InstallPath") {
                add_dir_if_valid(&mut roots, &mut seen, Path::new(&path));
            }
        }
    }

    let common_rel = [
        PathBuf::from("Steam"),
        PathBuf::from("SteamLibrary"),
        PathBuf::from(r"Program Files (x86)\Steam"),
        PathBuf::from(r"Program Files\Steam"),
        PathBuf::from(r"Games\Steam"),
        PathBuf::from(r"Games\SteamLibrary"),
    ];

    for drive in fixed_drive_roots() {
        for rel in &common_rel {
            add_dir_if_valid(&mut roots, &mut seen, &drive.join(rel));
        }
        if let Ok(entries) = fs::read_dir(&drive) {
            for entry in entries.flatten() {
                let top = entry.path();
                if !top.is_dir() {
                    continue;
                }
                if top
                    .join("steamapps")
                    .join("workshop")
                    .join("content")
                    .join(WALLPAPER_ENGINE_APP_ID)
                    .is_dir()
                    || top.join("steamapps").join("libraryfolders.vdf").is_file()
                {
                    add_dir_if_valid(&mut roots, &mut seen, &top);
                }
            }
        }
    }

    roots
}

pub fn fixed_drive_roots() -> Vec<PathBuf> {
    const DRIVE_FIXED: u32 = 3;
    let mask = unsafe { GetLogicalDrives() };
    let mut drives = Vec::new();
    for i in 0..26u8 {
        if (mask & (1u32 << i)) == 0 {
            continue;
        }
        let letter = (b'A' + i) as char;
        let root_str = format!("{letter}:\\");
        let wide: Vec<u16> = root_str.encode_utf16().chain(Some(0)).collect();
        let dtype = unsafe { GetDriveTypeW(PCWSTR(wide.as_ptr())) };
        if dtype == DRIVE_FIXED {
            let p = PathBuf::from(&root_str);
            if p.exists() {
                drives.push(p);
            }
        }
    }
    drives
}

fn add_dir_if_valid(roots: &mut Vec<PathBuf>, seen: &mut HashSet<String>, path: &Path) {
    if !path.is_dir() {
        return;
    }
    let abs = std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf());
    let key = abs
        .to_string_lossy()
        .trim_end_matches(['\\', '/'])
        .to_ascii_lowercase();
    if seen.insert(key) {
        roots.push(abs);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn persists_filter_preferences_across_restart() {
        let tmp = std::env::temp_dir().join(format!("wp_settings_persist_{}.json", std::process::id()));
        let _ = fs::remove_file(&tmp);
        let mut s = AppSettings::default();
        s.rating_filter = "everyone".to_string();
        s.spec_filter = "4k".to_string();
        s.sort_by = "resolution".to_string();
        s.media_filter = "image".to_string();
        s.color_filter = Some("blue".to_string());
        save_settings_to(&tmp, &s).unwrap();

        let loaded = load_settings_from(&tmp);
        assert_eq!(loaded.rating_filter, "everyone");
        assert_eq!(loaded.spec_filter, "4k");
        assert_eq!(loaded.sort_by, "resolution");
        assert_eq!(loaded.media_filter, "image");
        assert_eq!(loaded.color_filter.as_deref(), Some("blue"));
        let _ = fs::remove_file(&tmp);
    }
}
