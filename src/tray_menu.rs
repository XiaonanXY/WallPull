use crate::tray::{
    CMD_TRAY_EXIT, CMD_TRAY_OPEN_EXPORT, CMD_TRAY_RANDOM_ALL, CMD_TRAY_RANDOM_FAV, CMD_TRAY_SHOW,
};
use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Once, OnceLock};
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{
    DWM_WINDOW_CORNER_PREFERENCE, DWMWA_BORDER_COLOR, DWMWA_USE_IMMERSIVE_DARK_MODE,
    DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND, DwmSetWindowAttribute,
};
use windows::Win32::Graphics::Gdi::{
    AddFontMemResourceEx, BeginPaint, BitBlt, CLEARTYPE_QUALITY, CreateCompatibleBitmap,
    CreateCompatibleDC, CreateFontW, CreatePen, CreateSolidBrush, DT_LEFT, DT_SINGLELINE,
    DT_VCENTER, DeleteDC, DeleteObject, DrawTextW, Ellipse, EndPaint, FONT_CHARSET,
    FONT_CLIP_PRECISION, FONT_OUTPUT_PRECISION, FillRect, GetMonitorInfoW, InvalidateRect,
    MONITOR_DEFAULTTONEAREST, MONITORINFO, MonitorFromPoint, PAINTSTRUCT, PS_NULL, PS_SOLID,
    RoundRect, SRCCOPY, SelectObject, SetBkMode, SetTextColor, TRANSPARENT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::WM_MOUSELEAVE;
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, GetDpiForWindow, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    TRACKMOUSEEVENT, TME_LEAVE, TrackMouseEvent, VK_DOWN, VK_ESCAPE, VK_RETURN, VK_UP,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CS_DROPSHADOW, CS_HREDRAW, CS_VREDRAW, CreateWindowExW, DefWindowProcW, DestroyWindow,
    DispatchMessageW, GetClientRect, GetCursorPos, GetWindowLongPtrW, GWLP_USERDATA, IDC_ARROW,
    LoadCursorW, PeekMessageW, PM_REMOVE, PostMessageW, PostQuitMessage, RegisterClassExW,
    SW_SHOW, SetForegroundWindow, SetWindowLongPtrW, ShowWindow, TranslateMessage, WA_INACTIVE,
    WM_ACTIVATE, WM_CANCELMODE, WM_ERASEBKGND, WM_KEYDOWN, WM_LBUTTONUP, WM_MOUSEMOVE, WM_NULL,
    WM_PAINT, WM_QUIT, WM_RBUTTONUP, WNDCLASSEXW, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
    WaitMessage,
};
use windows::core::w;

static CLASS_INIT: Once = Once::new();
static TRAY_FONT_LOADED: OnceLock<bool> = OnceLock::new();
static MENU_OPEN_GUARD: AtomicBool = AtomicBool::new(false);
static TRAY_FONT_BYTES: &[u8] = include_bytes!("../Assets/tray_misans.ttf");
const MENU_CLASS_NAME: windows::core::PCWSTR = w!("WallPullModernTrayMenu");

fn ensure_tray_font_loaded() -> bool {
    *TRAY_FONT_LOADED.get_or_init(|| {
        let mut count: u32 = 0;
        let handle = unsafe {
            AddFontMemResourceEx(
                TRAY_FONT_BYTES.as_ptr().cast(),
                TRAY_FONT_BYTES.len() as u32,
                None,
                &mut count,
            )
        };
        !handle.is_invalid() && count > 0
    })
}

#[derive(Clone)]
enum MenuEntryKind {
    Action {
        cmd: u32,
        label: &'static str,
        enabled: bool,
        primary_dot: bool,
        danger: bool,
    },
    Separator,
}

struct MenuRowRect {
    kind: MenuEntryKind,
    rect: RECT,
}

struct PopupState {
    rows: Vec<MenuRowRect>,
    hovered: Option<usize>,
    selected_cmd: Option<u32>,
    done: bool,
    ready: bool,
    tracking_mouse: bool,
    is_dark: bool,
    accent_rgb: (u8, u8, u8),
    scale: f32,
}

