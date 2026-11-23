use crate::models::{MediaInfo, clean_path_str};
use crate::process_runner::{os_args, run_output, run_status};
use crate::settings::cache_root;
use image::codecs::ico::{IcoEncoder, IcoFrame};
use image::codecs::jpeg::JpegEncoder;
use image::codecs::png::PngEncoder;
use image::imageops::FilterType;
use image::{ColorType, DynamicImage, ExtendedColorType, ImageDecoder, ImageEncoder, ImageReader};
use std::ffi::OsString;
use std::fs::{self, File};
use std::io::BufWriter;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::time::Duration;

const THUMB_SIZE: u32 = 720;

pub fn find_executable(exe_name: &str) -> Option<PathBuf> {
    if let Ok(cur_exe) = std::env::current_exe() {
        if let Some(dir) = cur_exe.parent() {
            let bundled = dir.join("Tools").join(exe_name);
            if bundled.is_file() {
                return Some(bundled);
            }
            let same_dir = dir.join(exe_name);
            if same_dir.is_file() {
                return Some(same_dir);
            }
        }
    }

    let local_tools = crate::settings::local_app_data_root()
        .join("Tools")
        .join(exe_name);
    if local_tools.is_file() {
        return Some(local_tools);
    }

    if let Some(path_var) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path_var) {
            let candidate = dir.join(exe_name);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

pub fn detect_media_type(path: &Path) -> Option<&'static str> {
    if !path.is_file() {
        return None;
    }
    let mut header = [0u8; 16];
    let read = {
        let mut f = File::open(path).ok()?;
        f.read(&mut header).ok()?
    };
    let bytes = &header[..read];
    if is_image_signature(bytes) {
        return Some("image");
    }
    if is_video_signature(bytes) {
        return Some("video");
    }
    detect_by_extension(path)
}

pub fn is_recognized_media_path(path: &Path) -> bool {
    detect_by_extension(path).is_some()
}

fn detect_by_extension(path: &Path) -> Option<&'static str> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())?;
    match ext.as_str() {
        "jpg" | "jpeg" | "png" | "webp" | "gif" | "bmp" | "tif" | "tiff" => Some("image"),
        "mp4" | "m4v" | "mov" | "webm" | "mkv" | "avi" | "wmv" | "flv" | "mpeg" | "mpg" => {
            Some("video")
        }
        _ => None,
    }
}

fn is_image_signature(b: &[u8]) -> bool {
    if b.len() >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF {
        return true;
    }
    if b.len() >= 8 && &b[..8] == b"\x89PNG\r\n\x1A\n" {
        return true;
    }
    if b.len() >= 6 && (&b[..6] == b"GIF87a" || &b[..6] == b"GIF89a") {
        return true;
    }
    if b.len() >= 12 && &b[..4] == b"RIFF" && &b[8..12] == b"WEBP" {
        return true;
    }
    b.len() >= 2 && b[0] == b'B' && b[1] == b'M'
}

fn is_video_signature(b: &[u8]) -> bool {
    if b.len() >= 12 && &b[4..8] == b"ftyp" {
        return true;
    }
    if b.len() >= 4 && b[..4] == [0x1A, 0x45, 0xDF, 0xA3] {
        return true;
    }
    b.len() >= 12 && &b[..4] == b"RIFF" && &b[8..12] == b"AVI "
}

pub fn read_image_dimensions(path: &Path) -> (i32, i32) {
    if let Ok((w, h)) = image::image_dimensions(path) {
        if w > 0 && h > 0 {
            return (w as i32, h as i32);
        }
    }
    (0, 0)
}

pub fn probe_or_fallback(path: &Path, ffprobe_path: Option<&Path>) -> MediaInfo {
    probe_or_fallback_cancellable(path, ffprobe_path, None)
}

