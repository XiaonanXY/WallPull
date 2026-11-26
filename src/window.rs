use crate::bridge::{AppController, UiCommand, WM_UI_COMMAND};
use crate::tray::{CMD_TRAY_EXIT, CMD_TRAY_SHOW, TrayManager, WM_TRAY_CALLBACK};
use serde_json::json;
use std::sync::atomic::{AtomicIsize, AtomicU32, Ordering};
use windows::Win32::Foundation::{
    CloseHandle, ERROR_ALREADY_EXISTS, GetLastError, HANDLE, HWND, LPARAM, LRESULT, POINT, RECT,
    WPARAM,
};
use windows::Win32::Graphics::Dwm::{
    DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND, DwmExtendFrameIntoClientArea,
    DwmSetWindowAttribute,
};
use windows::Win32::Graphics::Gdi::{
    BLACK_BRUSH, GetMonitorInfoW, GetStockObject, HBRUSH, MONITOR_DEFAULTTONEAREST, MONITORINFO,
    MonitorFromWindow, UpdateWindow,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::Controls::MARGINS;
use windows::Win32::UI::HiDpi::{
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, GetDpiForWindow, GetSystemMetricsForDpi,
    SetProcessDpiAwarenessContext,
};
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{PCWSTR, w};

static WM_TASKBAR_CREATED: AtomicU32 = AtomicU32::new(0);
static WM_ACTIVATE_EXISTING: AtomicU32 = AtomicU32::new(0);
static SINGLE_INSTANCE_MUTEX: AtomicIsize = AtomicIsize::new(0);

struct WindowState {
    app: Box<AppController>,
    tray: TrayManager,
}

unsafe fn get_state_mut(hwnd: HWND) -> Option<&'static mut WindowState> {
    let ptr = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) } as *mut WindowState;
    if ptr.is_null() {
        None
    } else {
        Some(unsafe { &mut *ptr })
    }
}

pub fn release_single_instance_mutex() {
    let raw = SINGLE_INSTANCE_MUTEX.swap(0, Ordering::SeqCst);
    if raw != 0 {
        unsafe {
            let _ = CloseHandle(HANDLE(raw as *mut core::ffi::c_void));
        }
    }
}

struct MutexGuardHandle;

impl Drop for MutexGuardHandle {
    fn drop(&mut self) {
        release_single_instance_mutex();
    }
}

unsafe fn restore_and_activate_window(hwnd: HWND) {
    unsafe {
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        } else {
            let _ = ShowWindow(hwnd, SW_SHOW);
        }
        let _ = SetForegroundWindow(hwnd);
        if let Some(st) = get_state_mut(hwnd) {
            st.app.focus_webview();
        }
    }
}