pub fn parse_hex_rgb(hex: &str) -> (u8, u8, u8) {
    let trimmed = hex.trim().trim_start_matches('#');
    if trimmed.len() == 6 {
        if let (Ok(r), Ok(g), Ok(b)) = (
            u8::from_str_radix(&trimmed[0..2], 16),
            u8::from_str_radix(&trimmed[2..4], 16),
            u8::from_str_radix(&trimmed[4..6], 16),
        ) {
            return (r, g, b);
        }
    }
    (124, 58, 237)
}

#[inline]
const fn rgb_to_colorref(r: u8, g: u8, b: u8) -> COLORREF {
    COLORREF(((b as u32) << 16) | ((g as u32) << 8) | (r as u32))
}

#[inline]
fn blend_rgb(bg: (u8, u8, u8), fg: (u8, u8, u8), alpha: f32) -> (u8, u8, u8) {
    let a = alpha.clamp(0.0, 1.0);
    let r = (bg.0 as f32 * (1.0 - a) + fg.0 as f32 * a).round() as u8;
    let g = (bg.1 as f32 * (1.0 - a) + fg.1 as f32 * a).round() as u8;
    let b = (bg.2 as f32 * (1.0 - a) + fg.2 as f32 * a).round() as u8;
    (r, g, b)
}

#[inline]
fn scale_px(base: i32, scale: f32) -> i32 {
    ((base as f32) * scale).round().max(1.0) as i32
}

fn ensure_class_registered() {
    CLASS_INIT.call_once(|| unsafe {
        let hinst = GetModuleHandleW(None).unwrap_or_default();
        let wc = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            style: CS_HREDRAW | CS_VREDRAW | CS_DROPSHADOW,
            lpfnWndProc: Some(tray_menu_wnd_proc),
            hInstance: hinst.into(),
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            lpszClassName: MENU_CLASS_NAME,
            ..Default::default()
        };
        let _ = RegisterClassExW(&wc);
    });
}

fn build_entries(has_favorites: bool, has_wallpapers: bool) -> Vec<MenuEntryKind> {
    vec![
        MenuEntryKind::Action {
            cmd: CMD_TRAY_SHOW,
            label: "显示 WallPull 主窗口",
            enabled: true,
            primary_dot: true,
            danger: false,
        },
        MenuEntryKind::Separator,
        MenuEntryKind::Action {
            cmd: CMD_TRAY_RANDOM_FAV,
            label: "随机设为桌面（收藏壁纸）",
            enabled: has_favorites,
            primary_dot: false,
            danger: false,
        },
        MenuEntryKind::Action {
            cmd: CMD_TRAY_RANDOM_ALL,
            label: "随机设为桌面（全库抽取）",
            enabled: has_wallpapers,
            primary_dot: false,
            danger: false,
        },
        MenuEntryKind::Action {
            cmd: CMD_TRAY_OPEN_EXPORT,
            label: "打开默认导出目录",
            enabled: true,
            primary_dot: false,
            danger: false,
        },
        MenuEntryKind::Separator,
        MenuEntryKind::Action {
            cmd: CMD_TRAY_EXIT,
            label: "彻底退出 WallPull",
            enabled: true,
            primary_dot: false,
            danger: true,
        },
    ]
}

