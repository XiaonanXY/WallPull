use crate::clipboard::copy_media_to_clipboard;
use crate::settings::cache_root;
use image::{DynamicImage, ImageDecoder, ImageFormat, ImageReader};
use std::fs;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_PNG_BYTES: usize = 64 * 1024 * 1024;
const PNG_MAGIC: [u8; 8] = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];

pub fn decode_base64_png_data_url(input: &str) -> Result<Vec<u8>, String> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err("图片数据为空。".to_string());
    }

    let b64_part = if let Some(rest) = trimmed.strip_prefix("data:") {
        let Some((header, data)) = rest.split_once(',') else {
            return Err("无效的 Data URL 格式。".to_string());
        };
        if !header.to_ascii_lowercase().contains("base64") {
            return Err("仅支持 Base64 编码的 PNG 图片数据。".to_string());
        }
        data
    } else {
        trimmed
    };

    let bytes = decode_base64_str(b64_part)?;
    if bytes.len() > MAX_PNG_BYTES {
        return Err("PNG 图像体积超过 64 MB 上限。".to_string());
    }
    if bytes.len() < PNG_MAGIC.len() || bytes[..8] != PNG_MAGIC {
        return Err("数据并非有效的 PNG 图像格式。".to_string());
    }
    Ok(bytes)
}

fn decode_base64_str(raw: &str) -> Result<Vec<u8>, String> {
    let mut cleaned: Vec<u8> = Vec::with_capacity(raw.len());
    for &b in raw.as_bytes() {
        if !b.is_ascii_whitespace() {
            cleaned.push(b);
        }
    }
    if cleaned.is_empty() || cleaned.len() % 4 != 0 {
        return Err("Base64 图片数据长度不合法。".to_string());
    }

    let mut out = Vec::with_capacity((cleaned.len() / 4) * 3);
    for (chunk_idx, chunk) in cleaned.chunks_exact(4).enumerate() {
        let is_last = (chunk_idx + 1) * 4 == cleaned.len();
        let a = b64_val(chunk[0])?;
        let b = b64_val(chunk[1])?;
        let c_pad = chunk[2] == b'=';
        let d_pad = chunk[3] == b'=';
        if (c_pad || d_pad) && !is_last {
            return Err("Base64 填充字符位置不合法。".to_string());
        }
        if c_pad && !d_pad {
            return Err("Base64 填充字符格式错误。".to_string());
        }

        let c = if c_pad { 0 } else { b64_val(chunk[2])? };
        let d = if d_pad { 0 } else { b64_val(chunk[3])? };

        out.push((a << 2) | (b >> 4));
        if !c_pad {
            out.push((b << 4) | (c >> 2));
        }
        if !d_pad {
            out.push((c << 6) | d);
        }
    }
    Ok(out)
}

#[inline]
fn b64_val(b: u8) -> Result<u8, String> {
    match b {
        b'A'..=b'Z' => Ok(b - b'A'),
        b'a'..=b'z' => Ok(b - b'a' + 26),
        b'0'..=b'9' => Ok(b - b'0' + 52),
        b'+' => Ok(62),
        b'/' => Ok(63),
        _ => Err("Base64 图片数据包含非法字符。".to_string()),
    }
}

pub fn sanitize_png_stem(raw: &str) -> String {
    let cleaned: String = raw
        .trim()
        .chars()
        .map(|ch| match ch {
            '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*' => '_',
            c if c.is_control() => '_',
            c => c,
        })
        .collect();
    let trimmed = cleaned.trim_matches(|c: char| c == ' ' || c == '.');
    let truncated: String = trimmed.chars().take(64).collect();
    if truncated.is_empty() {
        "wallpull-capture".to_string()
    } else {
        truncated
    }
}

pub fn unique_png_path(dir: &Path, stem: &str) -> PathBuf {
    let safe = sanitize_png_stem(stem);
    let first = dir.join(format!("{safe}.png"));
    if !first.exists() {
        return first;
    }
    for idx in 1..=9999 {
        let candidate = dir.join(format!("{safe}_{idx}.png"));
        if !candidate.exists() {
            return candidate;
        }
    }
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    dir.join(format!("{safe}_{ts}.png"))
}