pub fn run_app(self_test: bool) -> Result<(), String> {
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let wm_taskbar = RegisterWindowMessageW(w!("TaskbarCreated"));
        WM_TASKBAR_CREATED.store(wm_taskbar, Ordering::Relaxed);
        let wm_activate = RegisterWindowMessageW(w!("WallPull_ActivateExistingInstance"));
        WM_ACTIVATE_EXISTING.store(wm_activate, Ordering::Relaxed);

        let class_name = w!("WallPullMainWindowClass");
        let _single_instance_guard = if !self_test {
            match CreateMutexW(None, false, w!("Local\\WallPull_SingleInstance_Mutex_v1")) {
                Ok(h_mutex) => {
                    if GetLastError() == ERROR_ALREADY_EXISTS {
                        let _ = CloseHandle(h_mutex);
                        for _ in 0..5 {
                            if let Ok(existing) = FindWindowW(class_name, PCWSTR::null()) {
                                if !existing.0.is_null() {
                                    let mut existing_pid = 0u32;
                                    GetWindowThreadProcessId(existing, Some(&mut existing_pid));
                                    if existing_pid != 0 {
                                        let _ = AllowSetForegroundWindow(existing_pid);
                                    }
                                    let _ = PostMessageW(
                                        Some(existing),
                                        wm_activate,
                                        WPARAM(0),
                                        LPARAM(0),
                                    );
                                    break;
                                }
                            }
                            std::thread::sleep(std::time::Duration::from_millis(80));
                        }
                        return Ok(());
                    }
                    SINGLE_INSTANCE_MUTEX.store(h_mutex.0 as isize, Ordering::SeqCst);
                    MutexGuardHandle
                }
                Err(_) => MutexGuardHandle,
            }
        } else {
            MutexGuardHandle
        };

        let hinstance = GetModuleHandleW(None).map_err(|e| format!("GetModuleHandleW 失败：{e}"))?;
        let icon_big = LoadImageW(
            Some(hinstance.into()),
            PCWSTR(1usize as *const u16),
            IMAGE_ICON,
            48,
            48,
            LR_SHARED,
        )
        .ok()
        .map(|h| HICON(h.0))
        .unwrap_or_default();
        let icon_small = LoadImageW(
            Some(hinstance.into()),
            PCWSTR(1usize as *const u16),
            IMAGE_ICON,
            16,
            16,
            LR_SHARED,
        )
        .ok()
        .map(|h| HICON(h.0))
        .unwrap_or_default();

        let wc = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(wnd_proc),
            hInstance: hinstance.into(),
            hIcon: icon_big,
            hIconSm: icon_small,
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            hbrBackground: HBRUSH(GetStockObject(BLACK_BRUSH).0),
            lpszClassName: class_name,
            ..Default::default()
        };
        RegisterClassExW(&wc);

        let initial_w = 1280;
        let initial_h = 860;
        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            class_name,
            w!("WallPull"),
            WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            initial_w,
            initial_h,
            None,
            None,
            Some(hinstance.into()),
            None,
        )
        .map_err(|e| format!("创建主窗口失败：{e}"))?;

        let dpi = GetDpiForWindow(hwnd).max(96);
        let scaled_w = (initial_w * dpi as i32) / 96;
        let scaled_h = (initial_h * dpi as i32) / 96;
        let _ = SetWindowPos(
            hwnd,
            None,
            0,
            0,
            scaled_w,
            scaled_h,
            SWP_NOMOVE | SWP_NOZORDER | SWP_FRAMECHANGED,
        );

        let corner_pref = DWMWCP_ROUND.0 as u32;
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_WINDOW_CORNER_PREFERENCE,
            &corner_pref as *const u32 as *const _,
            size_of::<u32>() as u32,
        );
        let margins = MARGINS {
            cxLeftWidth: 0,
            cxRightWidth: 0,
            cyTopHeight: 1,
            cyBottomHeight: 0,
        };
        let _ = DwmExtendFrameIntoClientArea(hwnd, &margins);

        let app = AppController::new(hwnd, self_test);
        let tray = TrayManager::new(hwnd);

        let state = Box::new(WindowState { app, tray });
        let state_ptr = Box::into_raw(state);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, state_ptr as isize);

        if let Some(st) = get_state_mut(hwnd) {
            st.app.apply_window_theme(st.app.settings.theme_mode == "dark");
        }

        if self_test {
            let _ = ShowWindow(hwnd, SW_SHOWMINNOACTIVE);
            let _ = UpdateWindow(hwnd);
        } else {
            let _ = ShowWindow(hwnd, SW_SHOW);
            let _ = UpdateWindow(hwnd);
            let _ = SetForegroundWindow(hwnd);
        }

        if let Some(st) = get_state_mut(hwnd) {
            if let Err(err) = st.app.init_webview() {
                st.tray.remove();
                let text: Vec<u16> = err.encode_utf16().chain(Some(0)).collect();
                let _ = MessageBoxW(
                    Some(hwnd),
                    PCWSTR(text.as_ptr()),
                    w!("WallPull 启动失败"),
                    MB_OK | MB_ICONERROR,
                );
                return Err(err);
            }
        }

        let mut msg = MSG::default();
        loop {
            let res = GetMessageW(&mut msg, None, 0, 0).0;
            if res == -1 {
                return Err(format!(
                    "消息循环异常：{}",
                    windows::core::Error::from_thread()
                ));
            }
            if res == 0 {
                break;
            }
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }

        let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut WindowState;
        if !ptr.is_null() {
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            drop(Box::from_raw(ptr));
        }
    }
    Ok(())
}