pub fn show_tray_popup_menu(
    owner_hwnd: HWND,
    is_dark: bool,
    spark_color_hex: &str,
    has_favorites: bool,
    has_wallpapers: bool,
) -> Option<u32> {
    if MENU_OPEN_GUARD.swap(true, Ordering::AcqRel) {
        return None;
    }
    struct ResetGuard;
    impl Drop for ResetGuard {
        fn drop(&mut self) {
            MENU_OPEN_GUARD.store(false, Ordering::Release);
        }
    }
    let _guard = ResetGuard;

    ensure_class_registered();

    unsafe {
        let mut cursor = POINT::default();
        let _ = GetCursorPos(&mut cursor);

        let monitor_at_cursor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
        let mut monitor_dpi_x = 0u32;
        let mut monitor_dpi_y = 0u32;
        let initial_dpi = if GetDpiForMonitor(
            monitor_at_cursor,
            MDT_EFFECTIVE_DPI,
            &mut monitor_dpi_x,
            &mut monitor_dpi_y,
        )
        .is_ok()
            && monitor_dpi_x >= 96
        {
            monitor_dpi_x
        } else if !owner_hwnd.0.is_null() {
            GetDpiForWindow(owner_hwnd)
        } else {
            96
        };
        let scale = (initial_dpi.max(96) as f32) / 96.0;

        let pad = scale_px(8, scale);
        let menu_w = scale_px(268, scale);
        let row_h = scale_px(38, scale);
        let sep_h = scale_px(11, scale);

        let entries = build_entries(has_favorites, has_wallpapers);
        let mut y = pad;
        let mut rows = Vec::with_capacity(entries.len());
        for kind in entries {
            let h = match kind {
                MenuEntryKind::Action { .. } => row_h,
                MenuEntryKind::Separator => sep_h,
            };
            rows.push(MenuRowRect {
                kind,
                rect: RECT {
                    left: pad,
                    top: y,
                    right: menu_w - pad,
                    bottom: y + h,
                },
            });
            y += h;
        }
        let menu_h = y + pad;

        let monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
        let mut mi = MONITORINFO {
            cbSize: size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        let (x, pos_y) = if GetMonitorInfoW(monitor, &mut mi).as_bool() {
            let work = mi.rcWork;
            let margin = scale_px(8, scale);
            let mut px = if cursor.x + menu_w <= work.right - margin {
                cursor.x
            } else {
                cursor.x - menu_w
            };
            let mut py = if cursor.y - menu_h >= work.top + margin {
                cursor.y - menu_h
            } else {
                cursor.y
            };
            px = px.clamp(work.left + margin, (work.right - menu_w - margin).max(work.left + margin));
            py = py.clamp(work.top + margin, (work.bottom - menu_h - margin).max(work.top + margin));
            (px, py)
        } else {
            (cursor.x, cursor.y - menu_h)
        };

        let state = Box::new(PopupState {
            rows,
            hovered: None,
            selected_cmd: None,
            done: false,
            ready: false,
            tracking_mouse: false,
            is_dark,
            accent_rgb: parse_hex_rgb(spark_color_hex),
            scale,
        });

        let hinst = GetModuleHandleW(None).unwrap_or_default();
        let Ok(popup_hwnd) = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
            MENU_CLASS_NAME,
            w!(""),
            WS_POPUP,
            x,
            pos_y,
            menu_w,
            menu_h,
            Some(owner_hwnd),
            None,
            Some(hinst.into()),
            None,
        ) else {
            return None;
        };

        let state_ptr: *mut PopupState = Box::into_raw(state);
        SetWindowLongPtrW(popup_hwnd, GWLP_USERDATA, state_ptr as isize);

        let dark_val: i32 = if is_dark { 1 } else { 0 };
        let _ = DwmSetWindowAttribute(
            popup_hwnd,
            DWMWA_USE_IMMERSIVE_DARK_MODE,
            (&dark_val as *const i32).cast(),
            size_of::<i32>() as u32,
        );
        let corner: DWM_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUND;
        let _ = DwmSetWindowAttribute(
            popup_hwnd,
            DWMWA_WINDOW_CORNER_PREFERENCE,
            (&corner as *const DWM_WINDOW_CORNER_PREFERENCE).cast(),
            size_of::<DWM_WINDOW_CORNER_PREFERENCE>() as u32,
        );
        let border_color: COLORREF = if is_dark {
            rgb_to_colorref(58, 58, 68)
        } else {
            rgb_to_colorref(228, 228, 234)
        };
        let _ = DwmSetWindowAttribute(
            popup_hwnd,
            DWMWA_BORDER_COLOR,
            (&border_color as *const COLORREF).cast(),
            size_of::<COLORREF>() as u32,
        );

        let _ = ShowWindow(popup_hwnd, SW_SHOW);
        let _ = SetForegroundWindow(popup_hwnd);
        (*state_ptr).ready = true;

        let mut msg = windows::Win32::UI::WindowsAndMessaging::MSG::default();
        while !(*state_ptr).done {
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                if msg.message == WM_QUIT {
                    PostQuitMessage(msg.wParam.0 as i32);
                    (*state_ptr).done = true;
                    break;
                }
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
                if (*state_ptr).done {
                    break;
                }
            }
            if !(*state_ptr).done {
                let _ = WaitMessage();
            }
        }

        SetWindowLongPtrW(popup_hwnd, GWLP_USERDATA, 0);
        let _ = DestroyWindow(popup_hwnd);
        let result = Box::from_raw(state_ptr).selected_cmd;
        if !owner_hwnd.0.is_null() {
            let _ = PostMessageW(Some(owner_hwnd), WM_NULL, WPARAM(0), LPARAM(0));
        }
        result
    }
}