pub fn probe_or_fallback_cancellable(
    path: &Path,
    ffprobe_path: Option<&Path>,
    cancel: Option<&AtomicBool>,
) -> MediaInfo {
    let file_size = fs::metadata(path).map(|m| m.len() as i64).unwrap_or(0);
    if detect_media_type(path) == Some("image") {
        let (width, height) = read_image_dimensions(path);
        return MediaInfo {
            width,
            height,
            duration_seconds: None,
            file_size,
        };
    }

    if let Some((w, h, dur)) = probe_mp4_header(path) {
        if w > 0 && h > 0 {
            return MediaInfo {
                width: w,
                height: h,
                duration_seconds: dur,
                file_size,
            };
        }
    }

    if let Some(ffprobe) = ffprobe_path {
        if let Some(info) = probe_with_ffprobe(ffprobe, path, file_size, cancel) {
            return info;
        }
    }

    MediaInfo {
        width: 0,
        height: 0,
        duration_seconds: None,
        file_size,
    }
}

fn probe_with_ffprobe(
    ffprobe: &Path,
    path: &Path,
    file_size: i64,
    cancel: Option<&AtomicBool>,
) -> Option<MediaInfo> {
    let mut args = os_args([
        "-v",
        "quiet",
        "-print_format",
        "json",
        "-show_streams",
        "-show_format",
    ]);
    args.push(path.as_os_str().to_os_string());
    let output = run_output(ffprobe, &args, None, Duration::from_secs(10), cancel).ok()?;
    if !output.status.success() {
        return None;
    }
    let v: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;
    let mut width = 0i32;
    let mut height = 0i32;
    let mut duration: Option<f64> = None;

    if let Some(streams) = v.get("streams").and_then(|s| s.as_array()) {
        for s in streams {
            if s.get("codec_type").and_then(|t| t.as_str()) == Some("video") {
                width = s.get("width").and_then(|n| n.as_i64()).unwrap_or(0) as i32;
                height = s.get("height").and_then(|n| n.as_i64()).unwrap_or(0) as i32;
                if let Some(d_str) = s.get("duration").and_then(|d| d.as_str()) {
                    duration = d_str.parse::<f64>().ok();
                }
                break;
            }
        }
    }
    if duration.is_none() {
        if let Some(d_str) = v
            .get("format")
            .and_then(|f| f.get("duration"))
            .and_then(|d| d.as_str())
        {
            duration = d_str.parse::<f64>().ok();
        }
    }
    Some(MediaInfo {
        width,
        height,
        duration_seconds: duration.filter(|&d| d > 0.0),
        file_size,
    })
}

/// Pure-Rust ISO BMFF / MP4 metadata parser (extracts pixel dimensions and duration without ffprobe).
fn probe_mp4_header(path: &Path) -> Option<(i32, i32, Option<f64>)> {
    let mut file = File::open(path).ok()?;
    let file_len = file.metadata().ok()?.len();
    parse_mp4_boxes(&mut file, 0, file_len, 0)
}