unsafe extern "system" fn wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_NCCALCSIZE => {
            if wparam.0 != 0 {
                let params = unsafe { &mut *(lparam.0 as *mut NCCALCSIZE_PARAMS) };
                let dpi = unsafe { GetDpiForWindow(hwnd) }.max(96);
                let frame_x = unsafe {
                    GetSystemMetricsForDpi(SM_CXFRAME, dpi)
                        + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi)
                };
                let frame_y = unsafe {
                    GetSystemMetricsForDpi(SM_CYFRAME, dpi)
                        + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi)
                };

                if unsafe { IsZoomed(hwnd).as_bool() } {
                    let hmon = unsafe { MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST) };
                    let mut mi = MONITORINFO {
                        cbSize: size_of::<MONITORINFO>() as u32,
                        ..Default::default()
                    };
                    if unsafe { GetMonitorInfoW(hmon, &mut mi).as_bool() } {
                        let mut work = mi.rcWork;
                        if work.left == mi.rcMonitor.left
                            && work.top == mi.rcMonitor.top
                            && work.right == mi.rcMonitor.right
                            && work.bottom == mi.rcMonitor.bottom
                        {
                            // Keep 1px wakeup seam at the bottom when auto-hide taskbar is enabled.
                            work.bottom -= 1;
                        }
                        params.rgrc[0] = work;
                    }
                } else {
                    params.rgrc[0].left += frame_x;
                    params.rgrc[0].right -= frame_x;
                    params.rgrc[0].bottom -= frame_y;
                }
                return LRESULT(0);
            }
            unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
        }
        WM_NCHITTEST => {
            let res = unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) };
            if res.0 == HTCLIENT as isize && !unsafe { IsZoomed(hwnd).as_bool() } {
                let x = (lparam.0 & 0xFFFF) as i16 as i32;
                let y = ((lparam.0 >> 16) & 0xFFFF) as i16 as i32;
                let mut wr = RECT::default();
                if unsafe { GetWindowRect(hwnd, &mut wr).is_ok() } {
                    let pt = POINT { x, y };
                    let dpi = unsafe { GetDpiForWindow(hwnd) }.max(96);
                    let border = unsafe {
                        GetSystemMetricsForDpi(SM_CXFRAME, dpi)
                            + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi)
                    }
                    .max(6);
                    let on_top = pt.y >= wr.top && pt.y < wr.top + border;
                    let on_bottom = pt.y <= wr.bottom && pt.y > wr.bottom - border;
                    let on_left = pt.x >= wr.left && pt.x < wr.left + border;
                    let on_right = pt.x <= wr.right && pt.x > wr.right - border;
                    if on_top && on_left {
                        return LRESULT(HTTOPLEFT as isize);
                    }
                    if on_top && on_right {
                        return LRESULT(HTTOPRIGHT as isize);
                    }
                    if on_bottom && on_left {
                        return LRESULT(HTBOTTOMLEFT as isize);
                    }
                    if on_bottom && on_right {
                        return LRESULT(HTBOTTOMRIGHT as isize);
                    }
                    if on_top {
                        return LRESULT(HTTOP as isize);
                    }
                    if on_bottom {
                        return LRESULT(HTBOTTOM as isize);
                    }
                    if on_left {
                        return LRESULT(HTLEFT as isize);
                    }
                    if on_right {
                        return LRESULT(HTRIGHT as isize);
                    }
                }
            }
            res
        }
        WM_GETMINMAXINFO => {
            let dpi = unsafe { GetDpiForWindow(hwnd) }.max(96) as i32;
            let mmi = unsafe { &mut *(lparam.0 as *mut MINMAXINFO) };
            mmi.ptMinTrackSize.x = (960 * dpi) / 96;
            mmi.ptMinTrackSize.y = (640 * dpi) / 96;
            LRESULT(0)
        }
        WM_DPICHANGED => {
            let suggested = unsafe { &*(lparam.0 as *const RECT) };
            unsafe {
                let _ = SetWindowPos(
                    hwnd,
                    None,
                    suggested.left,
                    suggested.top,
                    suggested.right - suggested.left,
                    suggested.bottom - suggested.top,
                    SWP_NOZORDER | SWP_NOACTIVATE,
                );
            }
            if let Some(st) = unsafe { get_state_mut(hwnd) } {
                st.app.resize_webview();
            }
            LRESULT(0)
        }
        WM_SIZE => {
            if let Some(st) = unsafe { get_state_mut(hwnd) } {
                st.app.resize_webview();
                let maximized = unsafe { IsZoomed(hwnd).as_bool() };
                st.app.post_json("window.state", json!({ "maximized": maximized }), None);
            }
            LRESULT(0)
        }
        WM_MOVE => {
            if let Some(st) = unsafe { get_state_mut(hwnd) } {
                st.app.notify_parent_moved();
            }
            LRESULT(0)
        }
        WM_SETFOCUS => {
            if let Some(st) = unsafe { get_state_mut(hwnd) } {
                st.app.focus_webview();
            }
            LRESULT(0)
        }
        WM_UI_COMMAND => {
            if let Some(st) = unsafe { get_state_mut(hwnd) } {
                st.app.drain_commands();
            }
            LRESULT(0)
        }
        WM_TRAY_CALLBACK => {
            let evt = (lparam.0 & 0xFFFF) as u32;
            if let Some(st) = unsafe { get_state_mut(hwnd) } {
                if evt == WM_LBUTTONUP || evt == WM_LBUTTONDBLCLK {
                    unsafe { restore_and_activate_window(hwnd) };
                } else if evt == WM_RBUTTONUP || evt == WM_CONTEXTMENU {
                    if let Some(cmd) = st.tray.show_context_menu() {
                        match cmd {
                            CMD_TRAY_SHOW => unsafe { restore_and_activate_window(hwnd) },
                            CMD_TRAY_EXIT => {
                                st.app.notify_ui(UiCommand::ExitExplicit);
                            }
                            _ => {}
                        }
                    }
                }
            }
            LRESULT(0)
        }
        WM_CLOSE => {
            if let Some(st) = unsafe { get_state_mut(hwnd) } {
                if st.app.settings.close_to_tray && !st.app.exiting_explicitly {
                    unsafe {
                        let _ = ShowWindow(hwnd, SW_HIDE);
                    }
                    return LRESULT(0);
                }
                st.app.shutdown_background_tasks();
                st.app.close_studio_internal();
                st.tray.remove();
            }
            unsafe { DestroyWindow(hwnd) }.ok();
            LRESULT(0)
        }
        WM_DESTROY => {
            unsafe { PostQuitMessage(0) };
            LRESULT(0)
        }
        other => {
            let wm_taskbar = WM_TASKBAR_CREATED.load(Ordering::Relaxed);
            let wm_activate = WM_ACTIVATE_EXISTING.load(Ordering::Relaxed);
            if wm_taskbar != 0 && other == wm_taskbar {
                if let Some(st) = unsafe { get_state_mut(hwnd) } {
                    st.tray.recreate();
                }
                return LRESULT(0);
            }
            if wm_activate != 0 && other == wm_activate {
                unsafe { restore_and_activate_window(hwnd) };
                return LRESULT(0);
            }
            unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
        }
    }
}