fn hit_test_row(state: &PopupState, x: i32, y: i32) -> Option<usize> {
    for (idx, row) in state.rows.iter().enumerate() {
        if let MenuEntryKind::Action { enabled: true, .. } = row.kind {
            if x >= row.rect.left
                && x < row.rect.right
                && y >= row.rect.top
                && y < row.rect.bottom
            {
                return Some(idx);
            }
        }
    }
    None
}

fn step_focus_row(state: &PopupState, dir: isize) -> Option<usize> {
    let enabled_indices: Vec<usize> = state
        .rows
        .iter()
        .enumerate()
        .filter_map(|(idx, r)| match r.kind {
            MenuEntryKind::Action { enabled: true, .. } => Some(idx),
            _ => None,
        })
        .collect();
    if enabled_indices.is_empty() {
        return None;
    }
    let Some(cur) = state.hovered else {
        return Some(if dir >= 0 {
            enabled_indices[0]
        } else {
            *enabled_indices.last().unwrap()
        });
    };
    let pos = enabled_indices.iter().position(|&i| i == cur).unwrap_or(0) as isize;
    let next_pos = (pos + dir).rem_euclid(enabled_indices.len() as isize) as usize;
    Some(enabled_indices[next_pos])
}

unsafe fn paint_menu(hwnd: HWND, state: &PopupState) {
    let mut ps = PAINTSTRUCT::default();
    let hdc = unsafe { BeginPaint(hwnd, &mut ps) };
    if hdc.0.is_null() {
        return;
    }

    let mut client = RECT::default();
    let _ = unsafe { GetClientRect(hwnd, &mut client) };
    let w = (client.right - client.left).max(1);
    let h = (client.bottom - client.top).max(1);

    unsafe {
        let mem_dc = CreateCompatibleDC(Some(hdc));
        let bmp = CreateCompatibleBitmap(hdc, w, h);
        let old_bmp = SelectObject(mem_dc, bmp.into());

        let bg_rgb = if state.is_dark { (32, 32, 38) } else { (255, 255, 255) };
        let fg_rgb = if state.is_dark { (244, 244, 248) } else { (24, 24, 28) };
        let muted_rgb = if state.is_dark { (110, 110, 124) } else { (156, 156, 168) };
        let sep_rgb = if state.is_dark { (52, 52, 62) } else { (232, 232, 238) };
        let danger_rgb = if state.is_dark { (248, 113, 113) } else { (220, 38, 38) };
        let hover_rgb = blend_rgb(bg_rgb, state.accent_rgb, if state.is_dark { 0.22 } else { 0.10 });
        let danger_hover_rgb = blend_rgb(bg_rgb, (239, 68, 68), if state.is_dark { 0.20 } else { 0.10 });

        let bg_brush = CreateSolidBrush(rgb_to_colorref(bg_rgb.0, bg_rgb.1, bg_rgb.2));
        let _ = FillRect(mem_dc, &client, bg_brush);
        let _ = DeleteObject(bg_brush.into());

        let _ = SetBkMode(mem_dc, TRANSPARENT);
        let font_family = if ensure_tray_font_loaded() {
            "WallPullMiSans"
        } else {
            "Microsoft YaHei UI"
        };
        let font_name: Vec<u16> = OsStr::new(font_family)
            .encode_wide()
            .chain(Some(0))
            .collect();
        let font_h = -scale_px(16, state.scale);
        let menu_font = CreateFontW(
            font_h,
            0,
            0,
            0,
            500,
            0,
            0,
            0,
            FONT_CHARSET(1),
            FONT_OUTPUT_PRECISION(0),
            FONT_CLIP_PRECISION(0),
            CLEARTYPE_QUALITY,
            0,
            windows::core::PCWSTR(font_name.as_ptr()),
        );

        let pill_radius = scale_px(10, state.scale) * 2;
        let dot_size = scale_px(7, state.scale);
        let text_inset = scale_px(14, state.scale);
        let dot_gap = scale_px(10, state.scale);
        let sep_margin = scale_px(12, state.scale);
        let null_pen = CreatePen(PS_NULL, 0, COLORREF(0));

        let old_f = SelectObject(mem_dc, menu_font.into());
        for (idx, row) in state.rows.iter().enumerate() {
            match row.kind {
                MenuEntryKind::Separator => {
                    let mid_y = (row.rect.top + row.rect.bottom) / 2;
                    let sep_pen = CreatePen(
                        PS_SOLID,
                        1,
                        rgb_to_colorref(sep_rgb.0, sep_rgb.1, sep_rgb.2),
                    );
                    let old_p = SelectObject(mem_dc, sep_pen.into());
                    let _ = windows::Win32::Graphics::Gdi::MoveToEx(
                        mem_dc,
                        row.rect.left + sep_margin,
                        mid_y,
                        None,
                    );
                    let _ = windows::Win32::Graphics::Gdi::LineTo(
                        mem_dc,
                        row.rect.right - sep_margin,
                        mid_y,
                    );
                    SelectObject(mem_dc, old_p);
                    let _ = DeleteObject(sep_pen.into());
                }
                MenuEntryKind::Action {
                    label,
                    enabled,
                    primary_dot,
                    danger,
                    ..
                } => {
                    let is_hovered = state.hovered == Some(idx) && enabled;
                    if is_hovered {
                        let fill = if danger { danger_hover_rgb } else { hover_rgb };
                        let hover_brush = CreateSolidBrush(rgb_to_colorref(fill.0, fill.1, fill.2));
                        let old_p = SelectObject(mem_dc, null_pen.into());
                        let old_b = SelectObject(mem_dc, hover_brush.into());
                        let _ = RoundRect(
                            mem_dc,
                            row.rect.left,
                            row.rect.top,
                            row.rect.right,
                            row.rect.bottom,
                            pill_radius,
                            pill_radius,
                        );
                        SelectObject(mem_dc, old_b);
                        SelectObject(mem_dc, old_p);
                        let _ = DeleteObject(hover_brush.into());
                    }

                    let text_rgb = if !enabled {
                        muted_rgb
                    } else if danger && is_hovered {
                        danger_rgb
                    } else {
                        fg_rgb
                    };
                    let _ = SetTextColor(mem_dc, rgb_to_colorref(text_rgb.0, text_rgb.1, text_rgb.2));

                    let mut text_left = row.rect.left + text_inset;
                    if primary_dot {
                        let dot_brush = CreateSolidBrush(rgb_to_colorref(
                            state.accent_rgb.0,
                            state.accent_rgb.1,
                            state.accent_rgb.2,
                        ));
                        let old_p = SelectObject(mem_dc, null_pen.into());
                        let old_b = SelectObject(mem_dc, dot_brush.into());
                        let cy = (row.rect.top + row.rect.bottom) / 2;
                        let r0 = dot_size / 2;
                        let cx = text_left + r0;
                        let _ = Ellipse(mem_dc, cx - r0, cy - r0, cx + r0 + (dot_size & 1), cy + r0 + (dot_size & 1));
                        SelectObject(mem_dc, old_b);
                        SelectObject(mem_dc, old_p);
                        let _ = DeleteObject(dot_brush.into());
                        text_left += dot_size + dot_gap;
                    }

                    let mut tr = RECT {
                        left: text_left,
                        top: row.rect.top,
                        right: row.rect.right - text_inset,
                        bottom: row.rect.bottom,
                    };
                    let mut wide: Vec<u16> = OsStr::new(label).encode_wide().collect();
                    let _ = DrawTextW(
                        mem_dc,
                        &mut wide,
                        &mut tr,
                        DT_LEFT | DT_VCENTER | DT_SINGLELINE,
                    );
                }
            }
        }
        SelectObject(mem_dc, old_f);

        let _ = DeleteObject(null_pen.into());
        let _ = DeleteObject(menu_font.into());

        let _ = BitBlt(hdc, 0, 0, w, h, Some(mem_dc), 0, 0, SRCCOPY);
        SelectObject(mem_dc, old_bmp);
        let _ = DeleteObject(bmp.into());
        let _ = DeleteDC(mem_dc);
        let _ = EndPaint(hwnd, &ps);
    }
}

