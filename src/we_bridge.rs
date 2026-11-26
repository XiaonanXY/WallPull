use crate::models::WallpaperItem;
use crate::process_runner::{os_args, run_status};
use crate::settings::{discover_steam_library_roots, fixed_drive_roots, local_app_data_root};
use serde_json::{Value, json};
use std::collections::{BTreeSet, HashSet};
use std::ffi::OsString;
use std::fs;
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::time::Duration;
use winreg::RegKey;
use winreg::enums::{HKEY_CURRENT_USER, KEY_SET_VALUE};
use windows::Win32::Foundation::{CloseHandle, MAX_PATH};
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};
use windows::Win32::System::Threading::{
    OpenMutexW, OpenProcess, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
    QueryFullProcessImageNameW, SYNCHRONIZATION_ACCESS_RIGHTS,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, SM_CMONITORS, SPI_SETDESKWALLPAPER, SPIF_SENDCHANGE, SPIF_UPDATEINIFILE,
    SystemParametersInfoW,
};
use windows::core::{PCWSTR, PWSTR};

const WE_PROC_NAMES: &[&str] = &["wallpaper64", "wallpaper32"];

fn is_native_static_wallpaper_image(path: &Path) -> bool {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase());
    matches!(ext.as_deref(), Some("png" | "jpg" | "jpeg" | "bmp"))
}

fn is_we_live_image_file(path: &Path) -> bool {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase());
    matches!(
        ext.as_deref(),
        Some("png" | "jpg" | "jpeg" | "bmp" | "webp" | "gif")
    )
}

pub fn is_wallpaper_engine_running() -> bool {
    !find_we_process_ids().is_empty()
}

pub fn try_find_install_directory(hint_workshop_dir: Option<&str>) -> Option<PathBuf> {
    if let Some(exe) = try_find_running_executable(hint_workshop_dir) {
        return exe.parent().map(Path::to_path_buf);
    }
    if let Some(hint) = hint_workshop_dir.filter(|s| !s.trim().is_empty()) {
        if let Some(dir) = resolve_we_dir_from_workshop_hint(hint) {
            return Some(dir);
        }
    }
    for dir in enumerate_fallback_install_dirs(hint_workshop_dir) {
        if dir.join("wallpaper64.exe").is_file() || dir.join("wallpaper32.exe").is_file() {
            return Some(dir);
        }
    }
    None
}

fn resolve_we_dir_from_workshop_hint(hint: &str) -> Option<PathBuf> {
    let mut cur = std::path::absolute(Path::new(hint)).ok();
    while let Some(dir) = cur {
        if dir
            .file_name()
            .and_then(|n| n.to_str())
            .map(|n| n.eq_ignore_ascii_case("steamapps"))
            .unwrap_or(false)
        {
            let cand = dir.join("common").join("wallpaper_engine");
            if cand.join("wallpaper64.exe").is_file() || cand.join("wallpaper32.exe").is_file() {
                return Some(cand);
            }
            break;
        }
        cur = dir.parent().map(Path::to_path_buf);
    }
    None
}

pub fn send_control_command(command: &str, extra_args: &[&str]) -> bool {
    let Some(we_exe) = try_find_running_executable(None) else {
        return false;
    };
    let mut args = vec!["-control".to_string(), command.to_string()];
    args.extend(extra_args.iter().map(|s| s.to_string()));
    std::thread::spawn(move || {
        dispatch_control_command(&we_exe, &args);
    });
    true
}

pub fn apply_wallpaper_properties(
    wallpaper: &WallpaperItem,
    raw_json_object: &str,
) -> Result<(), String> {
    let we_exe = try_find_running_executable(Some(&wallpaper.workshop_directory))
        .ok_or_else(|| "请先启动 Wallpaper Engine，再同步壁纸隐藏属性开关。".to_string())?;

    let project_json = if wallpaper.workshop_directory.trim().is_empty() {
        None
    } else {
        let p = Path::new(&wallpaper.workshop_directory).join("project.json");
        if p.is_file() {
            Some(p)
        } else {
            None
        }
    };
    let escaped_json = raw_json_object.replace(")~END", "\\u0029~END");
    let props_arg = format!("RAW~({escaped_json})~END");

    std::thread::spawn(move || {
        if let Some(pj) = project_json {
            let full = std::path::absolute(&pj)
                .unwrap_or(pj)
                .to_string_lossy()
                .into_owned();
            dispatch_control_command(&we_exe, &["-control".into(), "openWallpaper".into(), "-file".into(), full]);
            std::thread::sleep(std::time::Duration::from_millis(220));
        }
        dispatch_control_command(
            &we_exe,
            &[
                "-control".into(),
                "applyProperties".into(),
                "-properties".into(),
                props_arg,
            ],
        );
    });
    Ok(())
}