pub fn save_png_bytes_to_dir(png_bytes: &[u8], dir: &Path, stem: &str) -> Result<PathBuf, String> {
    fs::create_dir_all(dir).map_err(|e| format!("创建导出目录失败：{e}"))?;
    let dest = unique_png_path(dir, stem);
    fs::write(&dest, png_bytes).map_err(|e| format!("写入 PNG 文件失败：{e}"))?;
    Ok(dest)
}

pub fn copy_png_bytes_to_clipboard(png_bytes: &[u8], stem: &str) -> Result<PathBuf, String> {
    let staging = cache_root().join("frame-captures");
    fs::create_dir_all(&staging).map_err(|e| format!("创建截帧暂存目录失败：{e}"))?;
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let safe = sanitize_png_stem(stem);
    let file_path = unique_png_path(&staging, &format!("{safe}_{ts}"));
    fs::write(&file_path, png_bytes).map_err(|e| format!("写入暂存 PNG 失败：{e}"))?;
    copy_media_to_clipboard(&file_path, true)?;
    Ok(file_path)
}

pub fn compute_pixel_crop_rect(img_w: u32, img_h: u32, x: f64, y: f64, w: f64, h: f64) -> (u32, u32, u32, u32) {
    let max_w = img_w.max(1);
    let max_h = img_h.max(1);
    let nx = x.clamp(0.0, 1.0);
    let ny = y.clamp(0.0, 1.0);
    let nw = w.clamp(0.0, 1.0);
    let nh = h.clamp(0.0, 1.0);

    let px = (nx * max_w as f64).round().clamp(0.0, max_w.saturating_sub(1) as f64) as u32;
    let py = (ny * max_h as f64).round().clamp(0.0, max_h.saturating_sub(1) as f64) as u32;
    let pw = (nw * max_w as f64).round().max(1.0).min((max_w - px) as f64) as u32;
    let ph = (nh * max_h as f64).round().max(1.0).min((max_h - py) as f64) as u32;
    (px, py, pw, ph)
}

fn crop_dynamic_image_to_png(
    img: &DynamicImage,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
) -> Result<(Vec<u8>, u32, u32), String> {
    let img_w = img.width();
    let img_h = img.height();
    if img_w == 0 || img_h == 0 {
        return Err("原图尺寸无效，无法裁切。".to_string());
    }
    let (px, py, pw, ph) = compute_pixel_crop_rect(img_w, img_h, x, y, w, h);
    let cropped = img.crop_imm(px, py, pw, ph);
    let mut buf = Vec::new();
    cropped
        .write_to(&mut Cursor::new(&mut buf), ImageFormat::Png)
        .map_err(|e| format!("编码裁切 PNG 失败：{e}"))?;
    Ok((buf, pw, ph))
}

pub fn crop_image_file_normalized(
    path: &Path,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
) -> Result<(Vec<u8>, u32, u32), String> {
    let reader = ImageReader::open(path)
        .map_err(|e| format!("打开原图文件失败：{e}"))?
        .with_guessed_format()
        .map_err(|e| format!("识别原图格式失败：{e}"))?;
    let mut decoder = reader
        .into_decoder()
        .map_err(|e| format!("解析原图解码器失败：{e}"))?;
    let orientation = decoder
        .orientation()
        .unwrap_or(image::metadata::Orientation::NoTransforms);
    let mut img = DynamicImage::from_decoder(decoder)
        .map_err(|e| format!("解码原图失败：{e}"))?;
    img.apply_orientation(orientation);
    crop_dynamic_image_to_png(&img, x, y, w, h)
}