unsafe extern "system" fn tray_menu_wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    let ptr = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) } as *mut PopupState;
    if ptr.is_null() {
        return unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) };
    }
    let state = unsafe { &mut *ptr };

    match msg {
        WM_ERASEBKGND => LRESULT(1),
        WM_PAINT => {
            unsafe { paint_menu(hwnd, state) };
            LRESULT(0)
        }
        WM_MOUSEMOVE => {
            if !state.tracking_mouse {
                state.tracking_mouse = true;
                let mut tme = TRACKMOUSEEVENT {
                    cbSize: size_of::<TRACKMOUSEEVENT>() as u32,
                    dwFlags: TME_LEAVE,
                    hwndTrack: hwnd,
                    dwHoverTime: 0,
                };
                let _ = unsafe { TrackMouseEvent(&mut tme) };
            }
            let x = (lparam.0 & 0xFFFF) as i16 as i32;
            let y = ((lparam.0 >> 16) & 0xFFFF) as i16 as i32;
            let hit = hit_test_row(state, x, y);
            if hit != state.hovered {
                state.hovered = hit;
                let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
            }
            LRESULT(0)
        }
        WM_MOUSELEAVE => {
            state.tracking_mouse = false;
            if state.hovered.is_some() {
                state.hovered = None;
                let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
            }
            LRESULT(0)
        }
        WM_LBUTTONUP => {
            let x = (lparam.0 & 0xFFFF) as i16 as i32;
            let y = ((lparam.0 >> 16) & 0xFFFF) as i16 as i32;
            if let Some(idx) = hit_test_row(state, x, y) {
                if let MenuEntryKind::Action { cmd, enabled: true, .. } = state.rows[idx].kind {
                    state.selected_cmd = Some(cmd);
                }
            }
            state.done = true;
            LRESULT(0)
        }
        WM_KEYDOWN => {
            let vk = wparam.0 as u16;
            if vk == VK_ESCAPE.0 {
                state.selected_cmd = None;
                state.done = true;
            } else if vk == VK_DOWN.0 {
                state.hovered = step_focus_row(state, 1);
                let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
            } else if vk == VK_UP.0 {
                state.hovered = step_focus_row(state, -1);
                let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
            } else if vk == VK_RETURN.0 {
                if let Some(idx) = state.hovered {
                    if let MenuEntryKind::Action { cmd, enabled: true, .. } = state.rows[idx].kind {
                        state.selected_cmd = Some(cmd);
                        state.done = true;
                    }
                }
            }
            LRESULT(0)
        }
        WM_ACTIVATE => {
            if state.ready && (wparam.0 & 0xFFFF) as u32 == WA_INACTIVE {
                state.done = true;
            }
            LRESULT(0)
        }
        WM_CANCELMODE | WM_RBUTTONUP => {
            state.done = true;
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_hex_and_converts_bgr_colorref() {
        assert_eq!(parse_hex_rgb("#2563eb"), (37, 99, 235));
        assert_eq!(parse_hex_rgb("invalid"), (124, 58, 237));
        assert_eq!(rgb_to_colorref(37, 99, 235).0, 0x00EB6325);
        assert_eq!(blend_rgb((255, 255, 255), (0, 0, 0), 0.10), (230, 230, 230));
    }
}
