use crate::actions::{
    archive_wallpapers_offline, check_latest_release, clean_track_title, convert_toolbox_media,
    export_wallpaper_audio, export_wallpapers, format_byte_size, get_migration_status,
    is_archived_offline, migrate_workshop_with_junction, open_explorer_path, open_external_url,
    open_steam_workshop_page, open_wallpaper_folder, pick_toolbox_media_files,
    recycle_workshop_wallpapers, resolve_archive_directory, resolve_primary_workshop_root,
    resolve_target_items, slim_workshop_videos, unpack_external_packages,
};
use crate::clipboard::{copy_media_to_clipboard, copy_text_to_clipboard};
use crate::duplicates::analyze_duplicates;
use crate::media::{find_executable, is_recognized_media_path, probe_or_fallback};
use crate::models::{
    AppSettings, AudioTrackPayload, GpuAdapterInfo, ItemPrecomputedMeta, WallpaperItem,
    WallpaperPayloadItem, WallpaperScanReport, WorkshopExtraMetadata, clean_path_str,
    strip_verbatim_prefix,
};
use crate::pkg::extract_scene_assets;
use crate::process_runner::CANCELLED_ERR;
use crate::scanner::{compute_items_meta, inspect_workshop_extra, scan_wallpapers, scan_wallpapers_with_progress};
use crate::scene_studio::{SceneStudioSession, has_inspectable_2d_scene, open_studio_session};
use crate::settings::{
    cache_root, calculate_cache_size_bytes, clear_media_cache, get_gpu_adapters,
    load_settings_from, locate_workshop_roots, resolve_configured_workshop_roots,
    sanitize_settings, save_settings_to, settings_file_path,
};
use crate::we_bridge::{
    apply_custom_image, apply_wallpaper_item, apply_wallpaper_properties,
    resolve_wallpaper_asset_path,
};
use include_dir::{Dir, include_dir};
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use webview2_com::Microsoft::Web::WebView2::Win32::*;
use webview2_com::{
    CoTaskMemPWSTR, CoreWebView2EnvironmentOptions,
    CreateCoreWebView2ControllerCompletedHandler, CreateCoreWebView2EnvironmentCompletedHandler,
    WebMessageReceivedEventHandler, WebResourceRequestedEventHandler,
};
use windows::Win32::Foundation::{E_POINTER, HWND, LPARAM, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{DWMWA_USE_IMMERSIVE_DARK_MODE, DwmSetWindowAttribute};
use windows::Win32::UI::Shell::SHCreateMemStream;
use windows::Win32::UI::WindowsAndMessaging::{
    IsZoomed, PostMessageW, PostQuitMessage, SW_MAXIMIZE, SW_MINIMIZE, SW_RESTORE, ShowWindow,
    WM_APP, WM_CLOSE,
};
use windows::core::{BOOL, HSTRING, Interface, PCWSTR, PWSTR, w};

static DIST_DIR: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/frontend/dist");

pub const WM_UI_COMMAND: u32 = WM_APP + 1;

pub enum UiCommand {
    PostJson {
        msg_type: String,
        payload: Value,
        request_id: Option<String>,
    },
    PostRawJson(String),
    ScanBatch {
        request_id: Option<String>,
        scan_gen: u64,
        items: Vec<WallpaperItem>,
        metas: HashMap<String, ItemPrecomputedMeta>,
    },
    ScanCompleted {
        request_id: Option<String>,
        scan_gen: u64,
        items: Vec<WallpaperItem>,
        metas: HashMap<String, ItemPrecomputedMeta>,
        report: WallpaperScanReport,
        detected_roots: Vec<String>,
    },
    WatcherSyncCompleted {
        scan_gen: u64,
        items: Vec<WallpaperItem>,
        metas: HashMap<String, ItemPrecomputedMeta>,
        report: WallpaperScanReport,
        detected_roots: Vec<String>,
    },
    ArchiveOfflineCompleted {
        request_id: Option<String>,
        items: Vec<WallpaperItem>,
        archived_ids: Vec<String>,
        dest_dir: String,
        into_we: bool,
    },
    StudioExportCompleted {
        request_id: Option<String>,
        result: Result<String, String>,
    },
    RefreshScanRequested {
        request_id: Option<String>,
        force: bool,
    },
    DeleteCompleted {
        request_id: Option<String>,
        deleted_dirs: HashSet<String>,
        recycled_count: usize,
        total_targets: usize,
        freed_bytes: i64,
    },
    PickedWorkshopRoot {
        request_id: Option<String>,
        path: Option<String>,
    },
    PickedExportDir {
        request_id: Option<String>,
        path: Option<String>,
    },
    ExportWithPicker {
        request_id: Option<String>,
        ids: Vec<String>,
        format: Option<String>,
    },
    StartPickedExport {
        request_id: Option<String>,
        ids: Vec<String>,
        dest: PathBuf,
        format: Option<String>,
    },
    ExecuteJunctionMigration {
        request_id: Option<String>,
        primary_root: String,
        dest_dir: PathBuf,
    },
    StudioOpened {
        request_id: Option<String>,
        studio_gen: u64,
        wallpaper_id: String,
        title: String,
        session: Arc<SceneStudioSession>,
        preview_url: String,
        width: i32,
        height: i32,
        has_pixels: bool,
    },
    StudioPreviewReady {
        request_id: Option<String>,
        studio_gen: u64,
        wallpaper_id: String,
        preview_url: String,
        width: i32,
        height: i32,
        has_pixels: bool,
    },
    SelfTestTimeout,
    ExitExplicit,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BridgeEnvelope<T: Serialize> {
    version: i32,
    #[serde(rename = "type")]
    msg_type: String,
    request_id: Option<String>,
    payload: T,
}

pub struct AppController {
    pub hwnd: HWND,
    pub environment: Option<ICoreWebView2Environment>,
    pub controller: Option<ICoreWebView2Controller>,
    pub webview: Option<ICoreWebView2>,
    pub tx: mpsc::Sender<UiCommand>,
    pub rx: mpsc::Receiver<UiCommand>,
    pub settings: AppSettings,
    pub wallpapers: HashMap<String, WallpaperItem>,
    pub precomputed_meta: HashMap<String, ItemPrecomputedMeta>,
    pub detected_roots: Vec<String>,
    pub gpu_adapters: Vec<GpuAdapterInfo>,
    pub active_hw_accel: String,
    pub mapped_hosts: HashMap<String, String>,
    pub watcher_roots: Arc<Mutex<Vec<String>>>,
    pub watcher_export_dir: Arc<Mutex<String>>,
    pub scan_busy: Arc<AtomicBool>,
    pub scan_gen: Arc<AtomicU64>,
    pub scan_cancel: Arc<AtomicBool>,
    pub watcher_cancel: Arc<Mutex<Option<Arc<AtomicBool>>>>,
    pub watcher_stop: Arc<AtomicBool>,
    pub export_cancel: Arc<AtomicBool>,
    pub export_gen: Arc<AtomicU64>,
    pub toolbox_busy: Arc<AtomicBool>,
    pub toolbox_cancel: Arc<AtomicBool>,
    pub active_scan_req: Option<String>,
    pub studio_session: Option<(String, Arc<SceneStudioSession>, Option<String>)>,
    pub studio_gen: Arc<AtomicU64>,
    pub studio_preview_bytes: Arc<Mutex<Option<(u64, Arc<Vec<u8>>)>>>,
    pub exiting_explicitly: bool,
    pub self_test: bool,
}

impl AppController {
    pub fn new(hwnd: HWND, self_test: bool) -> Box<Self> {
        let (tx, rx) = mpsc::channel();
        let settings = load_settings_from(&settings_file_path());
        let active_hw_accel = if settings.hardware_acceleration_mode == "cpu" {
            "cpu".to_string()
        } else {
            "gpu".to_string()
        };
        let gpu_adapters = get_gpu_adapters();
        let detected_roots = locate_workshop_roots(None);

        let watcher_roots = Arc::new(Mutex::new(Vec::new()));
        let watcher_export_dir = Arc::new(Mutex::new(settings.export_directory.clone()));
        let scan_busy = Arc::new(AtomicBool::new(false));
        let scan_gen = Arc::new(AtomicU64::new(0));
        let watcher_cancel = Arc::new(Mutex::new(None));
        let watcher_stop = Arc::new(AtomicBool::new(false));
        if !self_test {
            start_watcher_thread(
                tx.clone(),
                hwnd.0 as isize,
                watcher_roots.clone(),
                watcher_export_dir.clone(),
                active_hw_accel == "gpu",
                scan_busy.clone(),
                scan_gen.clone(),
                watcher_cancel.clone(),
                watcher_stop.clone(),
            );
        }

        let app = Box::new(Self {
            hwnd,
            environment: None,
            controller: None,
            webview: None,
            tx,
            rx,
            settings,
            wallpapers: HashMap::new(),
            precomputed_meta: HashMap::new(),
            detected_roots,
            gpu_adapters,
            active_hw_accel,
            mapped_hosts: HashMap::new(),
            watcher_roots,
            watcher_export_dir,
            scan_busy,
            scan_gen,
            scan_cancel: Arc::new(AtomicBool::new(false)),
            watcher_cancel,
            watcher_stop,
            export_cancel: Arc::new(AtomicBool::new(false)),
            export_gen: Arc::new(AtomicU64::new(0)),
            toolbox_busy: Arc::new(AtomicBool::new(false)),
            toolbox_cancel: Arc::new(AtomicBool::new(false)),
            active_scan_req: None,
            studio_session: None,
            studio_gen: Arc::new(AtomicU64::new(0)),
            studio_preview_bytes: Arc::new(Mutex::new(None)),
            exiting_explicitly: false,
            self_test,
        });
        app.sync_watcher_roots();
        app
    }

    pub fn shutdown_background_tasks(&mut self) {
        self.scan_cancel.store(true, Ordering::SeqCst);
        self.export_cancel.store(true, Ordering::SeqCst);
        self.toolbox_cancel.store(true, Ordering::SeqCst);
        self.watcher_stop.store(true, Ordering::SeqCst);
        if let Ok(guard) = self.watcher_cancel.lock() {
            if let Some(c) = guard.as_ref() {
                c.store(true, Ordering::SeqCst);
            }
        }
    }

    pub fn notify_ui(&self, cmd: UiCommand) {
        let _ = self.tx.send(cmd);
        unsafe {
            let _ = PostMessageW(Some(self.hwnd), WM_UI_COMMAND, WPARAM(0), LPARAM(0));
        }
    }

    pub fn apply_window_theme(&self, is_dark: bool) {
        let dark_val: BOOL = is_dark.into();
        unsafe {
            let _ = DwmSetWindowAttribute(
                self.hwnd,
                DWMWA_USE_IMMERSIVE_DARK_MODE,
                &dark_val as *const BOOL as *const _,
                size_of::<BOOL>() as u32,
            );
        }
        if let Some(ctrl) = &self.controller {
            if let Ok(ctrl2) = ctrl.cast::<ICoreWebView2Controller2>() {
                let color = if is_dark {
                    COREWEBVIEW2_COLOR {
                        A: 255,
                        R: 0x0D,
                        G: 0x0D,
                        B: 0x14,
                    }
                } else {
                    COREWEBVIEW2_COLOR {
                        A: 255,
                        R: 255,
                        G: 255,
                        B: 255,
                    }
                };
                unsafe {
                    let _ = ctrl2.SetDefaultBackgroundColor(color);
                }
            }
        }
    }

    pub fn resize_webview(&self) {
        let Some(ctrl) = &self.controller else {
            return;
        };
        let mut rect = RECT::default();
        unsafe {
            let _ = windows::Win32::UI::WindowsAndMessaging::GetClientRect(self.hwnd, &mut rect);
            let _ = ctrl.SetBounds(rect);
            let _ = ctrl.SetIsVisible(true);
        }
    }

    pub fn notify_parent_moved(&self) {
        if let Some(ctrl) = &self.controller {
            unsafe {
                let _ = ctrl.NotifyParentWindowPositionChanged();
            }
        }
    }

    pub fn post_json<T: Serialize>(&self, msg_type: &str, payload: T, request_id: Option<&str>) {
        let Some(webview) = &self.webview else {
            return;
        };
        let envelope = BridgeEnvelope {
            version: 1,
            msg_type: msg_type.to_string(),
            request_id: request_id.map(ToString::to_string),
            payload,
        };
        if let Ok(json_str) = serde_json::to_string(&envelope) {
            let hstr = HSTRING::from(json_str);
            unsafe {
                let _ = webview.PostWebMessageAsJson(&hstr);
            }
        }
    }

    pub fn init_webview(&mut self) -> Result<(), String> {
        let wv_root = crate::settings::local_app_data_root().join("WebView2");
        cleanup_stale_webview_sessions(&wv_root);
        let isolated = has_other_running_instance();
        let folder_name = if isolated {
            format!("session-{}", std::process::id())
        } else {
            self.active_hw_accel.clone()
        };
        let user_data_dir = wv_root.join(folder_name);
        let _ = fs::create_dir_all(&user_data_dir);

        let browser_args = if self.active_hw_accel == "cpu" {
            "--disable-gpu --disable-gpu-compositing --disable-gpu-vsync"
        } else {
            "--force_high_performance_gpu --enable-gpu-rasterization --ignore-gpu-blocklist"
        };

        let env = create_wv_environment(&user_data_dir, browser_args).or_else(|_| {
            let fallback_dir = wv_root.join(format!("session-{}", std::process::id()));
            let _ = fs::create_dir_all(&fallback_dir);
            create_wv_environment(&fallback_dir, browser_args)
        })?;

        let ctrl = create_wv_controller(&env, self.hwnd)?;
        let webview = unsafe { ctrl.CoreWebView2() }.map_err(|e| format!("获取 CoreWebView2 失败：{e}"))?;

        unsafe {
            if let Ok(settings) = webview.Settings() {
                let _ = settings.SetAreDefaultContextMenusEnabled(false);
                let _ = settings.SetAreDevToolsEnabled(cfg!(debug_assertions));
                let _ = settings.SetIsZoomControlEnabled(false);
                if let Ok(s9) = settings.cast::<ICoreWebView2Settings9>() {
                    let _ = s9.SetIsNonClientRegionSupportEnabled(true);
                }
            }
        }

        let web_assets_dir = ensure_embedded_web_assets()?;
        let wv3 = webview
            .cast::<ICoreWebView2_3>()
            .map_err(|e| format!("WebView2 版本过旧，不支持虚拟主机映射：{e}"))?;
        unsafe {
            wv3.SetVirtualHostNameToFolderMapping(
                w!("app.wallpapervault"),
                &HSTRING::from(web_assets_dir.to_string_lossy().as_ref()),
                COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS,
            )
            .map_err(|e| format!("映射内置前端资源失败：{e}"))?;
        }

        self.environment = Some(env.clone());
        self.controller = Some(ctrl.clone());
        self.webview = Some(webview.clone());

        self.apply_window_theme(self.settings.theme_mode == "dark");
        self.resize_webview();
        unsafe {
            let _ = ctrl.SetIsVisible(true);
        }
        self.map_initial_media_roots();

        let studio_mem = self.studio_preview_bytes.clone();
        let env_for_mem = env.clone();
        let mut wrr_token = 0i64;
        unsafe {
            let _ = webview.AddWebResourceRequestedFilter(
                w!("https://studio-mem.wallpapervault/*"),
                COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL,
            );
            let _ = webview.add_WebResourceRequested(
                &WebResourceRequestedEventHandler::create(Box::new(move |_sender, args| {
                    let Some(args) = args else {
                        return Ok(());
                    };
                    let Ok(req) = args.Request() else {
                        return Ok(());
                    };
                    let mut uri_pw = PWSTR::null();
                    if req.Uri(&mut uri_pw).is_err() {
                        return Ok(());
                    }
                    let uri = CoTaskMemPWSTR::from(uri_pw).to_string();
                    if !uri.starts_with("https://studio-mem.wallpapervault/") {
                        return Ok(());
                    }
                    let bytes_opt = studio_mem
                        .lock()
                        .ok()
                        .and_then(|g| g.as_ref().map(|(_, b)| b.clone()));
                    let Some(bytes) = bytes_opt else {
                        return Ok(());
                    };
                    if let Some(stream) = SHCreateMemStream(Some(bytes.as_slice())) {
                        if let Ok(resp) = env_for_mem.CreateWebResourceResponse(
                            &stream,
                            200,
                            w!("OK"),
                            w!("Content-Type: image/png\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *"),
                        ) {
                            let _ = args.SetResponse(Some(&resp));
                        }
                    }
                    Ok(())
                })),
                &mut wrr_token,
            );
        }

        // Listen for WebMessageReceived and route into AppController via WM_UI_COMMAND
        let tx_msg = self.tx.clone();
        let hwnd_msg = self.hwnd;
        let mut msg_token = 0i64;
        unsafe {
            webview
                .add_WebMessageReceived(
                    &WebMessageReceivedEventHandler::create(Box::new(move |_sender, args| {
                        let Some(args) = args else {
                            return Ok(());
                        };
                        let mut msg_pw = PWSTR::null();
                        if args.WebMessageAsJson(&mut msg_pw).is_ok() {
                            let raw_json = CoTaskMemPWSTR::from(msg_pw).to_string();
                            let _ = tx_msg.send(UiCommand::PostRawJson(raw_json));
                            let _ = PostMessageW(Some(hwnd_msg), WM_UI_COMMAND, WPARAM(0), LPARAM(0));
                        }
                        Ok(())
                    })),
                    &mut msg_token,
                )
                .map_err(|e| format!("add_WebMessageReceived 失败：{e}"))?;

            webview
                .Navigate(w!("https://app.wallpapervault/index.html"))
                .map_err(|e| format!("WebView2 导航到内置页面失败：{e}"))?;
        }

        if self.self_test {
            let tx = self.tx.clone();
            let hwnd_raw = self.hwnd.0 as isize;
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_secs(12));
                send_ui(&tx, hwnd_raw, UiCommand::SelfTestTimeout);
            });
        }

        Ok(())
    }

    pub fn drain_commands(&mut self) {
        while let Ok(cmd) = self.rx.try_recv() {
            match cmd {
                UiCommand::PostRawJson(raw) => self.handle_web_message(&raw),
                UiCommand::PostJson {
                    msg_type,
                    payload,
                    request_id,
                } => self.post_json(&msg_type, payload, request_id.as_deref()),
                UiCommand::ScanBatch {
                    request_id,
                    scan_gen,
                    items,
                    metas,
                } => {
                    if self.scan_gen.load(Ordering::SeqCst) != scan_gen {
                        continue;
                    }
                    self.precomputed_meta.extend(metas);
                    let mut payloads = Vec::with_capacity(items.len());
                    for item in &items {
                        if let Some(p) = self.build_payload_item(item) {
                            self.wallpapers.insert(item.id.clone(), item.clone());
                            payloads.push(p);
                        }
                    }
                    if !payloads.is_empty() {
                        self.post_json(
                            "wallpapers.item",
                            json!({ "items": payloads }),
                            request_id.as_deref(),
                        );
                    }
                }
                UiCommand::ScanCompleted {
                    request_id,
                    scan_gen,
                    items,
                    metas,
                    report,
                    detected_roots,
                } => {
                    if self.scan_gen.load(Ordering::SeqCst) != scan_gen {
                        continue;
                    }
                    self.scan_busy.store(false, Ordering::SeqCst);
                    self.detected_roots = detected_roots;
                    self.wallpapers.clear();
                    self.precomputed_meta = metas;
                    self.map_initial_media_roots();

                    let mut payloads = Vec::with_capacity(items.len());
                    let (mut img_cnt, mut vid_cnt) = (0usize, 0usize);
                    for item in &items {
                        if let Some(p) = self.build_payload_item(item) {
                            if item.item_type == "video" {
                                vid_cnt += 1;
                            } else {
                                img_cnt += 1;
                            }
                            self.wallpapers.insert(item.id.clone(), item.clone());
                            payloads.push(p);
                        }
                    }
                    let disk_bytes = calculate_distinct_workshop_bytes(&items);
                    self.sync_watcher_roots();
                    self.post_json(
                        "wallpapers.list",
                        json!({
                            "items": payloads,
                            "status": format!("解析完成 · {img_cnt} 张图片，{vid_cnt} 个视频 · 共占 {}", format_byte_size(disk_bytes)),
                            "report": report,
                            "detectedWorkshopRoots": self.detected_roots,
                            "cacheSizeBytes": calculate_cache_size_bytes(),
                        }),
                        request_id.as_deref(),
                    );
                }
                UiCommand::WatcherSyncCompleted {
                    scan_gen,
                    items,
                    metas,
                    report,
                    detected_roots,
                } => {
                    if self.scan_gen.load(Ordering::SeqCst) != scan_gen {
                        continue;
                    }
                    self.scan_busy.store(false, Ordering::SeqCst);
                    let old_meta: HashMap<String, (i64, i64, String, String)> = self
                        .wallpapers
                        .iter()
                        .map(|(id, w)| {
                            (
                                id.clone(),
                                (
                                    w.file_size,
                                    w.folder_size,
                                    w.title.clone(),
                                    w.preview_path.clone(),
                                ),
                            )
                        })
                        .collect();
                    let mut new_map = HashMap::new();
                    let mut added = Vec::new();
                    let mut updated_cnt = 0usize;
                    self.detected_roots = detected_roots;
                    self.precomputed_meta = metas;
                    self.map_initial_media_roots();

                    let mut payloads = Vec::with_capacity(items.len());
                    let (mut img_cnt, mut vid_cnt) = (0usize, 0usize);
                    for item in &items {
                        if let Some(p) = self.build_payload_item(item) {
                            match old_meta.get(&item.id) {
                                None => added.push(item.clone()),
                                Some(prev) => {
                                    let cur = (
                                        item.file_size,
                                        item.folder_size,
                                        item.title.clone(),
                                        item.preview_path.clone(),
                                    );
                                    if *prev != cur {
                                        updated_cnt += 1;
                                    }
                                }
                            }
                            if item.item_type == "video" {
                                vid_cnt += 1;
                            } else {
                                img_cnt += 1;
                            }
                            new_map.insert(item.id.clone(), item.clone());
                            payloads.push(p);
                        }
                    }
                    let removed_cnt = old_meta
                        .keys()
                        .filter(|id| !new_map.contains_key(*id))
                        .count();
                    if added.is_empty() && removed_cnt == 0 && updated_cnt == 0 {
                        continue;
                    }
                    self.wallpapers = new_map;
                    let disk_bytes = calculate_distinct_workshop_bytes(&items);
                    self.sync_watcher_roots();
                    self.post_json(
                        "wallpapers.sync",
                        json!({
                            "items": payloads,
                            "status": format!("解析完成 · {img_cnt} 张图片，{vid_cnt} 个视频 · 共占 {}", format_byte_size(disk_bytes)),
                            "report": report,
                            "detectedWorkshopRoots": self.detected_roots,
                            "cacheSizeBytes": calculate_cache_size_bytes(),
                            "addedCount": added.len(),
                            "removedCount": removed_cnt,
                            "updatedCount": updated_cnt,
                            "firstAddedTitle": added.first().map(|w| w.title.as_str()),
                        }),
                        None,
                    );
                }
                UiCommand::ArchiveOfflineCompleted {
                    request_id,
                    items,
                    archived_ids,
                    dest_dir,
                    into_we,
                } => {
                    let id_set: HashSet<String> = archived_ids.iter().cloned().collect();
                    for w in &items {
                        if id_set.contains(&w.id) {
                            let k = clean_path_str(Path::new(&w.workshop_directory))
                                .to_ascii_lowercase();
                            if let Some(m) = self.precomputed_meta.get_mut(&k) {
                                m.is_archived_offline = true;
                            }
                        }
                    }
                    let all_items: Vec<WallpaperItem> = self.wallpapers.values().cloned().collect();
                    let updated: Vec<WallpaperPayloadItem> = all_items
                        .iter()
                        .filter_map(|w| self.build_payload_item(w))
                        .collect();
                    let vec_ids: Vec<String> = id_set.into_iter().collect();
                    self.post_json(
                        "wallpapers.sync-meta",
                        json!({ "archivedIds": vec_ids }),
                        None,
                    );
                    self.post_json(
                        "wallpapers.action.result",
                        json!({
                            "message": if into_we {
                                format!("已将 {} 款壁纸永久备份至 WE 本地项目库，原作者删库也不会丢失", archived_ids.len())
                            } else {
                                format!("已将 {} 款壁纸克隆至独立「离线永久保险箱」", archived_ids.len())
                            },
                            "destination": dest_dir,
                            "archivedIds": vec_ids,
                            "items": updated,
                        }),
                        request_id.as_deref(),
                    );
                }
                UiCommand::StudioExportCompleted { request_id, result } => match result {
                    Ok(msg) => self.post_json(
                        "wallpapers.action.result",
                        json!({ "message": msg }),
                        request_id.as_deref(),
                    ),
                    Err(err_msg) => self.post_json(
                        "error",
                        json!({ "message": err_msg }),
                        request_id.as_deref(),
                    ),
                },
                UiCommand::RefreshScanRequested { request_id, force } => {
                    self.start_scan(request_id, force);
                }
                UiCommand::DeleteCompleted {
                    request_id,
                    deleted_dirs,
                    recycled_count,
                    total_targets,
                    freed_bytes,
                } => {
                    let deleted_ids: HashSet<String> = self
                        .wallpapers
                        .values()
                        .filter(|w| {
                            let key = std::path::absolute(Path::new(&w.workshop_directory))
                                .unwrap_or_else(|_| PathBuf::from(&w.workshop_directory))
                                .to_string_lossy()
                                .trim_end_matches(['\\', '/'])
                                .to_ascii_lowercase();
                            deleted_dirs.contains(&key)
                        })
                        .map(|w| w.id.clone())
                        .collect();

                    let mut remaining: Vec<WallpaperItem> = self
                        .wallpapers
                        .values()
                        .filter(|w| !deleted_ids.contains(&w.id))
                        .cloned()
                        .collect();
                    remaining.sort_by(|a, b| {
                        a.title
                            .to_lowercase()
                            .cmp(&b.title.to_lowercase())
                            .then_with(|| a.id.cmp(&b.id))
                    });

                    if !deleted_ids.is_empty() && !self.settings.favorite_ids.is_empty() {
                        let next_favs: Vec<String> = self
                            .settings
                            .favorite_ids
                            .iter()
                            .filter(|id| !deleted_ids.contains(*id))
                            .cloned()
                            .collect();
                        if next_favs.len() != self.settings.favorite_ids.len() {
                            self.settings.favorite_ids = next_favs;
                            let _ = save_settings_to(&settings_file_path(), &self.settings);
                        }
                    }

                    for dir in &deleted_dirs {
                        self.precomputed_meta.remove(dir);
                    }
                    self.wallpapers.clear();
                    let mut payloads = Vec::with_capacity(remaining.len());
                    let (mut img_cnt, mut vid_cnt) = (0usize, 0usize);
                    for item in &remaining {
                        if let Some(p) = self.build_payload_item(item) {
                            if item.item_type == "video" {
                                vid_cnt += 1;
                            } else {
                                img_cnt += 1;
                            }
                            self.wallpapers.insert(item.id.clone(), item.clone());
                            payloads.push(p);
                        }
                    }
                    let disk_bytes = calculate_distinct_workshop_bytes(&remaining);
                    let failed_cnt = total_targets.saturating_sub(recycled_count);
                    let summary = if failed_cnt > 0 {
                        format!(
                            "已将 {recycled_count} 组壁纸移入 Windows 回收站（另有 {failed_cnt} 组被占用跳过）"
                        )
                    } else {
                        format!(
                            "已将 {recycled_count} 组壁纸移入 Windows 回收站（可释放 {}）",
                            format_byte_size(freed_bytes)
                        )
                    };

                    let deleted_vec: Vec<String> = deleted_ids.into_iter().collect();
                    self.post_json(
                        "wallpapers.deleted",
                        json!({
                            "deletedIds": deleted_vec,
                            "items": payloads,
                            "status": format!("解析完成 · {img_cnt} 张图片，{vid_cnt} 个视频 · 共占 {}", format_byte_size(disk_bytes)),
                            "detectedWorkshopRoots": self.detected_roots,
                            "cacheSizeBytes": calculate_cache_size_bytes(),
                            "settings": self.settings,
                        }),
                        request_id.as_deref(),
                    );
                    self.post_json(
                        "wallpapers.action.result",
                        json!({ "message": summary, "recycled": recycled_count }),
                        request_id.as_deref(),
                    );
                }
                UiCommand::PickedWorkshopRoot { request_id, path } => {
                    if let Some(p) = path {
                        self.clear_dynamic_media_hosts();
                        self.settings.workshop_root = Some(p);
                        let _ = save_settings_to(&settings_file_path(), &self.settings);
                        self.sync_watcher_roots();
                        self.post_json("settings.value", &self.settings, request_id.as_deref());
                    }
                }
                UiCommand::PickedExportDir { request_id, path } => {
                    if let Some(p) = path {
                        self.settings.export_directory = p;
                        let _ = save_settings_to(&settings_file_path(), &self.settings);
                        self.post_json("settings.value", &self.settings, request_id.as_deref());
                    }
                }
                UiCommand::ExportWithPicker {
                    request_id,
                    ids,
                    format,
                } => {
                    let tx = self.tx.clone();
                    let hwnd = self.hwnd.0 as isize;
                    std::thread::spawn(move || {
                        let Some(dest) = rfd::FileDialog::new().pick_folder() else {
                            send_ui(
                                &tx,
                                hwnd,
                                UiCommand::PostJson {
                                    msg_type: "wallpapers.action.result".into(),
                                    payload: json!({ "message": "已取消导出" }),
                                    request_id,
                                },
                            );
                            return;
                        };
                        send_ui(
                            &tx,
                            hwnd,
                            UiCommand::StartPickedExport {
                                request_id,
                                ids,
                                dest,
                                format,
                            },
                        );
                    });
                }
                UiCommand::StartPickedExport {
                    request_id,
                    ids,
                    dest,
                    format,
                } => {
                    self.start_export_job(ids, dest, format, request_id);
                }
                UiCommand::ExecuteJunctionMigration {
                    request_id,
                    primary_root,
                    dest_dir,
                } => {
                    let tx = self.tx.clone();
                    let hwnd = self.hwnd.0 as isize;
                    let req = request_id.clone();
                    let busy = self.toolbox_busy.clone();
                    std::thread::spawn(move || {
                        let res = migrate_workshop_with_junction(&primary_root, &dest_dir, |msg| {
                            send_ui(
                                &tx,
                                hwnd,
                                UiCommand::PostJson {
                                    msg_type: "toolbox.progress".into(),
                                    payload: json!({ "message": msg }),
                                    request_id: None,
                                },
                            );
                        });
                        busy.store(false, Ordering::SeqCst);
                        match res {
                            Ok((target_ws, bytes)) => {
                                send_ui(
                                    &tx,
                                    hwnd,
                                    UiCommand::PostJson {
                                        msg_type: "toolbox.migration.status".into(),
                                        payload: json!({
                                            "workshopRoot": primary_root,
                                            "isJunction": true,
                                            "linkTarget": target_ws,
                                            "totalBytes": bytes as i64,
                                        }),
                                        request_id: req.clone(),
                                    },
                                );
                                send_ui(
                                    &tx,
                                    hwnd,
                                    UiCommand::PostJson {
                                        msg_type: "wallpapers.action.result".into(),
                                        payload: json!({
                                            "message": format!("跨盘搬家成功！已将 {} 无感迁移至 {target_ws}（原备份已在回收站）", format_byte_size(bytes as i64)),
                                            "destination": target_ws,
                                        }),
                                        request_id: req,
                                    },
                                );
                            }
                            Err(msg) => send_ui(
                                &tx,
                                hwnd,
                                UiCommand::PostJson {
                                    msg_type: "error".into(),
                                    payload: json!({ "message": msg }),
                                    request_id: req,
                                },
                            ),
                        }
                    });
                }
                UiCommand::StudioOpened {
                    request_id,
                    studio_gen,
                    wallpaper_id,
                    title,
                    session,
                    preview_url,
                    width,
                    height,
                    has_pixels,
                } => {
                    if self.studio_gen.load(Ordering::SeqCst) != studio_gen {
                        continue;
                    }
                    self.cleanup_studio_session_keep_mem();
                    self.studio_session = Some((wallpaper_id.clone(), session.clone(), None));
                    self.post_json(
                        "wallpapers.scene-studio.opened",
                        json!({
                            "wallpaperId": wallpaper_id,
                            "title": title,
                            "manifest": session.manifest,
                            "previewUrl": preview_url,
                            "previewWidth": width,
                            "previewHeight": height,
                            "hasPixels": has_pixels,
                        }),
                        request_id.as_deref(),
                    );
                }
                UiCommand::StudioPreviewReady {
                    request_id,
                    studio_gen,
                    wallpaper_id,
                    preview_url,
                    width,
                    height,
                    has_pixels,
                } => {
                    if self.studio_gen.load(Ordering::SeqCst) != studio_gen {
                        continue;
                    }
                    self.post_json(
                        "wallpapers.scene-studio.preview",
                        json!({
                            "wallpaperId": wallpaper_id,
                            "previewUrl": preview_url,
                            "previewWidth": width,
                            "previewHeight": height,
                            "hasPixels": has_pixels,
                        }),
                        request_id.as_deref(),
                    );
                }
                UiCommand::SelfTestTimeout => {
                    if self.self_test {
                        if let Ok(out_path) = std::env::var("WALLPULL_SELFTEST_OUT") {
                            let _ = fs::write(out_path, "SELF_TEST_TIMEOUT");
                        }
                        std::process::exit(2);
                    }
                }
                UiCommand::ExitExplicit => {
                    self.exiting_explicitly = true;
                    unsafe {
                        PostQuitMessage(0);
                    }
                }
            }
        }
    }

    fn handle_web_message(&mut self, raw: &str) {
        let Ok(root) = serde_json::from_str::<Value>(raw) else {
            return;
        };
        if root.get("version").and_then(|v| v.as_i64()) != Some(1) {
            return;
        }
        let Some(msg_type) = root.get("type").and_then(|v| v.as_str()) else {
            return;
        };
        let req_id = root
            .get("requestId")
            .and_then(|v| v.as_str())
            .map(ToString::to_string);
        let payload = root.get("payload");

        let res: Result<(), String> = self.dispatch_web_message(msg_type, payload, req_id.as_deref());

        if let Err(err_msg) = res {
            self.post_json("error", json!({ "message": err_msg }), req_id.as_deref());
        }
    }

    fn dispatch_web_message(
        &mut self,
        msg_type: &str,
        payload: Option<&Value>,
        req_id_ref: Option<&str>,
    ) -> Result<(), String> {
        let req_id = req_id_ref.map(ToString::to_string);
        match msg_type {
            "app.ready" => {
                if self.self_test {
                    if let Ok(out_path) = std::env::var("WALLPULL_SELFTEST_OUT") {
                        let _ = fs::write(out_path, "SELF_TEST_APP_READY_OK");
                    }
                    self.exiting_explicitly = true;
                    unsafe {
                        let _ = PostMessageW(Some(self.hwnd), WM_CLOSE, WPARAM(0), LPARAM(0));
                    }
                    return Ok(());
                }
                let maximized = unsafe { IsZoomed(self.hwnd).as_bool() };
                self.post_json(
                    "app.state",
                    json!({
                        "native": true,
                        "customCaptionButtons": true,
                        "settings": self.settings,
                        "detectedWorkshopRoots": self.detected_roots,
                        "gpuAdapters": self.gpu_adapters,
                        "activeHardwareAccelerationMode": self.active_hw_accel,
                        "cacheSizeBytes": calculate_cache_size_bytes(),
                        "maximized": maximized,
                        "appVersion": env!("CARGO_PKG_VERSION"),
                    }),
                    req_id.as_deref(),
                );
                Ok(())
            }
            "window.minimize" => {
                unsafe {
                    let _ = ShowWindow(self.hwnd, SW_MINIMIZE);
                }
                Ok(())
            }
            "window.toggle-maximize" => {
                unsafe {
                    let cmd = if IsZoomed(self.hwnd).as_bool() {
                        SW_RESTORE
                    } else {
                        SW_MAXIMIZE
                    };
                    let _ = ShowWindow(self.hwnd, cmd);
                }
                Ok(())
            }
            "window.close" => {
                unsafe {
                    let _ = PostMessageW(Some(self.hwnd), WM_CLOSE, WPARAM(0), LPARAM(0));
                }
                Ok(())
            }
            "app.restart.request" => {
                crate::window::release_single_instance_mutex();
                self.shutdown_background_tasks();
                if let Ok(exe) = std::env::current_exe() {
                    let _ = std::process::Command::new(exe).spawn();
                }
                self.exiting_explicitly = true;
                unsafe {
                    PostQuitMessage(0);
                }
                Ok(())
            }
            "wallpapers.scan.request" => {
                if self.self_test {
                    return Ok(());
                }
                let force = payload
                    .and_then(|p| p.get("force"))
                    .and_then(|f| f.as_bool())
                    .unwrap_or(false);
                self.start_scan(req_id.clone(), force);
                Ok(())
            }
            "wallpapers.open-folder.request" => {
                let id = read_id(payload);
                self.find_wallpaper(id.as_deref())
                    .and_then(|w| open_wallpaper_folder(Path::new(&w.source_path)))
                    .map(|_| {
                        self.post_json(
                            "wallpapers.action.result",
                            json!({ "message": "已在资源管理器中定位解析后的原文件" }),
                            req_id.as_deref(),
                        );
                    })
            }
            "wallpapers.open-workshop.request" => {
                let id = read_id(payload);
                self.find_wallpaper(id.as_deref())
                    .and_then(|w| open_steam_workshop_page(&w.workshop_id))
                    .map(|_| {
                        self.post_json(
                            "wallpapers.action.result",
                            json!({ "message": "已在 Steam 打开创意工坊详情页" }),
                            req_id.as_deref(),
                        );
                    })
            }
            "wallpapers.copy.request" => {
                let id = read_id(payload);
                let idx = payload
                    .and_then(|p| p.get("assetIndex"))
                    .and_then(|v| v.as_u64())
                    .map(|u| u as usize);
                let w = self.find_wallpaper(id.as_deref())?;
                let target = resolve_wallpaper_asset_path(&w, idx);
                let is_img = w.item_type == "image";
                let tx = self.tx.clone();
                let hwnd = self.hwnd.0 as isize;
                let rq = req_id.clone();
                std::thread::spawn(move || match copy_media_to_clipboard(Path::new(&target), is_img) {
                    Ok(()) => send_ui(
                        &tx,
                        hwnd,
                        UiCommand::PostJson {
                            msg_type: "wallpapers.action.result".into(),
                            payload: json!({
                                "message": if is_img {
                                    "已复制原图到剪贴板，可直接 Ctrl+V 发送"
                                } else {
                                    "已复制原视频到剪贴板，可直接 Ctrl+V 发送"
                                }
                            }),
                            request_id: rq,
                        },
                    ),
                    Err(msg) => send_ui(
                        &tx,
                        hwnd,
                        UiCommand::PostJson {
                            msg_type: "error".into(),
                            payload: json!({ "message": msg }),
                            request_id: rq,
                        },
                    ),
                });
                Ok(())
            }
            "wallpapers.set-desktop.request" => {
                let id = read_id(payload);
                let idx = payload
                    .and_then(|p| p.get("assetIndex"))
                    .and_then(|v| v.as_u64())
                    .map(|u| u as usize);
                self.find_wallpaper(id.as_deref()).and_then(|w| {
                    let synced = apply_wallpaper_item(&w, idx)?;
                    let msg = if synced {
                        format!("已联动 Wallpaper Engine 切换壁纸：{}", w.title)
                    } else {
                        format!("已将「{}」设为桌面壁纸", w.title)
                    };
                    self.post_json(
                        "wallpapers.action.result",
                        json!({ "message": msg }),
                        req_id.as_deref(),
                    );
                    Ok(())
                })
            }
            "wallpapers.export.request" => {
                let ids = read_ids(payload);
                let fmt = payload
                    .and_then(|p| p.get("format"))
                    .and_then(|f| f.as_str())
                    .map(ToString::to_string);
                let dest = PathBuf::from(&self.settings.export_directory);
                self.start_export_job(ids, dest, fmt, req_id);
                Ok(())
            }
            "wallpapers.export-as.request" => {
                let ids = read_ids(payload);
                let fmt = payload
                    .and_then(|p| p.get("format"))
                    .and_then(|f| f.as_str())
                    .map(ToString::to_string);
                self.notify_ui(UiCommand::ExportWithPicker {
                    request_id: req_id.clone(),
                    ids,
                    format: fmt,
                });
                Ok(())
            }
            "wallpapers.export-audio.request" => {
                let id = read_id(payload);
                let track_idx = payload
                    .and_then(|p| p.get("trackIndex"))
                    .and_then(|v| v.as_u64())
                    .map(|u| u as usize);
                let w = self.find_wallpaper(id.as_deref())?;
                let export_dir = self.settings.export_directory.clone();
                let tx = self.tx.clone();
                let hwnd = self.hwnd.0 as isize;
                let rq = req_id.clone();
                std::thread::spawn(move || match export_wallpaper_audio(&w, track_idx, &export_dir) {
                    Ok((count, last_name)) => {
                        let msg = if count == 1 {
                            format!("已导出原声音乐：{}", last_name.unwrap_or_default())
                        } else {
                            format!("已导出 {count} 首壁纸原声到 音频 文件夹")
                        };
                        send_ui(
                            &tx,
                            hwnd,
                            UiCommand::PostJson {
                                msg_type: "wallpapers.action.result".into(),
                                payload: json!({ "message": msg }),
                                request_id: rq,
                            },
                        );
                    }
                    Err(msg) => send_ui(
                        &tx,
                        hwnd,
                        UiCommand::PostJson {
                            msg_type: "error".into(),
                            payload: json!({ "message": msg }),
                            request_id: rq,
                        },
                    ),
                });
                Ok(())
            }
            "wallpapers.scene-studio.open" => self.start_studio_open(read_id(payload), req_id.clone()),
            "wallpapers.scene-studio.preview" => {
                self.start_studio_preview(payload, req_id.clone());
                Ok(())
            }
            "wallpapers.scene-studio.export" => self.handle_studio_export(payload, req_id.clone()),
            "wallpapers.scene-studio.close" => {
                self.close_studio_internal();
                Ok(())
            }
            "wallpapers.duplicates.scan" => {
                let snap: Vec<WallpaperItem> = self.wallpapers.values().cloned().collect();
                let items_payloads: HashMap<String, WallpaperPayloadItem> = snap
                    .iter()
                    .filter_map(|w| self.build_payload_item(w).map(|p| (w.id.clone(), p)))
                    .collect();
                let tx = self.tx.clone();
                let hwnd = self.hwnd.0 as isize;
                let rq = req_id.clone();
                std::thread::spawn(move || {
                    let res = analyze_duplicates(&snap, |w| items_payloads.get(&w.id).cloned());
                    send_ui(
                        &tx,
                        hwnd,
                        UiCommand::PostJson {
                            msg_type: "wallpapers.duplicates.result".into(),
                            payload: json!({
                                "groups": res.groups,
                                "totalReclaimableBytes": res.total_reclaimable_bytes,
                                "scannedCount": res.scanned_count,
                            }),
                            request_id: rq,
                        },
                    );
                });
                Ok(())
            }
            "wallpapers.recycle-workshop.request" => {
                let ids = read_ids(payload);
                if ids.is_empty() {
                    Err("请先选择要清理的冗余壁纸。".to_string())
                } else {
                    let allowed: Vec<String> = self
                        .detected_roots
                        .iter()
                        .chain(
                            resolve_configured_workshop_roots(
                                self.settings.workshop_root.as_deref(),
                            )
                            .iter(),
                        )
                        .cloned()
                        .collect();
                    let targets: Vec<WallpaperItem> = ids
                        .iter()
                        .filter_map(|id| self.wallpapers.get(id).cloned())
                        .collect();
                    let export_dir = self.settings.export_directory.clone();
                    let tx = self.tx.clone();
                    let hwnd = self.hwnd.0 as isize;
                    let rq = req_id.clone();
                    std::thread::spawn(move || {
                        match recycle_workshop_wallpapers(&targets, &allowed, &export_dir) {
                            Ok((deleted_dirs, recycled_count, total_targets, freed_bytes)) => {
                                send_ui(
                                    &tx,
                                    hwnd,
                                    UiCommand::DeleteCompleted {
                                        request_id: rq,
                                        deleted_dirs,
                                        recycled_count,
                                        total_targets,
                                        freed_bytes,
                                    },
                                );
                            }
                            Err(msg) => send_ui(
                                &tx,
                                hwnd,
                                UiCommand::PostJson {
                                    msg_type: "error".into(),
                                    payload: json!({ "message": msg }),
                                    request_id: rq,
                                },
                            ),
                        }
                    });
                    Ok(())
                }
            }
            "toolbox.task.cancel" => {
                if self.toolbox_busy.load(Ordering::SeqCst) {
                    self.toolbox_cancel.store(true, Ordering::SeqCst);
                    self.post_json(
                        "toolbox.progress",
                        json!({
                            "taskKind": "cancelling",
                            "message": "正在安全停止当前任务并清理临时文件…",
                            "currentIndex": 0,
                            "totalCount": 0,
                            "cancellable": false,
                        }),
                        None,
                    );
                }
                Ok(())
            }
            "wallpapers.archive-offline.request" => {
                if self
                    .toolbox_busy
                    .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                    .is_err()
                {
                    return Err("已有后台工具箱任务正在运行，请等待当前任务完成。".to_string());
                }
                self.toolbox_cancel.store(false, Ordering::SeqCst);
                let raw_ids = read_ids(payload);
                let ids = if raw_ids.is_empty() {
                    self.settings.favorite_ids.clone()
                } else {
                    raw_ids
                };
                let items = resolve_target_items(&ids, &self.wallpapers);
                let export_dir = self.settings.export_directory.clone();
                let tx = self.tx.clone();
                let hwnd = self.hwnd.0 as isize;
                let rq = req_id.clone();
                let busy = self.toolbox_busy.clone();
                let cancel = self.toolbox_cancel.clone();
                std::thread::spawn(move || {
                    let res = archive_wallpapers_offline(&items, &export_dir, Some(&cancel), |prog| {
                        send_ui(
                            &tx,
                            hwnd,
                            UiCommand::PostJson {
                                msg_type: "toolbox.progress".into(),
                                payload: serde_json::to_value(prog).unwrap_or_else(|_| json!({})),
                                request_id: None,
                            },
                        );
                    });
                    busy.store(false, Ordering::SeqCst);
                    match res {
                        Ok((archived_ids, dest_dir, into_we)) => send_ui(
                            &tx,
                            hwnd,
                            UiCommand::ArchiveOfflineCompleted {
                                request_id: rq,
                                items,
                                archived_ids,
                                dest_dir,
                                into_we,
                            },
                        ),
                        Err(msg) if msg == CANCELLED_ERR => send_ui(
                            &tx,
                            hwnd,
                            UiCommand::PostJson {
                                msg_type: "toolbox.cancelled".into(),
                                payload: json!({ "message": "已安全停止离线典藏任务" }),
                                request_id: rq,
                            },
                        ),
                        Err(msg) => send_ui(
                            &tx,
                            hwnd,
                            UiCommand::PostJson {
                                msg_type: "error".into(),
                                payload: json!({ "message": msg }),
                                request_id: rq,
                            },
                        ),
                    }
                });
                Ok(())
            }
            "wallpapers.slim-videos.request" => {
                if self
                    .toolbox_busy
                    .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                    .is_err()
                {
                    return Err("已有后台工具箱任务正在运行，请等待当前任务完成。".to_string());
                }
                self.toolbox_cancel.store(false, Ordering::SeqCst);
                let ids = read_ids(payload);
                let mut seen_paths = HashSet::new();
                let mut targets: Vec<WallpaperItem> = Vec::new();
                for w in self.wallpapers.values() {
                    if !(ids.is_empty() || ids.contains(&w.id))
                        || w.item_type != "video"
                        || !w.source_path.to_ascii_lowercase().ends_with(".mp4")
                        || (!ids.is_empty() && w.file_size < 0)
                        || (ids.is_empty() && w.file_size < 50 * 1024 * 1024)
                        || !Path::new(&w.source_path).is_file()
                    {
                        continue;
                    }
                    let key = clean_path_str(Path::new(&w.source_path)).to_ascii_lowercase();
                    if seen_paths.insert(key) {
                        targets.push(w.clone());
                    }
                }
                let tx = self.tx.clone();
                let hwnd = self.hwnd.0 as isize;
                let rq = req_id.clone();
                let busy = self.toolbox_busy.clone();
                let cancel = self.toolbox_cancel.clone();
                std::thread::spawn(move || {
                    let res = slim_workshop_videos(&targets, Some(&cancel), |prog| {
                        send_ui(
                            &tx,
                            hwnd,
                            UiCommand::PostJson {
                                msg_type: "toolbox.progress".into(),
                                payload: serde_json::to_value(prog).unwrap_or_else(|_| json!({})),
                                request_id: None,
                            },
                        );
                    });
                    busy.store(false, Ordering::SeqCst);
                    match res {
                        Ok((slimmed, saved)) => {
                            let msg = if slimmed > 0 {
                                format!(
                                    "已无损感瘦身 {slimmed} 个视频，共节省 {}（原文件已在回收站）",
                                    format_byte_size(saved)
                                )
                            } else {
                                "所选视频本身已高度压缩，未继续二次压制以保护画质".to_string()
                            };
                            send_ui(
                                &tx,
                                hwnd,
                                UiCommand::PostJson {
                                    msg_type: "wallpapers.action.result".into(),
                                    payload: json!({ "message": msg }),
                                    request_id: rq,
                                },
                            );
                            if slimmed > 0 {
                                send_ui(
                                    &tx,
                                    hwnd,
                                    UiCommand::RefreshScanRequested {
                                        request_id: None,
                                        force: false,
                                    },
                                );
                            }
                        }
                        Err(msg) if msg == CANCELLED_ERR => {
                            send_ui(
                                &tx,
                                hwnd,
                                UiCommand::PostJson {
                                    msg_type: "toolbox.cancelled".into(),
                                    payload: json!({ "message": "已安全停止视频压缩，临时文件已清理" }),
                                    request_id: rq,
                                },
                            );
                            send_ui(
                                &tx,
                                hwnd,
                                UiCommand::RefreshScanRequested {
                                    request_id: None,
                                    force: false,
                                },
                            );
                        }
                        Err(msg) => send_ui(
                            &tx,
                            hwnd,
                            UiCommand::PostJson {
                                msg_type: "error".into(),
                                payload: json!({ "message": msg }),
                                request_id: rq,
                            },
                        ),
                    }
                });
                Ok(())
            }
            "toolbox.migration.status" => {
                let all_vals: Vec<WallpaperItem> = self.wallpapers.values().cloned().collect();
                let status = get_migration_status(&self.settings, &self.detected_roots, &all_vals);
                let mut status_val = serde_json::to_value(&status).unwrap_or_else(|_| json!({}));
                if let Some(obj) = status_val.as_object_mut() {
                    obj.insert(
                        "archiveDirectory".to_string(),
                        json!(clean_path_str(&resolve_archive_directory(
                            &self.settings,
                            &self.detected_roots,
                            &all_vals,
                        ))),
                    );
                }
                self.post_json("toolbox.migration.status", status_val, req_id.as_deref());
                Ok(())
            }
            "wallpapers.open-archive-dir.request" => {
                let all_vals: Vec<WallpaperItem> = self.wallpapers.values().cloned().collect();
                let archive_dir = resolve_archive_directory(
                    &self.settings,
                    &self.detected_roots,
                    &all_vals,
                );
                fs::create_dir_all(&archive_dir)
                    .map_err(|e| format!("无法创建典藏目录：{e}"))?;
                open_explorer_path(&archive_dir.to_string_lossy())?;
                self.post_json(
                    "wallpapers.action.result",
                    json!({ "message": "已打开典藏壁纸目录" }),
                    req_id.as_deref(),
                );
                Ok(())
            }
            "toolbox.migration.execute" => {
                let Some(primary_root) =
                    resolve_primary_workshop_root(&self.settings, &self.detected_roots)
                else {
                    return Err("未检测到可迁移的 Steam 创意工坊 431960 目录。".to_string());
                };
                if self
                    .toolbox_busy
                    .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                    .is_err()
                {
                    return Err("已有后台工具箱任务正在运行，请等待当前任务完成。".to_string());
                }
                let tx = self.tx.clone();
                let hwnd = self.hwnd.0 as isize;
                let rq = req_id.clone();
                let busy = self.toolbox_busy.clone();
                std::thread::spawn(move || {
                    if let Some(dest) = rfd::FileDialog::new().pick_folder() {
                        send_ui(
                            &tx,
                            hwnd,
                            UiCommand::ExecuteJunctionMigration {
                                request_id: rq,
                                primary_root,
                                dest_dir: dest,
                            },
                        );
                    } else {
                        busy.store(false, Ordering::SeqCst);
                        send_ui(
                            &tx,
                            hwnd,
                            UiCommand::PostJson {
                                msg_type: "toolbox.idle".into(),
                                payload: json!({}),
                                request_id: rq,
                            },
                        );
                    }
                });
                Ok(())
            }
            "wallpapers.we-properties.get" => {
                let id = read_id(payload);
                self.find_wallpaper(id.as_deref()).map(|w| {
                    let extra = self.get_cached_extra(&w);
                    self.post_json(
                        "wallpapers.we-properties.value",
                        json!({
                            "id": w.id,
                            "properties": extra.properties,
                        }),
                        req_id.as_deref(),
                    );
                })
            }
            "wallpapers.we-properties.apply" => {
                let id = read_id(payload);
                let props_val = payload
                    .and_then(|p| p.get("properties"))
                    .filter(|v| v.is_object())
                    .ok_or_else(|| "缺少要同步的壁纸属性参数。".to_string())?;
                self.find_wallpaper(id.as_deref()).and_then(|w| {
                    apply_wallpaper_properties(&w, &props_val.to_string())?;
                    self.post_json(
                        "wallpapers.action.result",
                        json!({ "message": format!("已向 Wallpaper Engine 同步「{}」的隐藏开关", w.title) }),
                        req_id.as_deref(),
                    );
                    Ok(())
                })
            }
            "shell.open-path.request" => {
                let path = payload
                    .and_then(|p| p.get("path"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                open_explorer_path(path)
            }
            "shell.open-url.request" => {
                let url = payload
                    .and_then(|p| p.get("url"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                let copy_text = payload
                    .and_then(|p| p.get("copyText"))
                    .and_then(|v| v.as_str())
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(ToString::to_string);
                let toast_message = payload
                    .and_then(|p| p.get("toastMessage"))
                    .and_then(|v| v.as_str())
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(ToString::to_string);

                open_external_url(url)?;
                let mut copied_ok = true;
                if let Some(ref text) = copy_text {
                    if copy_text_to_clipboard(text).is_err() {
                        copied_ok = false;
                    }
                }
                if let Some(msg) = toast_message {
                    let final_msg = if copy_text.is_some() && !copied_ok {
                        format!(
                            "已打开交流反馈链接（剪贴板暂被占用，群号：{}）",
                            copy_text.as_deref().unwrap_or("")
                        )
                    } else {
                        msg
                    };
                    self.post_json("app.toast", json!({ "message": final_msg }), req_id.as_deref());
                }
                Ok(())
            }
            "app.check-update.request" => {
                let current_version = payload
                    .and_then(|p| p.get("currentVersion"))
                    .and_then(|v| v.as_str())
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .unwrap_or(env!("CARGO_PKG_VERSION"))
                    .to_string();
                let tx = self.tx.clone();
                let hwnd = self.hwnd.0 as isize;
                let rq = req_id.clone();
                std::thread::spawn(move || match check_latest_release(&current_version) {
                    Ok((true, latest_tag, release_url)) => send_ui(
                        &tx,
                        hwnd,
                        UiCommand::PostJson {
                            msg_type: "app.toast".into(),
                            payload: json!({
                                "message": format!("发现新版本 {latest_tag}（当前 v{current_version}）"),
                                "actionLabel": "前往下载",
                                "actionUrl": release_url,
                            }),
                            request_id: rq,
                        },
                    ),
                    Ok((false, _latest_tag, _)) => send_ui(
                        &tx,
                        hwnd,
                        UiCommand::PostJson {
                            msg_type: "app.toast".into(),
                            payload: json!({
                                "message": format!("当前已是最新版本（v{current_version}）"),
                            }),
                            request_id: rq,
                        },
                    ),
                    Err(err_msg) => send_ui(
                        &tx,
                        hwnd,
                        UiCommand::PostJson {
                            msg_type: "error".into(),
                            payload: json!({ "message": err_msg }),
                            request_id: rq,
                        },
                    ),
                });
                Ok(())
            }
            "toolbox.media.pick" => {
                let tx = self.tx.clone();
                let hwnd = self.hwnd.0 as isize;
                let rq = req_id.clone();
                std::thread::spawn(move || {
                    let files = pick_toolbox_media_files();
                    if !files.is_empty() {
                        send_ui(
                            &tx,
                            hwnd,
                            UiCommand::PostJson {
                                msg_type: "toolbox.media.picked".into(),
                                payload: json!({ "files": files }),
                                request_id: rq,
                            },
                        );
                    }
                });
                Ok(())
            }
            "toolbox.media.convert" => {
                let paths: Vec<String> = payload
                    .and_then(|p| p.get("paths"))
                    .and_then(|v| v.as_array())
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|x| x.as_str().map(ToString::to_string))
                            .collect()
                    })
                    .unwrap_or_default();
                if paths.is_empty() {
                    return Err("请先添加要转换的文件。".to_string());
                }
                if self
                    .toolbox_busy
                    .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                    .is_err()
                {
                    return Err("已有后台工具箱任务正在运行，请等待当前任务完成。".to_string());
                }
                self.toolbox_cancel.store(false, Ordering::SeqCst);
                let target_fmt = payload
                    .and_then(|p| p.get("targetFormat"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("png")
                    .to_string();
                let strip_meta = payload
                    .and_then(|p| p.get("stripMetadata"))
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                let trim_alpha = payload
                    .and_then(|p| p.get("trimTransparency"))
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                let export_dir = self.settings.export_directory.clone();
                let tx = self.tx.clone();
                let hwnd = self.hwnd.0 as isize;
                let rq = req_id.clone();
                let busy = self.toolbox_busy.clone();
                let cancel = self.toolbox_cancel.clone();
                std::thread::spawn(move || {
                    let res = convert_toolbox_media(
                        &paths,
                        &target_fmt,
                        strip_meta,
                        trim_alpha,
                        &export_dir,
                        Some(&cancel),
                        |prog| {
                            send_ui(
                                &tx,
                                hwnd,
                                UiCommand::PostJson {
                                    msg_type: "toolbox.progress".into(),
                                    payload: serde_json::to_value(prog).unwrap_or_else(|_| json!({})),
                                    request_id: None,
                                },
                            );
                        },
                    );
                    busy.store(false, Ordering::SeqCst);
                    match res {
                        Ok((count, out_folder)) => send_ui(
                            &tx,
                            hwnd,
                            UiCommand::PostJson {
                                msg_type: "wallpapers.action.result".into(),
                                payload: json!({
                                    "message": format!("格式转换完成：已输出 {count} 个文件"),
                                    "destination": out_folder,
                                }),
                                request_id: rq,
                            },
                        ),
                        Err(msg) if msg == CANCELLED_ERR => send_ui(
                            &tx,
                            hwnd,
                            UiCommand::PostJson {
                                msg_type: "toolbox.cancelled".into(),
                                payload: json!({ "message": "已安全停止格式转换，临时文件已清理" }),
                                request_id: rq,
                            },
                        ),
                        Err(msg) => send_ui(
                            &tx,
                            hwnd,
                            UiCommand::PostJson {
                                msg_type: "error".into(),
                                payload: json!({ "message": msg }),
                                request_id: rq,
                            },
                        ),
                    }
                });
                Ok(())
            }
            "toolbox.packages.unpack" => {
                if self
                    .toolbox_busy
                    .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                    .is_err()
                {
                    return Err("已有后台工具箱任务正在运行，请等待当前任务完成。".to_string());
                }
                self.toolbox_cancel.store(false, Ordering::SeqCst);
                let export_dir = self.settings.export_directory.clone();
                let tx = self.tx.clone();
                let hwnd = self.hwnd.0 as isize;
                let rq = req_id.clone();
                let busy = self.toolbox_busy.clone();
                let cancel = self.toolbox_cancel.clone();
                std::thread::spawn(move || {
                    let res = unpack_external_packages(&export_dir, Some(&cancel), |prog| {
                        send_ui(
                            &tx,
                            hwnd,
                            UiCommand::PostJson {
                                msg_type: "toolbox.progress".into(),
                                payload: serde_json::to_value(prog).unwrap_or_else(|_| json!({})),
                                request_id: None,
                            },
                        );
                    });
                    busy.store(false, Ordering::SeqCst);
                    match res {
                        Ok(Some((files, texs, dest))) => send_ui(
                            &tx,
                            hwnd,
                            UiCommand::PostJson {
                                msg_type: "wallpapers.action.result".into(),
                                payload: json!({
                                    "message": format!("解包完成：已提取 {files} 个文件（含 {texs} 张 PNG 贴图）"),
                                    "destination": dest,
                                }),
                                request_id: rq,
                            },
                        ),
                        Ok(None) => send_ui(
                            &tx,
                            hwnd,
                            UiCommand::PostJson {
                                msg_type: "toolbox.idle".into(),
                                payload: json!({}),
                                request_id: rq,
                            },
                        ),
                        Err(msg) if msg == CANCELLED_ERR => send_ui(
                            &tx,
                            hwnd,
                            UiCommand::PostJson {
                                msg_type: "toolbox.cancelled".into(),
                                payload: json!({ "message": "已安全停止外部解包任务" }),
                                request_id: rq,
                            },
                        ),
                        Err(msg) => send_ui(
                            &tx,
                            hwnd,
                            UiCommand::PostJson {
                                msg_type: "error".into(),
                                payload: json!({ "message": msg }),
                                request_id: rq,
                            },
                        ),
                    }
                });
                Ok(())
            }
            "settings.clear-cache.request" => {
                self.clear_dynamic_media_hosts();
                let (freed_mb, after_bytes) = clear_media_cache();
                self.precomputed_meta.clear();
                self.post_json(
                    "app.state",
                    json!({
                        "native": true,
                        "customCaptionButtons": true,
                        "settings": self.settings,
                        "detectedWorkshopRoots": self.detected_roots,
                        "gpuAdapters": self.gpu_adapters,
                        "activeHardwareAccelerationMode": self.active_hw_accel,
                        "cacheSizeBytes": after_bytes,
                    }),
                    req_id.as_deref(),
                );
                self.post_json(
                    "wallpapers.action.result",
                    json!({ "message": format!("已清理壁纸引擎缓存（释放 {freed_mb:.1} MB 空间），正在重新构建缩略图…") }),
                    req_id.as_deref(),
                );
                self.start_scan(req_id, false);
                Ok(())
            }
            "settings.get.request" => {
                self.post_json("settings.value", &self.settings, req_id.as_deref());
                Ok(())
            }
            "settings.update.request" => {
                let p = payload.ok_or_else(|| "设置内容为空。".to_string())?;
                let parsed: AppSettings = serde_json::from_value(p.clone())
                    .map_err(|_| "设置内容无效。".to_string())?;
                self.settings = sanitize_settings(parsed);
                save_settings_to(&settings_file_path(), &self.settings)?;
                self.sync_watcher_roots();
                self.apply_window_theme(self.settings.theme_mode == "dark");
                self.post_json("settings.value", &self.settings, req_id.as_deref());
                Ok(())
            }
            "settings.pick-workshop.request" => {
                let tx = self.tx.clone();
                let hwnd = self.hwnd.0 as isize;
                let rq = req_id.clone();
                std::thread::spawn(move || {
                    let picked = rfd::FileDialog::new()
                        .pick_folder()
                        .map(|p| p.to_string_lossy().into_owned());
                    send_ui(
                        &tx,
                        hwnd,
                        UiCommand::PickedWorkshopRoot {
                            request_id: rq,
                            path: picked,
                        },
                    );
                });
                Ok(())
            }
            "settings.pick-export.request" => {
                let tx = self.tx.clone();
                let hwnd = self.hwnd.0 as isize;
                let rq = req_id.clone();
                std::thread::spawn(move || {
                    let picked = rfd::FileDialog::new()
                        .pick_folder()
                        .map(|p| p.to_string_lossy().into_owned());
                    send_ui(
                        &tx,
                        hwnd,
                        UiCommand::PickedExportDir {
                            request_id: rq,
                            path: picked,
                        },
                    );
                });
                Ok(())
            }
            "settings.detect-workshop.request" => {
                let detected = locate_workshop_roots(None);
                self.detected_roots = detected.clone();
                for (i, root_path) in detected.iter().enumerate() {
                    self.map_media_root(&format!("workshop-{i}.wallpapervault"), root_path);
                }
                if let Some(first) = detected.first() {
                    self.settings.workshop_root = Some(first.clone());
                    let _ = save_settings_to(&settings_file_path(), &self.settings);
                    self.sync_watcher_roots();
                    self.post_json("settings.value", &self.settings, req_id.as_deref());
                }
                self.post_json(
                    "app.state",
                    json!({
                        "native": true,
                        "settings": self.settings,
                        "detectedWorkshopRoots": self.detected_roots,
                    }),
                    req_id.as_deref(),
                );
                let msg = if let Some(first) = detected.first() {
                    format!("已自动检测到创意工坊目录：{first}")
                } else {
                    "未在本机磁盘检测到 Wallpaper Engine 创意工坊目录，请手动选择".to_string()
                };
                self.post_json(
                    "wallpapers.action.result",
                    json!({ "message": msg }),
                    req_id.as_deref(),
                );
                Ok(())
            }
            _ => Ok(()),
        }
    }

    fn start_export_job(
        &mut self,
        ids: Vec<String>,
        dest: PathBuf,
        fmt: Option<String>,
        req_id: Option<String>,
    ) {
        self.export_cancel.store(true, Ordering::SeqCst);
        let cancel = Arc::new(AtomicBool::new(false));
        self.export_cancel = cancel.clone();
        let next_gen = self.export_gen.fetch_add(1, Ordering::SeqCst) + 1;
        let targets = resolve_target_items(&ids, &self.wallpapers);
        let tx = self.tx.clone();
        let hwnd = self.hwnd.0 as isize;
        let gen_ref = self.export_gen.clone();
        std::thread::spawn(move || {
            run_export_thread(&tx, hwnd, targets, dest, fmt, req_id, cancel, gen_ref, next_gen)
        });
    }

    fn start_scan(&mut self, request_id: Option<String>, force: bool) {
        self.scan_busy.store(true, Ordering::SeqCst);
        let next_gen = self.scan_gen.fetch_add(1, Ordering::SeqCst) + 1;
        self.scan_cancel.store(true, Ordering::SeqCst);
        if let Ok(guard) = self.watcher_cancel.lock() {
            if let Some(wc) = guard.as_ref() {
                wc.store(true, Ordering::SeqCst);
            }
        }
        let cancel = Arc::new(AtomicBool::new(false));
        self.scan_cancel = cancel.clone();
        self.active_scan_req = request_id.clone();

        self.post_json(
            "wallpapers.scan.status",
            json!({
                "message": if force {
                    "正在重新扫描本机创意工坊与原媒体…"
                } else {
                    "正在解析创意工坊中的原图与原视频…"
                }
            }),
            request_id.as_deref(),
        );

        let custom_roots = resolve_configured_workshop_roots(self.settings.workshop_root.as_deref());
        let parse_scenes = self.settings.parse_scenes;
        let use_hw_decode = self.active_hw_accel == "gpu";
        let export_dir = self.settings.export_directory.clone();
        let tx = self.tx.clone();
        let hwnd = self.hwnd.0 as isize;
        let gen_ref = self.scan_gen.clone();

        std::thread::spawn(move || {
            let detected = locate_workshop_roots(None);
            let roots = if custom_roots.is_empty() {
                detected.clone()
            } else {
                custom_roots
            };

            let req_progress = request_id.clone();
            let req_batch = request_id.clone();
            let res = scan_wallpapers_with_progress(
                &roots,
                parse_scenes,
                force,
                true,
                use_hw_decode,
                None,
                Some(&cancel),
                |info| {
                    if !cancel.load(Ordering::SeqCst) && gen_ref.load(Ordering::SeqCst) == next_gen {
                        send_ui(
                            &tx,
                            hwnd,
                            UiCommand::PostJson {
                                msg_type: "wallpapers.scan.status".into(),
                                payload: json!({
                                    "message": info.message,
                                    "phase": info.phase,
                                    "current": info.current,
                                    "total": info.total,
                                }),
                                request_id: req_progress.clone(),
                            },
                        );
                    }
                },
                |batch| {
                    if !cancel.load(Ordering::SeqCst)
                        && gen_ref.load(Ordering::SeqCst) == next_gen
                        && !batch.is_empty()
                    {
                        let metas = compute_items_meta(batch, &export_dir);
                        send_ui(
                            &tx,
                            hwnd,
                            UiCommand::ScanBatch {
                                request_id: req_batch.clone(),
                                scan_gen: next_gen,
                                items: batch.to_vec(),
                                metas,
                            },
                        );
                    }
                },
            );

            if !cancel.load(Ordering::SeqCst) && gen_ref.load(Ordering::SeqCst) == next_gen {
                let metas = compute_items_meta(&res.items, &export_dir);
                send_ui(
                    &tx,
                    hwnd,
                    UiCommand::ScanCompleted {
                        request_id,
                        scan_gen: next_gen,
                        items: res.items,
                        metas,
                        report: res.report,
                        detected_roots: detected,
                    },
                );
            }
        });
    }

    fn start_studio_open(&mut self, id: Option<String>, request_id: Option<String>) -> Result<(), String> {
        let wallpaper = self.find_wallpaper(id.as_deref())?;
        let scene_pkg = Path::new(&wallpaper.workshop_directory).join("scene.pkg");
        if !scene_pkg.is_file() {
            return Err("该壁纸不是可拆解的 2D scene.pkg 壁纸包。".to_string());
        }
        self.cleanup_studio_session(None);
        let studio_gen = self.studio_gen.fetch_add(1, Ordering::SeqCst) + 1;
        let tx = self.tx.clone();
        let hwnd = self.hwnd.0 as isize;
        let wp_id = wallpaper.id.clone();
        let title = wallpaper.title.clone();
        let mem_slot = self.studio_preview_bytes.clone();

        std::thread::spawn(move || {
            let Some(session) = open_studio_session(&scene_pkg) else {
                send_ui(
                    &tx,
                    hwnd,
                    UiCommand::PostJson {
                        msg_type: "error".into(),
                        payload: json!({ "message": "未能从该壁纸包解析出可编辑的 2D 图层。" }),
                        request_id,
                    },
                );
                return;
            };

            let default_set: HashSet<usize> = session
                .manifest
                .layers
                .iter()
                .filter(|l| l.default_visible)
                .map(|l| l.index)
                .collect();

            match session.render_subset_to_png_bytes(&default_set, 1440, true, false) {
                Ok((png_bytes, r)) => {
                    if let Ok(mut guard) = mem_slot.lock() {
                        *guard = Some((studio_gen, Arc::new(png_bytes)));
                    }
                    let preview_url =
                        format!("https://studio-mem.wallpapervault/preview-{studio_gen}.png");
                    send_ui(
                        &tx,
                        hwnd,
                        UiCommand::StudioOpened {
                            request_id,
                            studio_gen,
                            wallpaper_id: wp_id,
                            title,
                            session: Arc::new(session),
                            preview_url,
                            width: r.width,
                            height: r.height,
                            has_pixels: r.has_pixels,
                        },
                    );
                }
                Err(e) => {
                    send_ui(
                        &tx,
                        hwnd,
                        UiCommand::PostJson {
                            msg_type: "error".into(),
                            payload: json!({ "message": e }),
                            request_id,
                        },
                    );
                }
            }
        });
        Ok(())
    }

    fn start_studio_preview(&mut self, payload: Option<&Value>, request_id: Option<String>) {
        let Some((cur_id, session, _)) = &self.studio_session else {
            return;
        };
        if let Some(req_wp) = payload.and_then(|p| p.get("id")).and_then(|v| v.as_str()) {
            if !req_wp.is_empty() && req_wp != cur_id {
                return;
            }
        }
        let visible_set = read_layer_index_set(payload);
        let studio_gen = self.studio_gen.fetch_add(1, Ordering::SeqCst) + 1;
        let sess = session.clone();
        let wp_id = cur_id.clone();
        let tx = self.tx.clone();
        let hwnd = self.hwnd.0 as isize;
        let mem_slot = self.studio_preview_bytes.clone();

        std::thread::spawn(move || {
            if let Ok((png_bytes, r)) = sess.render_subset_to_png_bytes(&visible_set, 1440, true, false)
            {
                if let Ok(mut guard) = mem_slot.lock() {
                    *guard = Some((studio_gen, Arc::new(png_bytes)));
                }
                let preview_url =
                    format!("https://studio-mem.wallpapervault/preview-{studio_gen}.png");
                send_ui(
                    &tx,
                    hwnd,
                    UiCommand::StudioPreviewReady {
                        request_id,
                        studio_gen,
                        wallpaper_id: wp_id,
                        preview_url,
                        width: r.width,
                        height: r.height,
                        has_pixels: r.has_pixels,
                    },
                );
            }
        });
    }

    fn handle_studio_export(
        &self,
        payload: Option<&Value>,
        request_id: Option<String>,
    ) -> Result<(), String> {
        let Some((cur_id, session, _)) = &self.studio_session else {
            return Err("透视拆解台尚未打开任何壁纸。".to_string());
        };
        let wallpaper = self.find_wallpaper(Some(cur_id))?;
        let visible_set = read_layer_index_set(payload);
        let mode = payload
            .and_then(|p| p.get("mode"))
            .and_then(|v| v.as_str())
            .unwrap_or("composite")
            .to_string();
        let group_key = payload
            .and_then(|p| p.get("groupKey"))
            .and_then(|v| v.as_str())
            .map(ToString::to_string);
        let trim_bounds = payload
            .and_then(|p| p.get("trimBounds"))
            .and_then(|v| v.as_bool())
            .unwrap_or(true);
        let include_bg = payload
            .and_then(|p| p.get("includeBackground"))
            .and_then(|v| v.as_bool())
            .unwrap_or(false);

        let session_arc = session.clone();
        let export_dir = self.settings.export_directory.clone();
        let tx = self.tx.clone();
        let hwnd = self.hwnd.0 as isize;

        std::thread::spawn(move || {
            let result = execute_studio_export_task(
                &session_arc,
                &wallpaper,
                &visible_set,
                &mode,
                group_key.as_deref(),
                trim_bounds,
                include_bg,
                &export_dir,
            );
            send_ui(
                &tx,
                hwnd,
                UiCommand::StudioExportCompleted { request_id, result },
            );
        });
        Ok(())
    }

    pub fn close_studio_internal(&mut self) {
        self.cleanup_studio_session(None);
    }

    fn cleanup_studio_session_keep_mem(&mut self) {
        if let Some((_, _, last_prev)) = self.studio_session.take() {
            if let Some(p) = last_prev {
                let _ = fs::remove_file(p);
            }
        }
        let cache_dir = cache_root().join("layer-studio");
        cleanup_studio_cache_dir(&cache_dir, None);
    }

    fn cleanup_studio_session(&mut self, keep_path: Option<&Path>) {
        if let Ok(mut guard) = self.studio_preview_bytes.lock() {
            *guard = None;
        }
        if let Some((_, _, last_prev)) = self.studio_session.take() {
            if let Some(p) = last_prev {
                let keep_it = keep_path.is_some_and(|kp| is_same_studio_path(Path::new(&p), kp));
                if !keep_it {
                    let _ = fs::remove_file(p);
                }
            }
        }
        let cache_dir = cache_root().join("layer-studio");
        cleanup_studio_cache_dir(&cache_dir, keep_path);
    }

    fn find_wallpaper(&self, id: Option<&str>) -> Result<WallpaperItem, String> {
        id.and_then(|k| self.wallpapers.get(k))
            .cloned()
            .ok_or_else(|| "没有找到对应的壁纸项目。".to_string())
    }

    fn get_cached_extra(&mut self, item: &WallpaperItem) -> WorkshopExtraMetadata {
        let key = clean_path_str(Path::new(&item.workshop_directory)).to_ascii_lowercase();
        if let Some(meta) = self.precomputed_meta.get(&key) {
            return meta.extra.clone();
        }
        let extra = inspect_workshop_extra(&item.workshop_directory);
        let archived = is_archived_offline(item, &self.settings.export_directory);
        let has_scene_layers = item.item_type == "image"
            && has_inspectable_2d_scene(&item.workshop_directory);
        self.precomputed_meta.insert(
            key,
            ItemPrecomputedMeta {
                has_scene_layers,
                is_archived_offline: archived,
                extra: extra.clone(),
            },
        );
        extra
    }

    fn build_payload_item(&mut self, item: &WallpaperItem) -> Option<WallpaperPayloadItem> {
        let media_url = self.try_build_media_url(&item.source_path)?;
        let preview_url = if item.has_preview {
            self.try_build_media_url(&item.preview_path)
        } else {
            None
        };
        let preview_video_url = item
            .preview_video_path
            .as_deref()
            .and_then(|p| self.try_build_media_url(p));
        let asset_urls: Vec<String> = item
            .asset_paths
            .as_deref()
            .unwrap_or(std::slice::from_ref(&item.source_path))
            .iter()
            .filter_map(|p| self.try_build_media_url(p))
            .collect();
        let mut audio_tracks = Vec::new();
        if let Some(tracks) = &item.audio_paths {
            for p in tracks {
                let path = Path::new(p);
                if !path.is_file() {
                    continue;
                }
                if let Some(url) = self.try_build_media_url(p) {
                    let size = fs::metadata(path).map(|m| m.len() as i64).unwrap_or(0);
                    audio_tracks.push(AudioTrackPayload {
                        name: clean_track_title(p),
                        url,
                        size,
                    });
                }
            }
        }

        let meta_key = clean_path_str(Path::new(&item.workshop_directory)).to_ascii_lowercase();
        let meta = if let Some(cached) = self.precomputed_meta.get(&meta_key) {
            cached.clone()
        } else {
            let computed = ItemPrecomputedMeta {
                has_scene_layers: item.item_type == "image"
                    && has_inspectable_2d_scene(&item.workshop_directory),
                is_archived_offline: is_archived_offline(item, &self.settings.export_directory),
                extra: inspect_workshop_extra(&item.workshop_directory),
            };
            self.precomputed_meta.insert(meta_key, computed.clone());
            computed
        };

        let has_audio = !audio_tracks.is_empty();
        let asset_count = asset_urls.len().max(1);

        Some(WallpaperPayloadItem {
            id: item.id.clone(),
            workshop_id: item.workshop_id.clone(),
            title: item.title.clone(),
            item_type: item.item_type.clone(),
            original_type: item.original_type.clone(),
            has_preview: preview_url.is_some(),
            preview_url,
            preview_video_url,
            media_url,
            asset_urls,
            resolution: item.resolution.clone(),
            duration: item.duration.clone(),
            file_size: item.file_size,
            folder_size: if item.folder_size > 0 {
                item.folder_size
            } else {
                item.file_size
            },
            audio_tracks,
            has_audio,
            has_scene_layers: item.item_type == "image" && meta.has_scene_layers,
            asset_count,
            content_rating: meta.extra.content_rating,
            tags: meta.extra.tags,
            customizable_count: meta.extra.properties.len(),
            is_archived_offline: meta.is_archived_offline,
            color_bucket: item.color_bucket.clone(),
        })
    }

    fn map_initial_media_roots(&mut self) {
        let mut roots = resolve_configured_workshop_roots(self.settings.workshop_root.as_deref());
        if roots.is_empty() {
            roots = self.detected_roots.clone();
        }
        for (idx, root_dir) in roots.iter().enumerate() {
            self.map_media_root(&format!("workshop-{idx}.wallpapervault"), root_dir);
        }

        let cache = cache_root();
        for (sub, host) in [
            ("scenes", "scenes.wallpapervault"),
            ("video-previews", "video-previews.wallpapervault"),
            ("video-clips", "video-clips.wallpapervault"),
            ("layer-studio", "layer-studio.wallpapervault"),
        ] {
            let dir = cache.join(sub);
            let _ = fs::create_dir_all(&dir);
            self.map_media_root(host, &dir.to_string_lossy());
        }
    }

    fn map_media_root(&mut self, host: &str, directory: &str) {
        let norm = clean_path_str(Path::new(directory))
            .trim_end_matches(['\\', '/'])
            .to_string();
        if norm.is_empty() {
            return;
        }
        if let Some(existing) = self.mapped_hosts.get(host) {
            if existing.eq_ignore_ascii_case(&norm) {
                return;
            }
        }
        if let Some(wv) = &self.webview {
            if let Ok(wv3) = wv.cast::<ICoreWebView2_3>() {
                let res = unsafe {
                    wv3.SetVirtualHostNameToFolderMapping(
                        &HSTRING::from(host),
                        &HSTRING::from(&norm),
                        COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW,
                    )
                };
                if res.is_ok() {
                    self.mapped_hosts.insert(host.to_string(), norm);
                }
            }
        }
    }

    fn clear_dynamic_media_hosts(&mut self) {
        let dyn_hosts: Vec<String> = self
            .mapped_hosts
            .keys()
            .filter(|h| h.starts_with("media-"))
            .cloned()
            .collect();
        if let Some(wv) = &self.webview {
            if let Ok(wv3) = wv.cast::<ICoreWebView2_3>() {
                for host in &dyn_hosts {
                    unsafe {
                        let _ = wv3.ClearVirtualHostNameToFolderMapping(&HSTRING::from(host.as_str()));
                    }
                }
            }
        }
        for host in dyn_hosts {
            self.mapped_hosts.remove(&host);
        }
    }

    fn try_build_media_url(&mut self, path_str: &str) -> Option<String> {
        let clean_input = strip_verbatim_prefix(path_str);
        if clean_input.is_empty() {
            return None;
        }
        let path = Path::new(&clean_input);
        if !path.is_file() {
            return None;
        }
        let full_str = clean_path_str(path);

        for (host, root) in &self.mapped_hosts {
            if let Some(rel) = strip_root_case_insensitive(&full_str, root) {
                let encoded = encode_url_path(rel);
                return Some(format!("https://{host}/{encoded}"));
            }
        }

        let dir = Path::new(&full_str).parent()?;
        let dir_str = clean_path_str(dir).trim_end_matches(['\\', '/']).to_string();
        let mut hasher = Sha256::new();
        hasher.update(dir_str.to_lowercase().as_bytes());
        let hex_digest = hex::encode(hasher.finalize());
        let host = format!("media-{}.wallpapervault", &hex_digest[..16]);
        self.map_media_root(&host, &dir_str);
        let file_name = Path::new(&full_str).file_name()?.to_string_lossy();
        Some(format!("https://{host}/{}", urlencoding::encode(&file_name)))
    }

    fn sync_watcher_roots(&self) {
        let configured = resolve_configured_workshop_roots(self.settings.workshop_root.as_deref());
        let target = if configured.is_empty() {
            self.detected_roots.clone()
        } else {
            configured
        };
        if let Ok(mut guard) = self.watcher_roots.lock() {
            *guard = target;
        }
        if let Ok(mut guard) = self.watcher_export_dir.lock() {
            *guard = self.settings.export_directory.clone();
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn execute_studio_export_task(
    session: &SceneStudioSession,
    wallpaper: &WallpaperItem,
    visible_set: &HashSet<usize>,
    mode: &str,
    group_key: Option<&str>,
    trim_bounds: bool,
    include_bg: bool,
    export_directory: &str,
) -> Result<String, String> {
    let studio_folder = Path::new(export_directory).join("立绘拆解");
    let safe_title = crate::actions::get_safe_file_name(&wallpaper.title, &wallpaper.workshop_id);

    match mode {
        "all-characters" => {
            fs::create_dir_all(&studio_folder).map_err(|e| e.to_string())?;
            let targets: Vec<_> = session
                .manifest
                .groups
                .iter()
                .filter(|g| matches!(g.role.as_str(), "character" | "subject"))
                .collect();
            if targets.is_empty() {
                return Err("当前壁纸未识别到独立的人物/主体分组，可直接自定义勾选图层后导出。".to_string());
            }
            let mut count = 0usize;
            for group in targets {
                let safe_g = crate::actions::get_safe_file_name(&group.title, &group.key);
                let dest = crate::actions::get_unique_destination_path(
                    &studio_folder,
                    &format!("{safe_title} - {safe_g}.png"),
                );
                let mut indices: HashSet<usize> = group
                    .layer_indices
                    .iter()
                    .copied()
                    .filter(|i| visible_set.contains(i))
                    .collect();
                if indices.is_empty() {
                    indices = group.layer_indices.iter().copied().collect();
                }
                let r = session.render_subset_to_png(&dest, &indices, 0, true, trim_bounds)?;
                if !r.has_pixels {
                    let _ = fs::remove_file(&dest);
                    continue;
                }
                count += 1;
            }
            Ok(format!("已批量导出 {count} 张 4K 透明角色立绘到「立绘拆解」文件夹"))
        }
        "group" => {
            let gk = group_key.ok_or_else(|| "找不到对应的图层分组。".to_string())?;
            let group = session
                .manifest
                .groups
                .iter()
                .find(|g| g.key == gk)
                .ok_or_else(|| "找不到对应的图层分组。".to_string())?;
            fs::create_dir_all(&studio_folder).map_err(|e| e.to_string())?;
            let safe_g = crate::actions::get_safe_file_name(&group.title, &group.key);
            let dest = crate::actions::get_unique_destination_path(
                &studio_folder,
                &format!("{safe_title} - {safe_g}.png"),
            );
            let mut indices: HashSet<usize> = group
                .layer_indices
                .iter()
                .copied()
                .filter(|i| visible_set.contains(i))
                .collect();
            if indices.is_empty() {
                indices = group.layer_indices.iter().copied().collect();
            }
            let r = session.render_subset_to_png(&dest, &indices, 0, true, trim_bounds)?;
            if !r.has_pixels {
                let _ = fs::remove_file(&dest);
                return Err(format!("分组「{}」当前没有可见像素。", group.title));
            }
            Ok(format!(
                "已导出「{}」({}×{} 透明 PNG)",
                group.title, r.width, r.height
            ))
        }
        "set-desktop" => {
            let cache_dir = cache_root().join("layer-studio");
            let _ = fs::create_dir_all(&cache_dir);
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0);
            let desk_path = cache_dir.join(format!("desktop-{}-{stamp}.png", wallpaper.workshop_id));
            session.render_subset_to_png(&desk_path, visible_set, 0, false, false)?;
            let synced = apply_custom_image(&desk_path, &format!("{} - 拆解画面", wallpaper.title))?;
            Ok(if synced {
                "已将当前拆解画面联动 Wallpaper Engine 设为桌面壁纸".to_string()
            } else {
                "已将当前拆解画面设为 Windows 桌面壁纸".to_string()
            })
        }
        "copy" => {
            let cache_dir = cache_root().join("layer-studio");
            let _ = fs::create_dir_all(&cache_dir);
            let copy_path = cache_dir.join(format!("{safe_title} - 拆解透明图.png"));
            let r = session.render_subset_to_png(
                &copy_path,
                visible_set,
                0,
                !include_bg,
                !include_bg && trim_bounds,
            )?;
            if !r.has_pixels {
                return Err("当前勾选图层画面为空，请至少保留一个可见图层。".to_string());
            }
            copy_media_to_clipboard(&copy_path, true)?;
            Ok(format!(
                "已复制拆解图 ({}×{} PNG) 到剪贴板",
                r.width, r.height
            ))
        }
        _ => {
            fs::create_dir_all(&studio_folder).map_err(|e| e.to_string())?;
            let suffix = if include_bg { "自定义合成" } else { "透明立绘" };
            let dest = crate::actions::get_unique_destination_path(
                &studio_folder,
                &format!("{safe_title} - {suffix}.png"),
            );
            let r = session.render_subset_to_png(
                &dest,
                visible_set,
                0,
                !include_bg,
                !include_bg && trim_bounds,
            )?;
            if !r.has_pixels {
                let _ = fs::remove_file(&dest);
                return Err("当前勾选图层画面为空，无法导出。".to_string());
            }
            let name = dest.file_name().and_then(|n| n.to_str()).unwrap_or("");
            Ok(format!("已导出 4K 拆解文件：{name} ({}×{})", r.width, r.height))
        }
    }
}

fn encode_url_path(rel: &str) -> String {
    rel.split(['\\', '/'])
        .filter(|s| !s.is_empty())
        .map(|seg| urlencoding::encode(seg).into_owned())
        .collect::<Vec<_>>()
        .join("/")
}

fn calculate_distinct_workshop_bytes(items: &[WallpaperItem]) -> i64 {
    let mut seen = HashSet::new();
    let mut sum = 0i64;
    for item in items {
        if seen.insert(item.workshop_id.as_str()) {
            sum += if item.folder_size > 0 {
                item.folder_size
            } else {
                item.file_size
            };
        }
    }
    sum
}

#[allow(clippy::too_many_arguments)]
fn run_export_thread(
    tx: &mpsc::Sender<UiCommand>,
    hwnd: isize,
    targets: Vec<WallpaperItem>,
    dest: PathBuf,
    fmt: Option<String>,
    req_id: Option<String>,
    cancel: Arc<AtomicBool>,
    gen_ref: Arc<AtomicU64>,
    my_gen: u64,
) {
    match export_wallpapers(&targets, &dest, fmt.as_deref(), Some(&cancel), |msg| {
        if !cancel.load(Ordering::SeqCst) && gen_ref.load(Ordering::SeqCst) == my_gen {
            send_ui(
                tx,
                hwnd,
                UiCommand::PostJson {
                    msg_type: "wallpapers.action.result".into(),
                    payload: json!({ "message": msg }),
                    request_id: req_id.clone(),
                },
            );
        }
    }) {
        Ok((file_cnt, out_dir)) => {
            if !cancel.load(Ordering::SeqCst) && gen_ref.load(Ordering::SeqCst) == my_gen {
                send_ui(
                    tx,
                    hwnd,
                    UiCommand::PostJson {
                        msg_type: "wallpapers.action.result".into(),
                        payload: json!({
                            "message": format!("已导出 {file_cnt} 个文件到 {out_dir}"),
                            "exported": targets.len(),
                            "destination": out_dir,
                        }),
                        request_id: req_id,
                    },
                );
            }
        }
        Err(msg) => {
            if !cancel.load(Ordering::SeqCst) && gen_ref.load(Ordering::SeqCst) == my_gen {
                send_ui(
                    tx,
                    hwnd,
                    UiCommand::PostJson {
                        msg_type: "error".into(),
                        payload: json!({ "message": msg }),
                        request_id: req_id,
                    },
                );
            }
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
struct ProjectDirStamp {
    has_project_json: bool,
    entry_count: usize,
    total_bytes: u64,
    max_mtime_nanos: u128,
}

fn stamp_project_dir(project_dir: &Path) -> ProjectDirStamp {
    let mut has_project_json = false;
    let mut entry_count = 0usize;
    let mut total_bytes = 0u64;
    let mut max_mtime_nanos = 0u128;

    let mut stack = vec![(project_dir.to_path_buf(), 0u32)];
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
            entry_count += 1;
            if let Ok(mt) = meta.modified() {
                if let Ok(dur) = mt.duration_since(std::time::UNIX_EPOCH) {
                    max_mtime_nanos = max_mtime_nanos.max(dur.as_nanos());
                }
            }
            if meta.is_dir() {
                if depth < 2 {
                    stack.push((p, depth + 1));
                }
            } else if meta.is_file() {
                total_bytes = total_bytes.saturating_add(meta.len());
                if depth == 0
                    && p.file_name()
                        .and_then(|n| n.to_str())
                        .map(|n| n.eq_ignore_ascii_case("project.json"))
                        .unwrap_or(false)
                {
                    has_project_json = true;
                }
            }
        }
    }

    ProjectDirStamp {
        has_project_json,
        entry_count,
        total_bytes,
        max_mtime_nanos,
    }
}

fn snapshot_workshop_dirs(roots: &[String]) -> HashMap<String, ProjectDirStamp> {
    let mut map = HashMap::new();
    for root in roots {
        if let Ok(entries) = fs::read_dir(root) {
            for e in entries.flatten() {
                let p = e.path();
                if !p.is_dir() {
                    continue;
                }
                let Some(name) = p.file_name().and_then(|n| n.to_str()) else {
                    continue;
                };
                if name.is_empty() || !name.chars().all(|c| c.is_ascii_digit()) {
                    continue;
                }
                let key = format!("{}\\{}", root.trim_end_matches(['\\', '/']), name);
                map.insert(key, stamp_project_dir(&p));
            }
        }
    }
    map
}

#[allow(clippy::too_many_arguments)]
fn start_watcher_thread(
    tx: mpsc::Sender<UiCommand>,
    hwnd: isize,
    roots_lock: Arc<Mutex<Vec<String>>>,
    export_dir_lock: Arc<Mutex<String>>,
    use_hw_decode: bool,
    scan_busy: Arc<AtomicBool>,
    scan_gen: Arc<AtomicU64>,
    watcher_cancel_slot: Arc<Mutex<Option<Arc<AtomicBool>>>>,
    watcher_stop: Arc<AtomicBool>,
) {
    std::thread::spawn(move || {
        let mut confirmed_snapshot: Option<HashMap<String, ProjectDirStamp>> = None;
        let mut pending_snapshot: Option<(HashMap<String, ProjectDirStamp>, std::time::Instant)> =
            None;

        loop {
            std::thread::sleep(std::time::Duration::from_millis(2000));
            if watcher_stop.load(Ordering::SeqCst) {
                break;
            }
            if scan_busy.load(Ordering::SeqCst) {
                pending_snapshot = None;
                continue;
            }
            let roots = roots_lock.lock().map(|g| g.clone()).unwrap_or_default();
            if roots.is_empty() {
                continue;
            }
            let cur_snapshot = snapshot_workshop_dirs(&roots);
            let Some(confirmed) = &confirmed_snapshot else {
                confirmed_snapshot = Some(cur_snapshot);
                continue;
            };
            if *confirmed == cur_snapshot {
                pending_snapshot = None;
                continue;
            }

            // Require two identical polling windows (and project.json presence for brand-new folders up to 20s)
            // before triggering a watcher scan so mid-download Steam transfers are never misread.
            let stabilized = match &pending_snapshot {
                Some((prev_pend, first_seen)) if *prev_pend == cur_snapshot => {
                    let missing_new_pj = cur_snapshot.iter().any(|(k, stamp)| {
                        !confirmed.contains_key(k) && !stamp.has_project_json
                    });
                    !missing_new_pj || first_seen.elapsed().as_secs() >= 20
                }
                _ => {
                    pending_snapshot = Some((cur_snapshot, std::time::Instant::now()));
                    continue;
                }
            };
            if !stabilized {
                continue;
            }

            if scan_busy
                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                .is_err()
            {
                continue;
            }
            let gen_at_start = scan_gen.load(Ordering::SeqCst);
            let w_cancel = Arc::new(AtomicBool::new(false));
            if let Ok(mut guard) = watcher_cancel_slot.lock() {
                *guard = Some(w_cancel.clone());
            }

            let detected = locate_workshop_roots(None);
            let res = scan_wallpapers(
                &roots,
                true,
                false,
                true,
                use_hw_decode,
                None,
                Some(&w_cancel),
                |_| {},
                |_| {},
            );

            if let Ok(mut guard) = watcher_cancel_slot.lock() {
                *guard = None;
            }

            let aborted = w_cancel.load(Ordering::SeqCst)
                || watcher_stop.load(Ordering::SeqCst)
                || scan_gen.load(Ordering::SeqCst) != gen_at_start;
            if aborted {
                if scan_gen.load(Ordering::SeqCst) == gen_at_start {
                    scan_busy.store(false, Ordering::SeqCst);
                }
                pending_snapshot = None;
                continue;
            }

            let export_dir = export_dir_lock
                .lock()
                .map(|g| g.clone())
                .unwrap_or_default();
            let metas = compute_items_meta(&res.items, &export_dir);
            confirmed_snapshot = Some(cur_snapshot);
            pending_snapshot = None;
            send_ui(
                &tx,
                hwnd,
                UiCommand::WatcherSyncCompleted {
                    scan_gen: gen_at_start,
                    items: res.items,
                    metas,
                    report: res.report,
                    detected_roots: detected,
                },
            );
        }
    });
}

fn strip_root_case_insensitive<'a>(full_str: &'a str, root: &str) -> Option<&'a str> {
    let root_clean = root.trim_end_matches(['\\', '/']);
    if root_clean.is_empty() {
        return None;
    }
    let mut f_chars = full_str.char_indices();
    for rc in root_clean.chars() {
        let (_, fc) = f_chars.next()?;
        let eq = fc == rc
            || ((fc == '\\' || fc == '/') && (rc == '\\' || rc == '/'))
            || fc.to_lowercase().eq(rc.to_lowercase());
        if !eq {
            return None;
        }
    }
    let (_, sep) = f_chars.next()?;
    if sep != '\\' && sep != '/' {
        return None;
    }
    let next_idx = f_chars.next().map(|(i, _)| i).unwrap_or(full_str.len());
    Some(&full_str[next_idx..])
}

fn send_ui(tx: &mpsc::Sender<UiCommand>, hwnd_raw: isize, cmd: UiCommand) {
    let _ = tx.send(cmd);
    let hwnd = HWND(hwnd_raw as *mut core::ffi::c_void);
    unsafe {
        let _ = PostMessageW(Some(hwnd), WM_UI_COMMAND, WPARAM(0), LPARAM(0));
    }
}

fn hash_embedded_dir(dir: &Dir<'_>, hasher: &mut Sha256) {
    for entry in dir.entries() {
        match entry {
            include_dir::DirEntry::Dir(sub) => hash_embedded_dir(sub, hasher),
            include_dir::DirEntry::File(file) => {
                let rel = file.path().to_string_lossy().replace('\\', "/");
                hasher.update(rel.as_bytes());
                hasher.update([0]);
                hasher.update((file.contents().len() as u64).to_le_bytes());
                hasher.update(file.contents());
            }
        }
    }
}

fn write_embedded_dir(dir: &Dir<'_>, target_root: &Path) -> Result<(), String> {
    for entry in dir.entries() {
        match entry {
            include_dir::DirEntry::Dir(sub) => write_embedded_dir(sub, target_root)?,
            include_dir::DirEntry::File(file) => {
                let out_path = target_root.join(file.path());
                if let Some(parent) = out_path.parent() {
                    fs::create_dir_all(parent)
                        .map_err(|e| format!("创建内置资源目录失败：{e}"))?;
                }
                fs::write(&out_path, file.contents())
                    .map_err(|e| format!("写入内置资源失败（{}）：{e}", out_path.display()))?;
            }
        }
    }
    Ok(())
}

fn ensure_embedded_web_assets() -> Result<PathBuf, String> {
    let mut hasher = Sha256::new();
    hash_embedded_dir(&DIST_DIR, &mut hasher);
    let full_hex = hex::encode(hasher.finalize());
    let ver_dir_name = format!("v-{}", &full_hex[..16]);

    let web_assets_root = crate::settings::local_app_data_root().join("WebAssets");
    let target = web_assets_root.join(&ver_dir_name);
    if target.join(".ready").is_file() && target.join("index.html").is_file() {
        return Ok(target);
    }

    let _ = fs::create_dir_all(&web_assets_root);
    if let Ok(entries) = fs::read_dir(&web_assets_root) {
        for e in entries.flatten() {
            let p = e.path();
            if p.is_dir()
                && p.file_name()
                    .and_then(|n| n.to_str())
                    .map(|n| n.starts_with("v-") && n != ver_dir_name)
                    .unwrap_or(false)
            {
                let _ = fs::remove_dir_all(p);
            }
        }
    }

    write_embedded_dir(&DIST_DIR, &target)?;
    fs::write(target.join(".ready"), b"ok")
        .map_err(|e| format!("写入前端资源就绪标记失败：{e}"))?;
    Ok(target)
}

fn create_wv_environment(user_data_dir: &Path, browser_args: &str) -> Result<ICoreWebView2Environment, String> {
    let opts: ICoreWebView2EnvironmentOptions = {
        let raw = CoreWebView2EnvironmentOptions::default();
        unsafe {
            raw.set_additional_browser_arguments(browser_args.to_string());
        }
        raw.into()
    };

    let (tx, rx) = mpsc::channel();
    let dir_h = HSTRING::from(user_data_dir.to_string_lossy().as_ref());
    CreateCoreWebView2EnvironmentCompletedHandler::wait_for_async_operation(
        Box::new(move |handler| unsafe {
            CreateCoreWebView2EnvironmentWithOptions(
                PCWSTR::null(),
                &dir_h,
                &opts,
                &handler,
            )
            .map_err(webview2_com::Error::WindowsError)
        }),
        Box::new(move |hr, env| {
            hr?;
            let _ = tx.send(env.ok_or_else(|| windows::core::Error::from(E_POINTER)));
            Ok(())
        }),
    )
    .map_err(|e| format!("WebView2 初始化失败（请确认本机已安装 WebView2 Runtime）：{e}"))?;

    rx.recv()
        .map_err(|_| "WebView2 环境创建通道异常。".to_string())?
        .map_err(|e| format!("WebView2 环境创建错误：{e}"))
}

fn create_wv_controller(
    env: &ICoreWebView2Environment,
    hwnd: HWND,
) -> Result<ICoreWebView2Controller, String> {
    let (tx, rx) = mpsc::channel();
    let env_clone = env.clone();
    CreateCoreWebView2ControllerCompletedHandler::wait_for_async_operation(
        Box::new(move |handler| unsafe {
            env_clone
                .CreateCoreWebView2Controller(hwnd, &handler)
                .map_err(webview2_com::Error::WindowsError)
        }),
        Box::new(move |hr, ctrl| {
            hr?;
            let _ = tx.send(ctrl.ok_or_else(|| windows::core::Error::from(E_POINTER)));
            Ok(())
        }),
    )
    .map_err(|e| format!("WebView2 Controller 创建失败：{e}"))?;

    rx.recv()
        .map_err(|_| "WebView2 Controller 通道异常。".to_string())?
        .map_err(|e| format!("WebView2 Controller 错误：{e}"))
}

fn has_other_running_instance() -> bool {
    let cur = std::process::id();
    let Ok(snap) = (unsafe {
        windows::Win32::System::Diagnostics::ToolHelp::CreateToolhelp32Snapshot(
            windows::Win32::System::Diagnostics::ToolHelp::TH32CS_SNAPPROCESS,
            0,
        )
    }) else {
        return false;
    };
    let mut entry = windows::Win32::System::Diagnostics::ToolHelp::PROCESSENTRY32W {
        dwSize: size_of::<windows::Win32::System::Diagnostics::ToolHelp::PROCESSENTRY32W>() as u32,
        ..Default::default()
    };
    let mut found = false;
    unsafe {
        if windows::Win32::System::Diagnostics::ToolHelp::Process32FirstW(snap, &mut entry).is_ok() {
            loop {
                if entry.th32ProcessID != cur {
                    let end = entry.szExeFile.iter().position(|&c| c == 0).unwrap_or(entry.szExeFile.len());
                    let name = String::from_utf16_lossy(&entry.szExeFile[..end]).to_ascii_lowercase();
                    if name == "wallpull.exe" || name == "wallpapervault.exe" {
                        found = true;
                        break;
                    }
                }
                if windows::Win32::System::Diagnostics::ToolHelp::Process32NextW(snap, &mut entry).is_err() {
                    break;
                }
            }
        }
        let _ = windows::Win32::Foundation::CloseHandle(snap);
    }
    found
}

fn cleanup_stale_webview_sessions(wv_root: &Path) {
    let Ok(entries) = fs::read_dir(wv_root) else {
        return;
    };
    let cur = std::process::id();
    for e in entries.flatten() {
        let p = e.path();
        if !p.is_dir() {
            continue;
        }
        let Some(name) = p.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        let Some(pid_str) = name.strip_prefix("session-") else {
            continue;
        };
        let Ok(pid) = pid_str.parse::<u32>() else {
            continue;
        };
        if pid == cur {
            continue;
        }
        let alive = unsafe {
            windows::Win32::System::Threading::OpenProcess(
                windows::Win32::System::Threading::PROCESS_QUERY_LIMITED_INFORMATION,
                false,
                pid,
            )
            .ok()
            .map(|h| {
                let mut code = 0u32;
                let ok = windows::Win32::System::Threading::GetExitCodeProcess(h, &mut code).is_ok()
                    && code == 259; // STILL_ACTIVE
                let _ = windows::Win32::Foundation::CloseHandle(h);
                ok
            })
            .unwrap_or(false)
        };
        if !alive {
            let _ = fs::remove_dir_all(p);
        }
    }
}

fn read_id(payload: Option<&Value>) -> Option<String> {
    payload
        .and_then(|p| p.get("id"))
        .and_then(|v| v.as_str())
        .map(ToString::to_string)
}

fn read_ids(payload: Option<&Value>) -> Vec<String> {
    let Some(p) = payload else {
        return Vec::new();
    };
    if let Some(arr) = p.get("ids").and_then(|v| v.as_array()) {
        return arr
            .iter()
            .filter_map(|v| v.as_str().map(str::trim))
            .filter(|s| !s.is_empty())
            .map(ToString::to_string)
            .collect();
    }
    if let Some(single) = p.get("id").and_then(|v| v.as_str()).filter(|s| !s.trim().is_empty()) {
        return vec![single.to_string()];
    }
    Vec::new()
}

fn read_layer_index_set(payload: Option<&Value>) -> HashSet<usize> {
    let mut set = HashSet::new();
    let arr = payload.and_then(|p| {
        p.get("layerIndices")
            .or_else(|| p.get("visibleLayerIndices"))
            .and_then(|v| v.as_array())
    });
    if let Some(items) = arr {
        for v in items {
            if let Some(idx) = v.as_u64() {
                set.insert(idx as usize);
            }
        }
    }
    set
}

fn is_same_studio_path(a: &Path, b: &Path) -> bool {
    clean_path_str(a).eq_ignore_ascii_case(&clean_path_str(b))
}

fn cleanup_studio_cache_dir(cache_dir: &Path, keep_path: Option<&Path>) {
    if let Ok(entries) = fs::read_dir(cache_dir) {
        for e in entries.flatten() {
            let p = e.path();
            let is_studio_png = p
                .file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.starts_with("studio-") && n.ends_with(".png"))
                .unwrap_or(false);
            if !is_studio_png {
                continue;
            }
            if keep_path.is_some_and(|kp| is_same_studio_path(&p, kp)) {
                continue;
            }
            let _ = fs::remove_file(p);
        }
    }
}

#[allow(dead_code)]
fn _unused_helpers_check() {
    let _ = find_executable("ffmpeg.exe");
    let _ = is_recognized_media_path(Path::new("a.png"));
    let _ = probe_or_fallback(Path::new("a.png"), None);
    let _ = extract_scene_assets;
}

#[cfg(test)]
mod tests {
    use super::{cleanup_studio_cache_dir, strip_root_case_insensitive};
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn unicode_prefix_strip_handles_non_ascii_without_panic() {
        assert_eq!(
            strip_root_case_insensitive(
                r"D:\Straße\WALLPULL\431960\file.png",
                r"D:\STRASSE\wallpull"
            ),
            None
        );
        assert_eq!(
            strip_root_case_insensitive(
                r"D:\壁纸库\Über\Preview.jpg",
                r"d:\壁纸库\über"
            ),
            Some("Preview.jpg")
        );
        assert_eq!(
            strip_root_case_insensitive(r"C:\foo_bar\a.png", r"C:\foo"),
            None
        );
    }

    #[test]
    fn cleanup_studio_session_preserves_keep_path_and_removes_stale_pngs() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!("wallpull_studio_cleanup_{stamp}"));
        fs::create_dir_all(&dir).expect("create temp dir");

        let keep_file = dir.join("studio-2343060304-new.png");
        let stale_file = dir.join("studio-2343060304-old.png");
        let unrelated_file = dir.join("notes.txt");
        fs::write(&keep_file, b"keep").unwrap();
        fs::write(&stale_file, b"stale").unwrap();
        fs::write(&unrelated_file, b"other").unwrap();

        cleanup_studio_cache_dir(&dir, Some(&keep_file));

        assert!(keep_file.is_file(), "newly generated preview must be preserved");
        assert!(!stale_file.exists(), "stale studio png must be removed");
        assert!(unrelated_file.is_file(), "unrelated files must remain untouched");

        cleanup_studio_cache_dir(&dir, None);
        assert!(!keep_file.exists(), "cleanup with keep_path=None removes all studio pngs");

        let _ = fs::remove_dir_all(&dir);
    }
}