fn extract_full_video_desktop_frame(wallpaper: &WallpaperItem) -> Option<PathBuf> {
    let src = Path::new(&wallpaper.source_path);
    if !src.is_file() {
        return None;
    }
    let dir = local_app_data_root().join("AppliedDesktop");
    let _ = fs::create_dir_all(&dir);
    let target_name = format!(
        "video-frame-{}.jpg",
        crate::media::sanitize_cache_key(&wallpaper.id)
    );
    let dest = dir.join(&target_name);
    if let Ok(entries) = fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if let Some(n) = p.file_name().and_then(|s| s.to_str()) {
                if n.starts_with("video-frame-") && n != target_name {
                    let _ = fs::remove_file(&p);
                }
            }
        }
    }
    if dest.is_file() && fs::metadata(&dest).map(|m| m.len() > 2048).unwrap_or(false) {
        return Some(dest);
    }

    let ffmpeg = crate::media::find_executable("ffmpeg.exe")?;
    for seek in ["0.5", "0"] {
        let mut args = os_args(["-y", "-ss", seek, "-i"]);
        args.push(src.as_os_str().to_os_string());
        args.extend(os_args([
            "-frames:v",
            "1",
            "-vf",
            "scale='min(3840,iw)':-2:flags=lanczos",
            "-q:v",
            "2",
        ]));
        args.push(dest.as_os_str().to_os_string());
        if matches!(
            run_status(&ffmpeg, &args, None, Duration::from_secs(20), None),
            Ok(true)
        ) && dest.is_file()
            && fs::metadata(&dest).map(|m| m.len() > 1024).unwrap_or(false)
        {
            return Some(dest);
        }
    }
    let _ = fs::remove_file(&dest);
    None
}

fn is_we_ipc_ready() -> bool {
    let mutex_name: Vec<u16> = "cxWallpaperEngineGlobalMutex"
        .encode_utf16()
        .chain(Some(0))
        .collect();
    match unsafe {
        OpenMutexW(
            SYNCHRONIZATION_ACCESS_RIGHTS(0x0010_0000),
            false,
            PCWSTR(mutex_name.as_ptr()),
        )
    } {
        Ok(handle) => {
            unsafe {
                let _ = CloseHandle(handle);
            }
            true
        }
        Err(_) => false,
    }
}

fn find_or_launch_wallpaper_engine(
    hint_workshop_dir: Option<&str>,
    allow_launch: bool,
) -> Option<PathBuf> {
    if let Some(exe) = try_find_running_executable(hint_workshop_dir) {
        return Some(exe);
    }
    if !allow_launch {
        return None;
    }
    let dir = try_find_install_directory(hint_workshop_dir)?;
    let exe = ["wallpaper64.exe", "wallpaper32.exe"]
        .into_iter()
        .map(|name| dir.join(name))
        .find(|p| p.is_file())?;
    let mut cmd = std::process::Command::new(&exe);
    cmd.arg("-silent").current_dir(&dir).creation_flags(0x0800_0000);
    cmd.spawn().ok()?;

    for _ in 0..40 {
        std::thread::sleep(Duration::from_millis(100));
        if is_we_ipc_ready() {
            std::thread::sleep(Duration::from_millis(450));
            return Some(exe);
        }
    }
    if is_wallpaper_engine_running() {
        return Some(exe);
    }
    None
}

