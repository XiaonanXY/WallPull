use image::codecs::png::PngEncoder;
use image::{ColorType, ImageEncoder};
use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use windows::Win32::Foundation::{GlobalFree, HANDLE, HGLOBAL, POINT};
use windows::Win32::Graphics::Gdi::{BI_BITFIELDS, BITMAPV5HEADER, LCS_GM_IMAGES};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, OpenClipboard, RegisterClipboardFormatW, SetClipboardData,
};
use windows::Win32::System::Memory::{GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalUnlock};
use windows::Win32::UI::Shell::DROPFILES;
use windows::core::w;

const CF_HDROP_ID: u32 = 15;
const CF_DIBV5_ID: u32 = 17;
const CF_UNICODETEXT_ID: u32 = 13;

pub fn copy_text_to_clipboard(text: &str) -> Result<(), String> {
    if text.is_empty() {
        return Err("复制内容为空。".to_string());
    }
    let wide: Vec<u16> = OsStr::new(text).encode_wide().chain(Some(0)).collect();
    let byte_len = wide.len() * std::mem::size_of::<u16>();
    let bytes = unsafe { std::slice::from_raw_parts(wide.as_ptr() as *const u8, byte_len) };

    unsafe {
        if OpenClipboard(None).is_err() {
            return Err("无法打开系统剪贴板，可能被其他应用短暂占用。".to_string());
        }
        let result = (|| -> Result<(), String> {
            let _ = EmptyClipboard();
            let mem = alloc_hglobal_bytes(bytes)?;
            if SetClipboardData(CF_UNICODETEXT_ID, Some(HANDLE(mem.0))).is_err() {
                let _ = GlobalFree(Some(mem));
                return Err("向系统剪贴板写入文本数据失败。".to_string());
            }
            Ok(())
        })();
        let _ = CloseClipboard();
        result
    }
}

pub fn copy_media_to_clipboard(target_path: &Path, is_image: bool) -> Result<(), String> {
    if !target_path.is_file() {
        return Err(format!("原始壁纸文件已不存在：{}", target_path.display()));
    }
    let full_path =
        std::path::absolute(target_path).unwrap_or_else(|_| target_path.to_path_buf());

    let hdrop = build_cf_hdrop(&full_path)?;
    let image_payload = if is_image {
        prepare_image_clipboard_buffers(&full_path).ok()
    } else {
        None
    };

    unsafe {
        if OpenClipboard(None).is_err() {
            let _ = GlobalFree(Some(hdrop));
            return Err("无法打开 Windows 剪贴板，可能被其他程序占用。".to_string());
        }
        if EmptyClipboard().is_err() {
            let _ = CloseClipboard();
            let _ = GlobalFree(Some(hdrop));
            return Err("清空 Windows 剪贴板失败。".to_string());
        }

        if let Some((png_bytes, dibv5_bytes)) = image_payload {
            let png_fmt = RegisterClipboardFormatW(w!("PNG"));
            if png_fmt != 0 {
                if let Ok(h_png) = alloc_hglobal_bytes(&png_bytes) {
                    if SetClipboardData(png_fmt, Some(HANDLE(h_png.0))).is_err() {
                        let _ = GlobalFree(Some(h_png));
                    }
                }
            }
            if let Ok(h_dib) = alloc_hglobal_bytes(&dibv5_bytes) {
                if SetClipboardData(CF_DIBV5_ID, Some(HANDLE(h_dib.0))).is_err() {
                    let _ = GlobalFree(Some(h_dib));
                }
            }
        }

        if SetClipboardData(CF_HDROP_ID, Some(HANDLE(hdrop.0))).is_err() {
            let _ = GlobalFree(Some(hdrop));
        }

        let _ = CloseClipboard();
    }

    Ok(())
}