fn parse_mp4_boxes(
    file: &mut File,
    start: u64,
    end: u64,
    depth: u32,
) -> Option<(i32, i32, Option<f64>)> {
    use std::io::{Seek, SeekFrom};
    if depth > 4 || start >= end {
        return None;
    }
    let mut pos = start;
    let mut width = 0i32;
    let mut height = 0i32;
    let mut duration: Option<f64> = None;

    while pos + 8 <= end {
        file.seek(SeekFrom::Start(pos)).ok()?;
        let mut hdr = [0u8; 8];
        if file.read_exact(&mut hdr).is_err() {
            break;
        }
        let size32 = u32::from_be_bytes(hdr[0..4].try_into().ok()?);
        let box_type = &hdr[4..8];
        let (box_size, header_len) = if size32 == 1 {
            if pos + 16 > end {
                break;
            }
            let mut ext = [0u8; 8];
            file.read_exact(&mut ext).ok()?;
            (u64::from_be_bytes(ext), 16u64)
        } else if size32 == 0 {
            (end - pos, 8u64)
        } else {
            (size32 as u64, 8u64)
        };
        if box_size < header_len || pos + box_size > end {
            break;
        }
        let body_start = pos + header_len;
        let body_end = pos + box_size;

        if box_type == b"moov" {
            let res = parse_mp4_boxes(file, body_start, body_end, depth + 1);
            if let Some((w, h, d)) = res {
                if w > 0 && h > 0 {
                    width = w;
                    height = h;
                }
                if d.is_some() {
                    duration = d;
                }
                if width > 0 && duration.is_some() {
                    return Some((width, height, duration));
                }
            }
        } else if box_type == b"trak" {
            if let Some((w, h, d)) = parse_mp4_boxes(file, body_start, body_end, depth + 1) {
                if w > width || (w > 0 && h > 0 && width == 0) {
                    width = w;
                    height = h;
                }
                if duration.is_none() {
                    duration = d;
                }
            }
        } else if box_type == b"mvhd" && (body_end - body_start) >= 24 {
            let mut buf = vec![0u8; (body_end - body_start).min(64) as usize];
            file.seek(SeekFrom::Start(body_start)).ok()?;
            if file.read_exact(&mut buf).is_ok() {
                let version = buf[0];
                if version == 0 && buf.len() >= 20 {
                    let timescale = u32::from_be_bytes(buf[12..16].try_into().ok()?);
                    let dur_units = u32::from_be_bytes(buf[16..20].try_into().ok()?);
                    if timescale > 0 && dur_units > 0 {
                        duration = Some(dur_units as f64 / timescale as f64);
                    }
                } else if version == 1 && buf.len() >= 32 {
                    let timescale = u32::from_be_bytes(buf[20..24].try_into().ok()?);
                    let dur_units = u64::from_be_bytes(buf[24..32].try_into().ok()?);
                    if timescale > 0 && dur_units > 0 {
                        duration = Some(dur_units as f64 / timescale as f64);
                    }
                }
            }
        } else if box_type == b"tkhd" && (body_end - body_start) >= 84 {
            let mut buf = vec![0u8; (body_end - body_start).min(104) as usize];
            file.seek(SeekFrom::Start(body_start)).ok()?;
            if file.read_exact(&mut buf).is_ok() {
                let version = buf[0];
                let off = if version == 1 { 88 } else { 76 };
                if buf.len() >= off + 8 {
                    let w_fixed = u32::from_be_bytes(buf[off..off + 4].try_into().ok()?);
                    let h_fixed = u32::from_be_bytes(buf[off + 4..off + 8].try_into().ok()?);
                    let w_px = (w_fixed >> 16) as i32;
                    let h_px = (h_fixed >> 16) as i32;
                    if w_px > 0 && h_px > 0 {
                        width = w_px;
                        height = h_px;
                    }
                }
            }
        }

        pos += box_size;
    }

    if width > 0 || duration.is_some() {
        Some((width, height, duration))
    } else {
        None
    }
}

pub fn sanitize_cache_key(key: &str) -> String {
    key.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '-' | '_') {
                c
            } else {
                '_'
            }
        })
        .collect()
}

fn make_unique_temp_path(dir: &Path, ext: &str) -> PathBuf {
    dir.join(format!(
        ".tmp-{}-{}.{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0),
        ext
    ))
}

fn is_cache_fresh(src_meta: &fs::Metadata, dest: &Path) -> bool {
    let Ok(dst_meta) = fs::metadata(dest) else {
        return false;
    };
    if dst_meta.len() == 0 {
        return false;
    }
    match (src_meta.modified(), dst_meta.modified()) {
        (Ok(sm), Ok(dm)) => dm >= sm,
        _ => true,
    }
}