pub fn apply_wallpaper_item(
    wallpaper: &WallpaperItem,
    asset_index: Option<usize>,
) -> Result<bool, String> {
    let needs_we_for_dynamic = wallpaper.item_type == "video"
        || (asset_index.unwrap_or(0) == 0
            && !wallpaper.workshop_directory.trim().is_empty()
            && wallpaper.original_type != "image");

    if let Some(we_exe) =
        find_or_launch_wallpaper_engine(Some(&wallpaper.workshop_directory), needs_we_for_dynamic)
    {
        if wallpaper.item_type == "image" {
            let is_dynamic_scene = asset_index.unwrap_or(0) == 0
                && !wallpaper.workshop_directory.trim().is_empty()
                && wallpaper.original_type != "image";
            if is_dynamic_scene {
                let project_json = Path::new(&wallpaper.workshop_directory).join("project.json");
                if project_json.is_file() {
                    run_open_wallpaper(&we_exe, &project_json);
                    return Ok(true);
                }
            }

            let img_path = PathBuf::from(resolve_wallpaper_asset_path(wallpaper, asset_index));
            if img_path.is_file() {
                try_apply_windows_static_wallpaper(&img_path);
            }
            if img_path.is_file() && is_we_live_image_file(&img_path) {
                let wrapper_json = materialize_live_desktop_project(&img_path, &wallpaper.title)?;
                run_open_wallpaper(&we_exe, &wrapper_json);
                return Ok(true);
            }
            return Err("当前壁纸缺少可用的原画面文件，无法在 Wallpaper Engine 中打开。".to_string());
        }

        // Video or dynamic scene: open directly in Wallpaper Engine without triggering
        // SPI_SETDESKWALLPAPER (WM_SETTINGCHANGE) which would stall DWM and restart video playback.
        if asset_index.unwrap_or(0) == 0 && !wallpaper.workshop_directory.trim().is_empty() {
            let project_json = Path::new(&wallpaper.workshop_directory).join("project.json");
            if project_json.is_file() {
                run_open_wallpaper(&we_exe, &project_json);
                return Ok(true);
            }
        }

        if wallpaper.item_type == "video" && Path::new(&wallpaper.source_path).is_file() {
            let wrapper_json =
                materialize_live_video_project(Path::new(&wallpaper.source_path), &wallpaper.title)?;
            run_open_wallpaper(&we_exe, &wrapper_json);
            return Ok(true);
        }

        return Err("当前动态壁纸缺少可用的项目或原视频文件，无法在 Wallpaper Engine 中打开。".to_string());
    }

    let full_static_image: Option<PathBuf> = if wallpaper.item_type == "image" {
        let p = PathBuf::from(resolve_wallpaper_asset_path(wallpaper, asset_index));
        if p.is_file() { Some(p) } else { None }
    } else {
        extract_full_video_desktop_frame(wallpaper)
    };

    let Some(static_path) = full_static_image else {
        return Err(if wallpaper.item_type == "video" {
            "当前为动态视频壁纸，未检测到已安装的 Wallpaper Engine 且未能提取高清视频帧。".to_string()
        } else {
            format!("找不到可设为桌面背景的图片文件：{}", wallpaper.source_path)
        });
    };
    apply_desktop_wallpaper_path(&static_path)?;
    if wallpaper.item_type == "video" {
        return Err("未检测到已安装的 Wallpaper Engine，已提取高清首帧设为静态桌面（动态播放需先安装 Wallpaper Engine）。".to_string());
    }
    Ok(false)
}

pub fn apply_custom_image(image_path: &Path, title: &str) -> Result<bool, String> {
    if !image_path.is_file() {
        return Err(format!("找不到可设为桌面背景的图片文件：{}", image_path.display()));
    }
    apply_desktop_wallpaper_path(image_path)?;
    if let Some(we_exe) = try_find_running_executable(None) {
        let wrapper = materialize_live_desktop_project(image_path, title)?;
        run_open_wallpaper(&we_exe, &wrapper);
        return Ok(true);
    }
    Ok(false)
}

pub fn resolve_wallpaper_asset_path(item: &WallpaperItem, asset_index: Option<usize>) -> String {
    if let (Some(idx), Some(assets)) = (asset_index, item.asset_paths.as_ref()) {
        if idx < assets.len() && Path::new(&assets[idx]).is_file() {
            return assets[idx].clone();
        }
    }
    item.source_path.clone()
}