fn build_cf_hdrop(path: &Path) -> Result<HGLOBAL, String> {
    let wide: Vec<u16> = OsStr::new(path)
        .encode_wide()
        .chain([0u16, 0u16])
        .collect();
    let header_size = size_of::<DROPFILES>();
    let total_bytes = header_size + wide.len() * 2;
    let hglobal = unsafe { GlobalAlloc(GMEM_MOVEABLE, total_bytes) }
        .map_err(|e| format!("分配剪贴板内存失败：{e}"))?;

    unsafe {
        let ptr = GlobalLock(hglobal) as *mut u8;
        if ptr.is_null() {
            let _ = GlobalFree(Some(hglobal));
            return Err("锁定剪贴板内存失败。".to_string());
        }
        std::ptr::write_bytes(ptr, 0, total_bytes);
        let df = DROPFILES {
            pFiles: header_size as u32,
            pt: POINT { x: 0, y: 0 },
            fNC: false.into(),
            fWide: true.into(),
        };
        std::ptr::write_unaligned(ptr as *mut DROPFILES, df);
        std::ptr::copy_nonoverlapping(wide.as_ptr() as *const u8, ptr.add(header_size), wide.len() * 2);
        let _ = GlobalUnlock(hglobal);
    }

    Ok(hglobal)
}

fn alloc_hglobal_bytes(data: &[u8]) -> Result<HGLOBAL, String> {
    let hglobal = unsafe { GlobalAlloc(GMEM_MOVEABLE, data.len()) }
        .map_err(|e| format!("分配图像剪贴板内存失败：{e}"))?;
    unsafe {
        let ptr = GlobalLock(hglobal) as *mut u8;
        if ptr.is_null() {
            let _ = GlobalFree(Some(hglobal));
            return Err("锁定图像剪贴板内存失败。".to_string());
        }
        std::ptr::copy_nonoverlapping(data.as_ptr(), ptr, data.len());
        let _ = GlobalUnlock(hglobal);
    }
    Ok(hglobal)
}

fn prepare_image_clipboard_buffers(path: &Path) -> Result<(Vec<u8>, Vec<u8>), String> {
    let rgba_img = image::open(path)
        .map_err(|e| format!("无法解码图片到剪贴板：{e}"))?
        .to_rgba8();
    let w = rgba_img.width();
    let h = rgba_img.height();

    let mut png_bytes = Vec::new();
    PngEncoder::new(&mut png_bytes)
        .write_image(rgba_img.as_raw(), w, h, ColorType::Rgba8.into())
        .map_err(|e| e.to_string())?;

    let hdr_size = size_of::<BITMAPV5HEADER>();
    let pixel_bytes = (w as usize) * (h as usize) * 4;
    let mut dib = vec![0u8; hdr_size + pixel_bytes];

    let header = BITMAPV5HEADER {
        bV5Size: hdr_size as u32,
        bV5Width: w as i32,
        bV5Height: h as i32, // Positive => bottom-up BGRA scanlines (universally accepted)
        bV5Planes: 1,
        bV5BitCount: 32,
        bV5Compression: BI_BITFIELDS,
        bV5SizeImage: pixel_bytes as u32,
        bV5XPelsPerMeter: 0,
        bV5YPelsPerMeter: 0,
        bV5ClrUsed: 0,
        bV5ClrImportant: 0,
        bV5RedMask: 0x00FF_0000,
        bV5GreenMask: 0x0000_FF00,
        bV5BlueMask: 0x0000_00FF,
        bV5AlphaMask: 0xFF00_0000,
        bV5CSType: 0x7352_4742, // LCS_sRGB ('sRGB')
        bV5Intent: LCS_GM_IMAGES as u32,
        ..Default::default()
    };

    unsafe {
        std::ptr::write_unaligned(dib.as_mut_ptr() as *mut BITMAPV5HEADER, header);
    }

    let raw = rgba_img.as_raw();
    let row_bytes = (w as usize) * 4;
    for y in 0..(h as usize) {
        let src_y = (h as usize) - 1 - y;
        let src_row = &raw[src_y * row_bytes..(src_y + 1) * row_bytes];
        let dst_off = hdr_size + y * row_bytes;
        for x in 0..(w as usize) {
            let s = x * 4;
            let d = dst_off + x * 4;
            dib[d] = src_row[s + 2];     // B
            dib[d + 1] = src_row[s + 1]; // G
            dib[d + 2] = src_row[s];     // R
            dib[d + 3] = src_row[s + 3]; // A
        }
    }

    Ok((png_bytes, dib))
}