fn finalize_temp_cache_file(
    tmp: &Path,
    dest: &Path,
    src_mtime: Option<std::time::SystemTime>,
) -> Option<String> {
    if !fs::metadata(tmp).map(|m| m.len() > 0).unwrap_or(false) {
        let _ = fs::remove_file(tmp);
        return None;
    }
    let _ = fs::rename(tmp, dest).or_else(|_| {
        let _ = fs::remove_file(dest);
        fs::rename(tmp, dest)
    });
    if let Some(mt) = src_mtime {
        if let Ok(sf) = File::open(dest) {
            let _ = sf.set_modified(mt);
        }
    }
    if dest.is_file() {
        Some(clean_path_str(dest))
    } else {
        let _ = fs::remove_file(tmp);
        None
    }
}

fn encode_rust_cover_thumbnail(source_path: &Path, tmp: &Path) -> Option<()> {
    let reader = ImageReader::open(source_path).ok()?.with_guessed_format().ok()?;
    let mut decoder = reader.into_decoder().ok()?;
    let orientation = decoder
        .orientation()
        .unwrap_or(image::metadata::Orientation::NoTransforms);
    let mut img = DynamicImage::from_decoder(decoder).ok()?;
    img.apply_orientation(orientation);

    let orig_w = img.width();
    let orig_h = img.height();
    if orig_w == 0 || orig_h == 0 {
        return None;
    }

    let side = orig_w.min(orig_h);
    let crop_x = (orig_w - side) / 2;
    let crop_y = (orig_h - side) / 2;
    let square = img.crop_imm(crop_x, crop_y, side, side);
    let rgba = square
        .resize_exact(THUMB_SIZE, THUMB_SIZE, FilterType::Lanczos3)
        .to_rgba8();

    // Composite alpha onto dark charcoal (#18181B) matching WIC NativeMediaInspector
    let mut rgb = Vec::with_capacity((THUMB_SIZE * THUMB_SIZE * 3) as usize);
    for px in rgba.pixels() {
        let [r, g, b, a] = px.0;
        if a == 255 {
            rgb.extend_from_slice(&[r, g, b]);
        } else {
            let a16 = a as u16;
            let inv = 255 - a16;
            rgb.push(((r as u16 * a16 + 24 * inv + 127) / 255) as u8);
            rgb.push(((g as u16 * a16 + 24 * inv + 127) / 255) as u8);
            rgb.push(((b as u16 * a16 + 27 * inv + 127) / 255) as u8);
        }
    }

    let out_file = File::create(tmp).ok()?;
    let writer = BufWriter::new(out_file);
    let mut encoder = JpegEncoder::new_with_quality(writer, 92);
    encoder
        .encode(&rgb, THUMB_SIZE, THUMB_SIZE, ExtendedColorType::Rgb8)
        .ok()
}

pub fn create_image_thumbnail_cancellable(
    source_path: &Path,
    cache_key: &str,
    ffmpeg_path: Option<&Path>,
    cancel: Option<&AtomicBool>,
) -> Option<String> {
    let thumb_dir = cache_root().join("video-previews");
    fs::create_dir_all(&thumb_dir).ok()?;
    let safe_key = sanitize_cache_key(cache_key);
    let dest = thumb_dir.join(format!("{safe_key}-img-thumb-v2.jpg"));

    let src_meta = fs::metadata(source_path).ok()?;
    if is_cache_fresh(&src_meta, &dest) {
        return Some(clean_path_str(&dest));
    }

    let src_mtime = src_meta.modified().ok();
    let tmp = make_unique_temp_path(&thumb_dir, "jpg");
    if encode_rust_cover_thumbnail(source_path, &tmp).is_some() {
        if let Some(done) = finalize_temp_cache_file(&tmp, &dest, src_mtime) {
            return Some(done);
        }
    }
    let _ = fs::remove_file(&tmp);

    let ffmpeg = ffmpeg_path?;
    let tmp_ff = make_unique_temp_path(&thumb_dir, "jpg");
    let mut args = vec![OsString::from("-y"), OsString::from("-i"), source_path.as_os_str().to_os_string()];
    args.extend(os_args([
        "-frames:v",
        "1",
        "-vf",
        "scale=720:720:force_original_aspect_ratio=increase:flags=lanczos,crop=720:720",
        "-q:v",
        "2",
    ]));
    args.push(tmp_ff.as_os_str().to_os_string());
    let ok = run_status(ffmpeg, &args, None, Duration::from_secs(20), cancel).unwrap_or(false);
    if ok {
        if let Some(done) = finalize_temp_cache_file(&tmp_ff, &dest, src_mtime) {
            return Some(done);
        }
    }
    let _ = fs::remove_file(&tmp_ff);
    None
}