pub fn apply_desktop_wallpaper_path(target_path: &Path) -> Result<(), String> {
    let apply_path = if is_native_static_wallpaper_image(target_path) {
        target_path.to_path_buf()
    } else if target_path.is_file() {
        let dir = local_app_data_root().join("AppliedDesktop");
        let _ = fs::create_dir_all(&dir);
        let conv = dir.join("static-converted.png");
        let img = image::ImageReader::open(target_path)
            .map_err(|e| format!("无法读取图片设为桌面：{e}"))?
            .with_guessed_format()
            .map_err(|e| format!("无法识别图片格式：{e}"))?
            .decode()
            .map_err(|e| format!("无法解码图片为静态桌面：{e}"))?;
        img.save(&conv)
            .map_err(|e| format!("转换桌面图片为 PNG 失败：{e}"))?;
        conv
    } else {
        return Err("Windows 原生静态桌面壁纸仅支持常见图片格式。".to_string());
    };
    let (w, h) = crate::media::read_image_dimensions(&apply_path);
    if let Ok(desktop_key) =
        RegKey::predef(HKEY_CURRENT_USER).open_subkey_with_flags(r"Control Panel\Desktop", KEY_SET_VALUE)
    {
        let _ = desktop_key.set_value("TileWallpaper", &"0");
        // Fit portrait art cleanly without zooming in on the top half; Fill landscape/standard screens
        let style = if w > 0 && h > w { "6" } else { "10" };
        let _ = desktop_key.set_value("WallpaperStyle", &style);
    }
    let full = std::path::absolute(&apply_path).unwrap_or(apply_path);
    let wide: Vec<u16> = full.as_os_str().encode_wide().chain(Some(0)).collect();
    let ok = unsafe {
        SystemParametersInfoW(
            SPI_SETDESKWALLPAPER,
            0,
            Some(wide.as_ptr() as *mut _),
            SPIF_UPDATEINIFILE | SPIF_SENDCHANGE,
        )
    };
    ok.map_err(|e| format!("设置 Windows 桌面壁纸失败：{e}"))
}

fn try_apply_windows_static_wallpaper(path: &Path) {
    if !path.is_file() {
        return;
    }
    let _ = apply_desktop_wallpaper_path(path);
}

fn run_open_wallpaper(exe_path: &Path, project_json_path: &Path) {
    let full_pj = std::path::absolute(project_json_path)
        .unwrap_or_else(|_| project_json_path.to_path_buf())
        .to_string_lossy()
        .into_owned();
    let monitors = get_active_monitor_indices(exe_path);
    if monitors.len() <= 1 {
        dispatch_control_command(
            exe_path,
            &[
                "-control".into(),
                "openWallpaper".into(),
                "-file".into(),
                full_pj,
            ],
        );
    } else {
        for m in monitors {
            dispatch_control_command(
                exe_path,
                &[
                    "-control".into(),
                    "openWallpaper".into(),
                    "-file".into(),
                    full_pj.clone(),
                    "-monitor".into(),
                    m.to_string(),
                ],
            );
        }
    }
}

fn dispatch_control_command(exe_path: &Path, args: &[String]) {
    let os = os_args(args);
    let _ = run_status(exe_path, &os, exe_path.parent(), Duration::from_secs(3), None);
}

fn get_active_monitor_indices(exe_path: &Path) -> Vec<usize> {
    let screen_count = unsafe { GetSystemMetrics(SM_CMONITORS) };
    if screen_count <= 1 {
        return Vec::new();
    }
    let Some(config_path) = exe_path.parent().map(|d| d.join("config.json")) else {
        return Vec::new();
    };
    let Ok(bytes) = fs::read(&config_path) else {
        return Vec::new();
    };
    let Ok(doc) = serde_json::from_slice::<Value>(&bytes) else {
        return Vec::new();
    };
    let mut indices = BTreeSet::new();
    collect_selected_monitors(&doc, &mut indices);
    indices.into_iter().collect()
}

fn collect_selected_monitors(val: &Value, indices: &mut BTreeSet<usize>) {
    match val {
        Value::Object(map) => {
            for (k, v) in map {
                if k.eq_ignore_ascii_case("wallpaperconfigrecent") {
                    continue;
                }
                if k.eq_ignore_ascii_case("selectedwallpapers") {
                    if let Some(mon_map) = v.as_object() {
                        for mon_key in mon_map.keys() {
                            if let Some(prefix) = mon_key.get(..7) {
                                if prefix.eq_ignore_ascii_case("monitor") {
                                    if let Ok(idx) = mon_key[7..].parse::<usize>() {
                                        indices.insert(idx);
                                    }
                                }
                            }
                        }
                    }
                } else {
                    collect_selected_monitors(v, indices);
                }
            }
        }
        Value::Array(arr) => {
            for item in arr {
                collect_selected_monitors(item, indices);
            }
        }
        _ => {}
    }
}