pub fn crop_png_bytes_normalized(
    png_bytes: &[u8],
    x: f64,
    y: f64,
    w: f64,
    h: f64,
) -> Result<(Vec<u8>, u32, u32), String> {
    let img = image::load_from_memory(png_bytes)
        .map_err(|e| format!("解析 PNG 字节流失败：{e}"))?;
    crop_dynamic_image_to_png(&img, x, y, w, h)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encode_b64(bytes: &[u8]) -> String {
        const TABLE: &[u8; 64] =
            b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::new();
        for chunk in bytes.chunks(3) {
            let b0 = chunk[0] as u32;
            let b1 = if chunk.len() > 1 { chunk[1] as u32 } else { 0 };
            let b2 = if chunk.len() > 2 { chunk[2] as u32 } else { 0 };
            let n = (b0 << 16) | (b1 << 8) | b2;
            out.push(TABLE[((n >> 18) & 63) as usize] as char);
            out.push(TABLE[((n >> 12) & 63) as usize] as char);
            out.push(if chunk.len() > 1 {
                TABLE[((n >> 6) & 63) as usize] as char
            } else {
                '='
            });
            out.push(if chunk.len() > 2 {
                TABLE[(n & 63) as usize] as char
            } else {
                '='
            });
        }
        out
    }

    #[test]
    fn decodes_valid_png_data_url() {
        let mut raw = PNG_MAGIC.to_vec();
        raw.extend_from_slice(&[1, 2, 3, 4, 5]);
        let url = format!("data:image/png;base64,{}", encode_b64(&raw));
        let decoded = decode_base64_png_data_url(&url).unwrap();
        assert_eq!(decoded, raw);
    }

    #[test]
    fn rejects_non_png_magic_bytes() {
        let bad = encode_b64(b"NOT_A_PNG_FILE");
        let url = format!("data:image/png;base64,{bad}");
        assert!(decode_base64_png_data_url(&url).is_err());
    }

    #[test]
    fn sanitizes_stem_and_deduplicates_path() {
        assert_eq!(sanitize_png_stem("a<b>:c/d\\e|?*."), "a_b__c_d_e___");
        assert_eq!(sanitize_png_stem("   ... "), "wallpull-capture");

        let dir = std::env::temp_dir().join(format!("wallpull_png_unique_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let p1 = save_png_bytes_to_dir(&PNG_MAGIC, &dir, "demo").unwrap();
        let p2 = save_png_bytes_to_dir(&PNG_MAGIC, &dir, "demo").unwrap();
        assert_ne!(p1, p2);
        assert!(p2.file_name().unwrap().to_string_lossy().contains("demo_1.png"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn crop_preserves_full_native_resolution_and_subrect() {
        assert_eq!(compute_pixel_crop_rect(3840, 2160, 0.0, 0.0, 1.0, 1.0), (0, 0, 3840, 2160));
        assert_eq!(compute_pixel_crop_rect(3840, 2160, 0.25, 0.5, 0.5, 0.25), (960, 1080, 1920, 540));

        let rgba = image::RgbaImage::from_pixel(120, 80, image::Rgba([40, 120, 220, 255]));
        let dyn_img = DynamicImage::ImageRgba8(rgba);
        let mut src_png = Vec::new();
        dyn_img.write_to(&mut Cursor::new(&mut src_png), ImageFormat::Png).unwrap();

        let (full_bytes, fw, fh) = crop_png_bytes_normalized(&src_png, 0.0, 0.0, 1.0, 1.0).unwrap();
        assert_eq!((fw, fh), (120, 80));
        let decoded_full = image::load_from_memory(&full_bytes).unwrap();
        assert_eq!((decoded_full.width(), decoded_full.height()), (120, 80));

        let tmp = std::env::temp_dir().join(format!("wallpull_crop_src_{}.png", std::process::id()));
        fs::write(&tmp, &src_png).unwrap();
        let (sub_bytes, sw, sh) = crop_image_file_normalized(&tmp, 0.25, 0.25, 0.5, 0.5).unwrap();
        assert_eq!((sw, sh), (60, 40));
        let decoded_sub = image::load_from_memory(&sub_bytes).unwrap();
        assert_eq!((decoded_sub.width(), decoded_sub.height()), (60, 40));
        let _ = fs::remove_file(&tmp);
    }
}