fn run_ffmpeg_preview_frame(
    ffmpeg: &Path,
    source_path: &Path,
    seek: &str,
    use_hw_decode: bool,
    tmp: &Path,
    cancel: Option<&AtomicBool>,
) -> bool {
    let mut args = vec![OsString::from("-y")];
    if use_hw_decode {
        args.extend(os_args(["-hwaccel", "auto"]));
    }
    args.push(OsString::from("-ss"));
    args.push(OsString::from(seek));
    args.push(OsString::from("-i"));
    args.push(source_path.as_os_str().to_os_string());
    args.extend(os_args([
        "-frames:v",
        "1",
        "-vf",
        "scale=1024:1024:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:1024",
        "-q:v",
        "2",
    ]));
    args.push(tmp.as_os_str().to_os_string());
    let ok = run_status(ffmpeg, &args, None, Duration::from_secs(25), cancel).unwrap_or(false);
    if !ok {
        let _ = fs::remove_file(tmp);
        return false;
    }
    fs::metadata(tmp).map(|m| m.len() > 0).unwrap_or(false)
}

pub fn try_create_video_preview_cancellable(
    source_path: &Path,
    cache_key: &str,
    ffmpeg_path: Option<&Path>,
    use_hw_decode: bool,
    cancel: Option<&AtomicBool>,
) -> Option<String> {
    let preview_dir = cache_root().join("video-previews");
    let safe_key = sanitize_cache_key(cache_key);
    let dest = preview_dir.join(format!("{safe_key}-square-v3.jpg"));
    let src_meta = fs::metadata(source_path).ok()?;
    if is_cache_fresh(&src_meta, &dest) {
        return Some(clean_path_str(&dest));
    }

    let ffmpeg = ffmpeg_path?;
    fs::create_dir_all(&preview_dir).ok()?;
    let tmp = make_unique_temp_path(&preview_dir, "jpg");
    let ok = ["0", "1"].iter().any(|seek| {
        if cancel.map(|c| c.load(std::sync::atomic::Ordering::SeqCst)).unwrap_or(false) {
            return false;
        }
        if use_hw_decode && run_ffmpeg_preview_frame(ffmpeg, source_path, seek, true, &tmp, cancel)
        {
            return true;
        }
        run_ffmpeg_preview_frame(ffmpeg, source_path, seek, false, &tmp, cancel)
    });
    if ok {
        finalize_temp_cache_file(&tmp, &dest, src_meta.modified().ok())
    } else {
        let _ = fs::remove_file(&tmp);
        None
    }
}

fn run_ffmpeg_preview_clip(
    ffmpeg: &Path,
    source_path: &Path,
    use_hw_decode: bool,
    tmp: &Path,
    cancel: Option<&AtomicBool>,
) -> bool {
    let mut args = vec![OsString::from("-y")];
    if use_hw_decode {
        args.extend(os_args(["-hwaccel", "auto"]));
    }
    args.push(OsString::from("-i"));
    args.push(source_path.as_os_str().to_os_string());
    args.extend(os_args([
        "-t",
        "12",
        "-an",
        "-vf",
        "scale=480:480:force_original_aspect_ratio=increase:flags=lanczos,crop=480:480,fps=30",
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "23",
        "-pix_fmt",
        "yuv420p",
        "-movflags",
        "+faststart",
    ]));
    args.push(tmp.as_os_str().to_os_string());
    let ok = run_status(ffmpeg, &args, None, Duration::from_secs(45), cancel).unwrap_or(false);
    if !ok {
        let _ = fs::remove_file(tmp);
        return false;
    }
    fs::metadata(tmp).map(|m| m.len() > 0).unwrap_or(false)
}