fn materialize_live_desktop_project(image_path: &Path, title: &str) -> Result<PathBuf, String> {
    let live_root = local_app_data_root().join("LiveDesktop");
    fs::create_dir_all(&live_root).map_err(|e| format!("无法创建 LiveDesktop 目录：{e}"))?;
    let slot_name = format!(
        "slot-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    );
    let slot_dir = live_root.join(slot_name);
    fs::create_dir_all(&slot_dir).map_err(|e| format!("无法创建 slot 目录：{e}"))?;

    let ext = image_path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| format!(".{}", e.to_ascii_lowercase()))
        .unwrap_or_else(|| ".png".to_string());
    let img_name = format!("wallpaper{ext}");
    fs::copy(image_path, slot_dir.join(&img_name))
        .map_err(|e| format!("复制壁纸原画失败：{e}"))?;

    let html = format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><style>html,body{{margin:0;padding:0;width:100vw;height:100vh;overflow:hidden;background:#000}}img{{display:block;width:100vw;height:100vh;object-fit:cover;user-select:none;-webkit-user-drag:none}}</style></head><body><img src=\"{img_name}\" alt=\"\"/></body></html>"
    );
    fs::write(slot_dir.join("index.html"), html).map_err(|e| e.to_string())?;

    let pj = json!({
        "file": "index.html",
        "preview": img_name,
        "title": if title.trim().is_empty() { "WallPull Desktop" } else { title },
        "type": "web"
    });
    let pj_path = slot_dir.join("project.json");
    fs::write(&pj_path, serde_json::to_vec_pretty(&pj).unwrap_or_default())
        .map_err(|e| e.to_string())?;

    cleanup_older_slots(&live_root, &slot_dir);
    Ok(pj_path)
}

fn materialize_live_video_project(video_path: &Path, title: &str) -> Result<PathBuf, String> {
    let live_root = local_app_data_root().join("LiveDesktop");
    fs::create_dir_all(&live_root).map_err(|e| format!("无法创建 LiveDesktop 目录：{e}"))?;
    let slot_name = format!(
        "slot-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    );
    let slot_dir = live_root.join(slot_name);
    fs::create_dir_all(&slot_dir).map_err(|e| format!("无法创建 slot 目录：{e}"))?;

    let ext = video_path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| format!(".{}", e.to_ascii_lowercase()))
        .unwrap_or_else(|| ".mp4".to_string());
    let vid_name = format!("wallpaper{ext}");
    let dst_video = slot_dir.join(&vid_name);
    if fs::hard_link(video_path, &dst_video).is_err() {
        fs::copy(video_path, &dst_video).map_err(|e| format!("复制视频壁纸失败：{e}"))?;
    }

    let pj = json!({
        "file": vid_name,
        "title": if title.trim().is_empty() { "WallPull Desktop" } else { title },
        "type": "video"
    });
    let pj_path = slot_dir.join("project.json");
    fs::write(&pj_path, serde_json::to_vec_pretty(&pj).unwrap_or_default())
        .map_err(|e| e.to_string())?;

    cleanup_older_slots(&live_root, &slot_dir);
    Ok(pj_path)
}

fn cleanup_older_slots(live_root: &Path, current_slot: &Path) {
    let Ok(entries) = fs::read_dir(live_root) else {
        return;
    };
    let mut dirs: Vec<(std::time::SystemTime, PathBuf)> = entries
        .flatten()
        .filter_map(|e| {
            let p = e.path();
            let name = p.file_name()?.to_str()?;
            if p.is_dir() && name.starts_with("slot-") && p != current_slot {
                let ctime = e
                    .metadata()
                    .ok()
                    .and_then(|m| m.created().ok())
                    .unwrap_or(std::time::UNIX_EPOCH);
                Some((ctime, p))
            } else {
                None
            }
        })
        .collect();
    dirs.sort_by(|a, b| b.0.cmp(&a.0));
    for (_, dir) in dirs.into_iter().skip(2) {
        let _ = fs::remove_dir_all(dir);
    }
}

fn find_we_process_ids() -> Vec<(u32, String)> {
    let mut found = Vec::new();
    let Ok(snap) = (unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) }) else {
        return found;
    };

    let mut entry = PROCESSENTRY32W {
        dwSize: size_of::<PROCESSENTRY32W>() as u32,
        ..Default::default()
    };

    unsafe {
        if Process32FirstW(snap, &mut entry).is_ok() {
            loop {
                let end = entry
                    .szExeFile
                    .iter()
                    .position(|&c| c == 0)
                    .unwrap_or(entry.szExeFile.len());
                let exe_name = OsString::from_wide(&entry.szExeFile[..end])
                    .to_string_lossy()
                    .to_ascii_lowercase();
                for &target in WE_PROC_NAMES {
                    if exe_name == format!("{target}.exe") || exe_name == target {
                        found.push((entry.th32ProcessID, target.to_string()));
                    }
                }
                if Process32NextW(snap, &mut entry).is_err() {
                    break;
                }
            }
        }
        let _ = CloseHandle(snap);
    }
    found
}

