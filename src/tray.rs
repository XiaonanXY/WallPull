use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use windows::Win32::Foundation::{HWND, HINSTANCE, POINT};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Shell::{
    NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW, Shell_NotifyIconW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreatePopupMenu, DestroyMenu, GetCursorPos, GetSystemMetrics, IMAGE_ICON,
    LR_DEFAULTSIZE, LR_SHARED, LoadImageW, MF_SEPARATOR, MF_STRING, PostMessageW, SM_CXSMICON,
    SM_CYSMICON, SetForegroundWindow, SetMenuDefaultItem, TPM_RETURNCMD, TPM_RIGHTBUTTON,
    TrackPopupMenuEx, WM_APP, WM_NULL,
};
use windows::core::PCWSTR;

pub const WM_TRAY_CALLBACK: u32 = WM_APP + 101;
pub const CMD_TRAY_SHOW: u32 = 1001;
pub const CMD_TRAY_EXIT: u32 = 1004;

pub struct TrayManager {
    hwnd: HWND,
    added: bool,
}

impl TrayManager {
    pub fn new(hwnd: HWND) -> Self {
        let mut mgr = Self { hwnd, added: false };
        mgr.ensure_added();
        mgr
    }

    pub fn ensure_added(&mut self) {
        if self.added || self.hwnd.0.is_null() {
            return;
        }
        let hinst = unsafe { GetModuleHandleW(None) }.unwrap_or_default();
        let cx = unsafe { GetSystemMetrics(SM_CXSMICON) }.max(16);
        let cy = unsafe { GetSystemMetrics(SM_CYSMICON) }.max(16);
        let hicon = unsafe {
            LoadImageW(
                Some(HINSTANCE(hinst.0)),
                PCWSTR(2usize as *const u16),
                IMAGE_ICON,
                cx,
                cy,
                LR_SHARED,
            )
            .or_else(|_| {
                LoadImageW(
                    Some(HINSTANCE(hinst.0)),
                    PCWSTR(1usize as *const u16),
                    IMAGE_ICON,
                    cx,
                    cy,
                    LR_SHARED | LR_DEFAULTSIZE,
                )
            })
            .ok()
            .map(|h| windows::Win32::UI::WindowsAndMessaging::HICON(h.0))
            .unwrap_or_default()
        };

        let mut tip = [0u16; 128];
        let encoded: Vec<u16> = OsStr::new("WallPull · 壁纸库").encode_wide().collect();
        let len = encoded.len().min(tip.len() - 1);
        tip[..len].copy_from_slice(&encoded[..len]);

        let nid = NOTIFYICONDATAW {
            cbSize: size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: self.hwnd,
            uID: 1,
            uFlags: NIF_MESSAGE | NIF_ICON | NIF_TIP,
            uCallbackMessage: WM_TRAY_CALLBACK,
            hIcon: hicon,
            szTip: tip,
            ..Default::default()
        };

        if unsafe { Shell_NotifyIconW(NIM_ADD, &nid).as_bool() } {
            self.added = true;
        }
    }

    pub fn show_context_menu(&self) -> Option<u32> {
        unsafe {
            let hmenu = CreatePopupMenu().ok()?;
            let show_txt: Vec<u16> = OsStr::new("显示 WallPull 主窗口")
                .encode_wide()
                .chain(Some(0))
                .collect();
            let exit_txt: Vec<u16> = OsStr::new("彻底退出 WallPull")
                .encode_wide()
                .chain(Some(0))
                .collect();

            let _ = AppendMenuW(hmenu, MF_STRING, CMD_TRAY_SHOW as usize, PCWSTR(show_txt.as_ptr()));
            let _ = AppendMenuW(hmenu, MF_SEPARATOR, 0, PCWSTR::null());
            let _ = AppendMenuW(hmenu, MF_STRING, CMD_TRAY_EXIT as usize, PCWSTR(exit_txt.as_ptr()));
            let _ = SetMenuDefaultItem(hmenu, 0, 1);

            let _ = SetForegroundWindow(self.hwnd);
            let mut pt = POINT::default();
            let _ = GetCursorPos(&mut pt);
            let cmd = TrackPopupMenuEx(
                hmenu,
                (TPM_RETURNCMD | TPM_RIGHTBUTTON).0,
                pt.x,
                pt.y,
                self.hwnd,
                None,
            );
            let _ = PostMessageW(Some(self.hwnd), WM_NULL, Default::default(), Default::default());
            let _ = DestroyMenu(hmenu);

            if cmd.as_bool() {
                Some(cmd.0 as u32)
            } else {
                None
            }
        }
    }

    pub fn recreate(&mut self) {
        self.added = false;
        self.ensure_added();
    }

    pub fn remove(&mut self) {
        if self.added && !self.hwnd.0.is_null() {
            let nid = NOTIFYICONDATAW {
                cbSize: size_of::<NOTIFYICONDATAW>() as u32,
                hWnd: self.hwnd,
                uID: 1,
                ..Default::default()
            };
            unsafe {
                let _ = Shell_NotifyIconW(NIM_DELETE, &nid);
            }
            self.added = false;
        }
    }
}

impl Drop for TrayManager {
    fn drop(&mut self) {
        self.remove();
    }
}