pub fn try_create_video_preview_clip_cancellable(
    source_path: &Path,
    cache_key: &str,
    ffmpeg_path: Option<&Path>,
    use_hw_decode: bool,
    cancel: Option<&AtomicBool>,
) -> Option<String> {
    let clip_dir = cache_root().join("video-clips");
    let safe_key = sanitize_cache_key(cache_key);
    let dest = clip_dir.join(format!("{safe_key}-480p-v1.mp4"));
    let src_meta = fs::metadata(source_path).ok()?;
    if is_cache_fresh(&src_meta, &dest) {
        return Some(clean_path_str(&dest));
    }

    let ffmpeg = ffmpeg_path?;
    fs::create_dir_all(&clip_dir).ok()?;
    let tmp = make_unique_temp_path(&clip_dir, "mp4");
    let ok = (use_hw_decode
        && run_ffmpeg_preview_clip(ffmpeg, source_path, true, &tmp, cancel))
        || run_ffmpeg_preview_clip(ffmpeg, source_path, false, &tmp, cancel);
    if ok {
        finalize_temp_cache_file(&tmp, &dest, src_meta.modified().ok())
    } else {
        let _ = fs::remove_file(&tmp);
        None
    }
}

pub fn pack_multi_size_ico_pure_rust(source_path: &Path, dest_ico: &Path) -> Result<(), String> {
    let img = image::open(source_path).map_err(|e| format!("无法打开图标源图片：{e}"))?;
    let sizes = [256u32, 128, 64, 48, 32, 16];
    let mut frames = Vec::with_capacity(sizes.len());

    for size in sizes {
        let thumb = img
            .resize(size, size, FilterType::Lanczos3)
            .to_rgba8();
        let mut canvas = image::RgbaImage::new(size, size);
        let ox = (size - thumb.width()) / 2;
        let oy = (size - thumb.height()) / 2;
        image::imageops::overlay(&mut canvas, &thumb, ox as i64, oy as i64);

        let mut png_bytes = Vec::new();
        PngEncoder::new(&mut png_bytes)
            .write_image(canvas.as_raw(), size, size, ColorType::Rgba8.into())
            .map_err(|e| format!("编码 ICO 帧失败：{e}"))?;
        let ico_frame = IcoFrame::with_encoded(png_bytes, size, size, ExtendedColorType::Rgba8)
            .map_err(|e| format!("打包 ICO 帧失败：{e}"))?;
        frames.push(ico_frame);
    }

    if let Some(parent) = dest_ico.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("无法创建导出目录：{e}"))?;
    }
    let out_file = File::create(dest_ico).map_err(|e| format!("无法写入 .ico 文件：{e}"))?;
    IcoEncoder::new(BufWriter::new(out_file))
        .encode_images(&frames)
        .map_err(|e| format!("写出 .ico 失败：{e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pure_rust_multi_size_ico_writes_valid_header() {
        let dir = std::env::temp_dir().join(format!("wallpull_ico_{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let src = dir.join("in.png");
        let dst = dir.join("out.ico");
        let img = image::RgbaImage::from_pixel(32, 32, image::Rgba([124, 58, 237, 255]));
        img.save(&src).unwrap();

        pack_multi_size_ico_pure_rust(&src, &dst).unwrap();
        let ico_bytes = fs::read(&dst).unwrap();
        assert_eq!(&ico_bytes[0..6], &[0, 0, 1, 0, 6, 0]);
        let _ = fs::remove_dir_all(&dir);
    }
}