fn try_find_running_executable(hint_workshop_dir: Option<&str>) -> Option<PathBuf> {
    let procs = find_we_process_ids();
    if procs.is_empty() {
        return None;
    }

    for (pid, _) in &procs {
        if let Ok(handle) = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, *pid) } {
            let mut buf = [0u16; MAX_PATH as usize * 2];
            let mut len = buf.len() as u32;
            let ok = unsafe {
                QueryFullProcessImageNameW(
                    handle,
                    PROCESS_NAME_WIN32,
                    PWSTR(buf.as_mut_ptr()),
                    &mut len,
                )
            };
            unsafe {
                let _ = CloseHandle(handle);
            }
            if ok.is_ok() && len > 0 {
                let path = PathBuf::from(OsString::from_wide(&buf[..len as usize]));
                if path.is_file() {
                    return Some(path);
                }
            }
        }
    }

    let mut exe_names: Vec<String> = procs.iter().map(|(_, n)| format!("{n}.exe")).collect();
    for fallback in ["wallpaper64.exe", "wallpaper32.exe"] {
        if !exe_names.iter().any(|e| e.eq_ignore_ascii_case(fallback)) {
            exe_names.push(fallback.to_string());
        }
    }

    for dir in enumerate_fallback_install_dirs(hint_workshop_dir) {
        for exe in &exe_names {
            let cand = dir.join(exe);
            if cand.is_file() {
                return Some(cand);
            }
        }
    }
    None
}

fn enumerate_fallback_install_dirs(hint_workshop_dir: Option<&str>) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();

    if let Some(hint) = hint_workshop_dir.filter(|s| !s.trim().is_empty()) {
        let mut cur = std::path::absolute(Path::new(hint)).ok();
        while let Some(dir) = cur {
            if dir
                .file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.eq_ignore_ascii_case("steamapps"))
                .unwrap_or(false)
            {
                let cand = dir.join("common").join("wallpaper_engine");
                if cand.is_dir() && seen.insert(cand.to_string_lossy().to_ascii_lowercase()) {
                    out.push(cand);
                }
                break;
            }
            cur = dir.parent().map(Path::to_path_buf);
        }
    }

    for lib in discover_steam_library_roots() {
        let cand = lib
            .join("steamapps")
            .join("common")
            .join("wallpaper_engine");
        if cand.is_dir() && seen.insert(cand.to_string_lossy().to_ascii_lowercase()) {
            out.push(cand);
        }
    }

    if let Some(pf86) = std::env::var_os("ProgramFiles(x86)") {
        let cand = PathBuf::from(pf86)
            .join("Steam")
            .join("steamapps")
            .join("common")
            .join("wallpaper_engine");
        if cand.is_dir() && seen.insert(cand.to_string_lossy().to_ascii_lowercase()) {
            out.push(cand);
        }
    }

    for drive in fixed_drive_roots() {
        for sub in ["SteamLibrary", "Steam", r"Games\Steam"] {
            let cand = drive
                .join(sub)
                .join("steamapps")
                .join("common")
                .join("wallpaper_engine");
            if cand.is_dir() && seen.insert(cand.to_string_lossy().to_ascii_lowercase()) {
                out.push(cand);
            }
        }
    }

    out
}
