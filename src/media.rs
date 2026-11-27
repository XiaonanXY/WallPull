use crate::models::{MediaInfo, clean_path_str};
use crate::process_runner::{os_args, run_output, run_status};
use crate::settings::cache_root;
use image::codecs::ico::{IcoEncoder, IcoFrame};
use image::codecs::jpeg::JpegEncoder;
use image::codecs::png::PngEncoder;
use image::imageops::FilterType;
use image::{ColorType, DynamicImage, ExtendedColorType, ImageDecoder, ImageEncoder, ImageReader};
use serde::Serialize;
use std::ffi::OsString;
use std::fs::{self, File};
use std::io::BufWriter;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Condvar, Mutex, OnceLock, RwLock};
use std::time::Duration;

const MAX_THUMB_EDGE: u32 = 800;
static TMP_MEDIA_SEQ: AtomicU64 = AtomicU64::new(1);
static CUSTOM_FFMPEG_OVERRIDE: OnceLock<RwLock<Option<PathBuf>>> = OnceLock::new();

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FfmpegStatus {
    pub available: bool,
    pub ffmpeg_path: Option<String>,
    pub ffprobe_available: bool,
    pub ffprobe_path: Option<String>,
    pub source: String,
    pub tools_dir: String,
    pub custom_path: Option<String>,
}

fn custom_override_lock() -> &'static RwLock<Option<PathBuf>> {
    CUSTOM_FFMPEG_OVERRIDE.get_or_init(|| RwLock::new(None))
}

pub fn set_custom_ffmpeg_override(path: Option<&str>) {
    let next = path
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(PathBuf::from);
    if let Ok(mut guard) = custom_override_lock().write() {
        *guard = next;
    }
}

fn resolve_custom_executable(exe_name: &str, custom: &Path) -> Option<PathBuf> {
    if !custom.is_file() {
        return None;
    }
    if exe_name.eq_ignore_ascii_case("ffmpeg.exe") {
        let is_ffmpeg = custom
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.eq_ignore_ascii_case("ffmpeg.exe"));
        if is_ffmpeg {
            return Some(custom.to_path_buf());
        }
        return None;
    }
    if exe_name.eq_ignore_ascii_case("ffprobe.exe") {
        if let Some(parent) = custom.parent() {
            let sibling = parent.join("ffprobe.exe");
            if sibling.is_file() {
                return Some(sibling);
            }
        }
    }
    None
}

fn locate_executable_with_source(
    exe_name: &str,
    custom_override: Option<&Path>,
) -> Option<(PathBuf, &'static str)> {
    if let Some(custom) = custom_override {
        if let Some(found) = resolve_custom_executable(exe_name, custom) {
            return Some((found, "custom"));
        }
    }

    if let Ok(cur_exe) = std::env::current_exe() {
        if let Some(dir) = cur_exe.parent() {
            let bundled = dir.join("Tools").join(exe_name);
            if bundled.is_file() {
                return Some((bundled, "bundled"));
            }
            let same_dir = dir.join(exe_name);
            if same_dir.is_file() {
                return Some((same_dir, "bundled"));
            }
        }
    }

    let local_tools = crate::settings::local_app_data_root()
        .join("Tools")
        .join(exe_name);
    if local_tools.is_file() {
        return Some((local_tools, "local"));
    }

    if let Some(path_var) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path_var) {
            let candidate = dir.join(exe_name);
            if candidate.is_file() {
                return Some((candidate, "path"));
            }
        }
    }
    None
}

pub fn find_executable(exe_name: &str) -> Option<PathBuf> {
    let custom = custom_override_lock()
        .read()
        .ok()
        .and_then(|g| g.clone());
    locate_executable_with_source(exe_name, custom.as_deref()).map(|(p, _)| p)
}

pub fn detect_ffmpeg_status(custom_path: Option<&str>) -> FfmpegStatus {
    let clean_custom = custom_path
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToString::to_string);
    let custom_buf = clean_custom.as_deref().map(PathBuf::from);
    let ffmpeg_found = locate_executable_with_source("ffmpeg.exe", custom_buf.as_deref());
    let ffprobe_found = locate_executable_with_source("ffprobe.exe", custom_buf.as_deref());
    let tools_dir = clean_path_str(&crate::settings::preferred_tools_dir());
    let (available, ffmpeg_path, source) = match ffmpeg_found {
        Some((p, src)) => (true, Some(clean_path_str(&p)), src.to_string()),
        None => (false, None, "missing".to_string()),
    };
    FfmpegStatus {
        available,
        ffmpeg_path,
        ffprobe_available: ffprobe_found.is_some(),
        ffprobe_path: ffprobe_found.map(|(p, _)| clean_path_str(&p)),
        source,
        tools_dir,
        custom_path: clean_custom,
    }
}

pub fn detect_media_type(path: &Path) -> Option<&'static str> {
    if !path.is_file() {
        return None;
    }
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .unwrap_or_default();
    if matches!(
        ext.as_str(),
        "mp3" | "wav" | "ogg" | "flac" | "m4a" | "m4b" | "aac" | "opus" | "wma"
    ) {
        return None;
    }
    if matches!(ext.as_str(), "heic" | "heif" | "avif") {
        return Some("image");
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
        "jpg" | "jpeg" | "png" | "webp" | "gif" | "bmp" | "tif" | "tiff" | "heic" | "heif"
        | "avif" => Some("image"),
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
    if b.len() >= 12 && &b[4..8] == b"ftyp" {
        let brand = &b[8..12];
        if matches!(
            brand,
            b"avif" | b"avis" | b"heic" | b"heix" | b"hevc" | b"hevx" | b"heim" | b"heis"
                | b"mif1" | b"msf1"
        ) {
            return true;
        }
    }
    b.len() >= 2 && b[0] == b'B' && b[1] == b'M'
}

fn is_video_signature(b: &[u8]) -> bool {
    if b.len() >= 12 && &b[4..8] == b"ftyp" {
        let brand = &b[8..12];
        if matches!(
            brand,
            b"M4A " | b"M4B " | b"M4P " | b"f4a " | b"avif" | b"avis" | b"heic" | b"heix"
                | b"hevc" | b"hevx" | b"heim" | b"heis" | b"mif1" | b"msf1"
        ) {
            return false;
        }
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

    const MAX_BOXES: usize = 8192;
    let mut box_count = 0usize;
    while pos + 8 <= end && box_count < MAX_BOXES {
        box_count += 1;
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
        let Some(body_end) = pos.checked_add(box_size) else {
            break;
        };
        if box_size < header_len || body_end <= pos || body_end > end {
            break;
        }
        let body_start = pos + header_len;

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

        pos = body_end;
    }

    if width > 0 || duration.is_some() {
        Some((width, height, duration))
    } else {
        None
    }
}

fn scan_mp4_audio_handlers(
    file: &mut File,
    start: u64,
    end: u64,
    depth: u32,
    saw_video: &mut bool,
    saw_audio: &mut bool,
) -> Option<()> {
    use std::io::{Seek, SeekFrom};
    if depth > 5 || start >= end || *saw_audio {
        return Some(());
    }
    let mut pos = start;
    const MAX_BOXES: usize = 8192;
    let mut box_count = 0usize;
    while pos + 8 <= end && box_count < MAX_BOXES && !*saw_audio {
        box_count += 1;
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
        let Some(body_end) = pos.checked_add(box_size) else {
            break;
        };
        if box_size < header_len || body_end <= pos || body_end > end {
            break;
        }
        let body_start = pos + header_len;
        if matches!(box_type, b"moov" | b"trak" | b"mdia") {
            let _ = scan_mp4_audio_handlers(
                file,
                body_start,
                body_end,
                depth + 1,
                saw_video,
                saw_audio,
            );
        } else if box_type == b"hdlr" && (body_end - body_start) >= 12 {
            let mut hdlr = [0u8; 12];
            file.seek(SeekFrom::Start(body_start)).ok()?;
            if file.read_exact(&mut hdlr).is_ok() {
                let handler_type = &hdlr[8..12];
                if handler_type == b"soun" {
                    *saw_audio = true;
                    return Some(());
                } else if handler_type == b"vide" {
                    *saw_video = true;
                }
            }
        }
        pos = body_end;
    }
    Some(())
}

fn probe_mp4_audio_box(path: &Path) -> Option<bool> {
    let mut file = File::open(path).ok()?;
    let file_len = file.metadata().ok()?.len();
    let mut saw_video = false;
    let mut saw_audio = false;
    scan_mp4_audio_handlers(&mut file, 0, file_len, 0, &mut saw_video, &mut saw_audio)?;
    if saw_audio {
        Some(true)
    } else if saw_video {
        Some(false)
    } else {
        None
    }
}

pub fn video_has_audio_stream_cancellable(
    path: &Path,
    ffprobe_path: Option<&Path>,
    cancel: Option<&AtomicBool>,
) -> bool {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default();
    if matches!(ext.as_str(), "mp4" | "m4v" | "mov") {
        if let Some(has_audio) = probe_mp4_audio_box(path) {
            return has_audio;
        }
    }
    if cancel.map(|c| c.load(Ordering::SeqCst)).unwrap_or(false) {
        return false;
    }
    let owned_probe = ffprobe_path
        .map(PathBuf::from)
        .or_else(|| find_executable("ffprobe.exe"));
    let Some(ffprobe) = owned_probe else {
        return false;
    };
    let mut args = os_args([
        "-v",
        "quiet",
        "-select_streams",
        "a:0",
        "-show_entries",
        "stream=codec_type",
        "-of",
        "csv=p=0",
    ]);
    args.push(path.as_os_str().to_os_string());
    let Ok(out) = run_output(&ffprobe, &args, None, Duration::from_secs(6), cancel) else {
        return false;
    };
    if !out.status.success() {
        return false;
    }
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .any(|line| line.trim().eq_ignore_ascii_case("audio"))
}

pub fn video_has_audio_stream(path: &Path, ffprobe_path: Option<&Path>) -> bool {
    video_has_audio_stream_cancellable(path, ffprobe_path, None)
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
    let seq = TMP_MEDIA_SEQ.fetch_add(1, Ordering::Relaxed);
    dir.join(format!(
        ".tmp-{}-{}-{}.{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0),
        seq,
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
    let renamed = fs::rename(tmp, dest)
        .or_else(|_| {
            let _ = fs::remove_file(dest);
            fs::rename(tmp, dest)
        })
        .is_ok();
    if renamed {
        if let Some(mt) = src_mtime {
            if let Ok(sf) = File::open(dest) {
                let _ = sf.set_modified(mt);
            }
        }
    } else {
        let _ = fs::remove_file(tmp);
    }
    if dest.is_file() {
        Some(clean_path_str(dest))
    } else {
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

    let resized = if orig_w > MAX_THUMB_EDGE * 2 || orig_h > MAX_THUMB_EDGE * 2 {
        let mid = img.resize(MAX_THUMB_EDGE * 2, MAX_THUMB_EDGE * 2, FilterType::Triangle);
        mid.resize(MAX_THUMB_EDGE, MAX_THUMB_EDGE, FilterType::CatmullRom)
    } else if orig_w > MAX_THUMB_EDGE || orig_h > MAX_THUMB_EDGE {
        img.resize(MAX_THUMB_EDGE, MAX_THUMB_EDGE, FilterType::CatmullRom)
    } else {
        img
    };
    let out_w = resized.width().max(1);
    let out_h = resized.height().max(1);
    let rgba = resized.to_rgba8();

    // Composite alpha onto dark charcoal (#18181B) matching WIC NativeMediaInspector
    let mut rgb = Vec::with_capacity((out_w as usize) * (out_h as usize) * 3);
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
    let mut encoder = JpegEncoder::new_with_quality(writer, 86);
    encoder
        .encode(&rgb, out_w, out_h, ExtendedColorType::Rgb8)
        .ok()
}

fn clip_encode_sema() -> &'static (Mutex<usize>, Condvar) {
    static SEMA: OnceLock<(Mutex<usize>, Condvar)> = OnceLock::new();
    SEMA.get_or_init(|| (Mutex::new(0), Condvar::new()))
}

pub fn existing_image_thumbnail_path(source_path: &Path, cache_key: &str) -> Option<String> {
    let dest = cache_root()
        .join("video-previews")
        .join(format!("{}-img-thumb-v3.jpg", sanitize_cache_key(cache_key)));
    let src_meta = fs::metadata(source_path).ok()?;
    if is_cache_fresh(&src_meta, &dest) {
        Some(clean_path_str(&dest))
    } else {
        None
    }
}

pub fn existing_video_preview_path(source_path: &Path, cache_key: &str) -> Option<String> {
    let dest = cache_root()
        .join("video-previews")
        .join(format!("{}-aspect-v4.jpg", sanitize_cache_key(cache_key)));
    let src_meta = fs::metadata(source_path).ok()?;
    if is_cache_fresh(&src_meta, &dest) {
        Some(clean_path_str(&dest))
    } else {
        None
    }
}

pub fn existing_video_preview_clip_path(source_path: &Path, cache_key: &str) -> Option<String> {
    let dest = cache_root()
        .join("video-clips")
        .join(format!("{}-aspect-v2.mp4", sanitize_cache_key(cache_key)));
    let src_meta = fs::metadata(source_path).ok()?;
    if is_cache_fresh(&src_meta, &dest) {
        Some(clean_path_str(&dest))
    } else {
        None
    }
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
    let dest = thumb_dir.join(format!("{safe_key}-img-thumb-v3.jpg"));

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
        "scale='min(800,iw)':'min(800,ih)':force_original_aspect_ratio=decrease:flags=bicubic",
        "-q:v",
        "4",
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
        "scale='min(800,iw)':'min(800,ih)':force_original_aspect_ratio=decrease:flags=bicubic",
        "-q:v",
        "4",
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
    let dest = preview_dir.join(format!("{safe_key}-aspect-v4.jpg"));
    let src_meta = fs::metadata(source_path).ok()?;
    if is_cache_fresh(&src_meta, &dest) {
        return Some(clean_path_str(&dest));
    }

    let ffmpeg = ffmpeg_path?;
    fs::create_dir_all(&preview_dir).ok()?;
    let tmp = make_unique_temp_path(&preview_dir, "jpg");
    let ok = ["0", "1"].iter().any(|seek| {
        if cancel.map(|c| c.load(Ordering::SeqCst)).unwrap_or(false) {
            return false;
        }
        if use_hw_decode && run_ffmpeg_preview_frame(ffmpeg, source_path, seek, true, &tmp, cancel)
        {
            return true;
        }
        if cancel.map(|c| c.load(Ordering::SeqCst)).unwrap_or(false) {
            return false;
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
    let (mtx, cv) = clip_encode_sema();
    {
        let mut active = mtx.lock().unwrap_or_else(|e| e.into_inner());
        while *active >= 2 {
            if cancel.map(|c| c.load(Ordering::SeqCst)).unwrap_or(false) {
                return false;
            }
            active = cv
                .wait_timeout(active, Duration::from_millis(200))
                .map(|(g, _)| g)
                .unwrap_or_else(|e| e.into_inner().0);
        }
        *active += 1;
    }
    struct ClipSlotGuard;
    impl Drop for ClipSlotGuard {
        fn drop(&mut self) {
            let (mtx, cv) = clip_encode_sema();
            let mut active = mtx.lock().unwrap_or_else(|e| e.into_inner());
            *active = active.saturating_sub(1);
            cv.notify_one();
        }
    }
    let _slot = ClipSlotGuard;

    let mut args = vec![OsString::from("-y")];
    if use_hw_decode {
        args.extend(os_args(["-hwaccel", "auto"]));
    }
    args.push(OsString::from("-i"));
    args.push(source_path.as_os_str().to_os_string());
    args.extend(os_args([
        "-t",
        "8",
        "-an",
        "-vf",
        "scale='max(2,trunc(iw*min(1,min(640/iw,640/ih))/2)*2)':'max(2,trunc(ih*min(1,min(640/iw,640/ih))/2)*2)':flags=fast_bilinear,fps=24",
        "-c:v",
        "libx264",
        "-preset",
        "superfast",
        "-crf",
        "25",
        "-threads",
        "2",
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
    let dest = clip_dir.join(format!("{safe_key}-aspect-v2.mp4"));
    let src_meta = fs::metadata(source_path).ok()?;
    if is_cache_fresh(&src_meta, &dest) {
        return Some(clean_path_str(&dest));
    }

    let ffmpeg = ffmpeg_path?;
    fs::create_dir_all(&clip_dir).ok()?;
    let tmp = make_unique_temp_path(&clip_dir, "mp4");
    let ok = (use_hw_decode
        && run_ffmpeg_preview_clip(ffmpeg, source_path, true, &tmp, cancel))
        || (!cancel.map(|c| c.load(Ordering::SeqCst)).unwrap_or(false)
            && run_ffmpeg_preview_clip(ffmpeg, source_path, false, &tmp, cancel));
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

    #[test]
    fn create_image_thumbnail_preserves_original_aspect_and_top_edge() {
        let dir = std::env::temp_dir().join(format!("wallpull_thumb_aspect_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        // 1600x900 landscape with pure-red top band (head area) -> 800x450 with intact red top band
        let mut wide = image::RgbImage::from_pixel(1600, 900, image::Rgb([0, 80, 200]));
        for y in 0..40 {
            for x in 0..1600 {
                wide.put_pixel(x, y, image::Rgb([255, 0, 0]));
            }
        }
        let wide_src = dir.join("wide.png");
        let wide_out = dir.join("wide_thumb.jpg");
        wide.save(&wide_src).unwrap();
        assert!(encode_rust_cover_thumbnail(&wide_src, &wide_out).is_some());
        let wide_dec = image::open(&wide_out).unwrap().to_rgb8();
        assert_eq!(wide_dec.dimensions(), (800, 450));
        let top_px = wide_dec.get_pixel(400, 10);
        assert!(top_px[0] > 200 && top_px[2] < 50, "top edge must remain red, got {:?}", top_px);

        // 900x1600 portrait -> 450x800
        let tall = image::RgbImage::from_pixel(900, 1600, image::Rgb([40, 160, 80]));
        let tall_src = dir.join("tall.png");
        let tall_out = dir.join("tall_thumb.jpg");
        tall.save(&tall_src).unwrap();
        assert!(encode_rust_cover_thumbnail(&tall_src, &tall_out).is_some());
        assert_eq!(image::image_dimensions(&tall_out).unwrap(), (450, 800));

        // 640x360 smaller than max edge -> preserved at 640x360
        let small = image::RgbImage::from_pixel(640, 360, image::Rgb([100, 100, 220]));
        let small_src = dir.join("small.png");
        let small_out = dir.join("small_thumb.jpg");
        small.save(&small_src).unwrap();
        assert!(encode_rust_cover_thumbnail(&small_src, &small_out).is_some());
        assert_eq!(image::image_dimensions(&small_out).unwrap(), (640, 360));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn parse_mp4_boxes_handles_wrapping_64bit_largesize_without_looping() {
        let dir = std::env::temp_dir().join(format!("wallpull_mp4_wrap_{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let bad_mp4 = dir.join("bad.mp4");
        let mut buf = Vec::new();
        // padding 100 bytes
        buf.resize(100, 0u8);
        // Box at offset 100: size32=1, type='free', largesize = u64::MAX - 99 -> wraps pos + box_size to 1
        buf.extend_from_slice(&1u32.to_be_bytes());
        buf.extend_from_slice(b"free");
        buf.extend_from_slice(&(u64::MAX - 99).to_be_bytes());
        fs::write(&bad_mp4, &buf).unwrap();

        let mut f = File::open(&bad_mp4).unwrap();
        let len = f.metadata().unwrap().len();
        assert!(parse_mp4_boxes(&mut f, 100, len, 0).is_none());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn mp4_hdlr_soun_box_detects_embedded_audio_stream() {
        fn wrap_box(tag: &[u8; 4], body: &[u8]) -> Vec<u8> {
            let mut out = Vec::with_capacity(8 + body.len());
            out.extend_from_slice(&((8 + body.len()) as u32).to_be_bytes());
            out.extend_from_slice(tag);
            out.extend_from_slice(body);
            out
        }
        let dir = std::env::temp_dir().join(format!("wallpull_mp4_soun_{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);

        let mut hdlr_vid = vec![0u8; 12];
        hdlr_vid[8..12].copy_from_slice(b"vide");
        let mdia_vid = wrap_box(b"mdia", &wrap_box(b"hdlr", &hdlr_vid));
        let trak_vid = wrap_box(b"trak", &mdia_vid);

        let mut hdlr_aud = vec![0u8; 12];
        hdlr_aud[8..12].copy_from_slice(b"soun");
        let mdia_aud = wrap_box(b"mdia", &wrap_box(b"hdlr", &hdlr_aud));
        let trak_aud = wrap_box(b"trak", &mdia_aud);

        let moov_silent = wrap_box(b"moov", &trak_vid);
        let silent_mp4 = dir.join("silent.mp4");
        fs::write(&silent_mp4, &moov_silent).unwrap();
        assert!(!video_has_audio_stream(&silent_mp4, None));

        let mut moov_body = Vec::new();
        moov_body.extend_from_slice(&trak_vid);
        moov_body.extend_from_slice(&trak_aud);
        let moov_bgm = wrap_box(b"moov", &moov_body);
        let bgm_mp4 = dir.join("with_bgm.mp4");
        fs::write(&bgm_mp4, &moov_bgm).unwrap();
        assert!(video_has_audio_stream(&bgm_mp4, None));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn ftyp_audio_and_heic_brands_are_not_classified_as_video() {
        let dir = std::env::temp_dir().join(format!("wallpull_ftyp_sniff_{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);

        let m4a_path = dir.join("bgm.m4a");
        let mut m4a_hdr = vec![0u8; 20];
        m4a_hdr[4..8].copy_from_slice(b"ftyp");
        m4a_hdr[8..12].copy_from_slice(b"M4A ");
        fs::write(&m4a_path, &m4a_hdr).unwrap();
        assert_eq!(detect_media_type(&m4a_path), None);

        let heic_path = dir.join("photo.heic");
        let mut heic_hdr = vec![0u8; 20];
        heic_hdr[4..8].copy_from_slice(b"ftyp");
        heic_hdr[8..12].copy_from_slice(b"heic");
        fs::write(&heic_path, &heic_hdr).unwrap();
        assert_eq!(detect_media_type(&heic_path), Some("image"));

        let heic_part = dir.join("upload.part");
        fs::write(&heic_part, &heic_hdr).unwrap();
        assert_eq!(detect_media_type(&heic_part), Some("image"));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn custom_ffmpeg_override_finds_ffmpeg_and_sibling_ffprobe() {
        let dir = std::env::temp_dir().join(format!("wallpull_ffmpeg_override_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let fake_ffmpeg = dir.join("ffmpeg.exe");
        let fake_ffprobe = dir.join("ffprobe.exe");
        fs::write(&fake_ffmpeg, b"MZ").unwrap();
        fs::write(&fake_ffprobe, b"MZ").unwrap();

        let status = detect_ffmpeg_status(fake_ffmpeg.to_str());
        assert!(status.available);
        assert!(status.ffprobe_available);
        assert_eq!(status.source, "custom");
        assert_eq!(
            resolve_custom_executable("ffmpeg.exe", &fake_ffmpeg).as_deref(),
            Some(fake_ffmpeg.as_path())
        );
        assert_eq!(
            resolve_custom_executable("ffprobe.exe", &fake_ffmpeg).as_deref(),
            Some(fake_ffprobe.as_path())
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn custom_ffmpeg_override_rejects_non_ffmpeg_executable() {
        let dir = std::env::temp_dir().join(format!(
            "wallpull_ffmpeg_reject_test_{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("create temp dir");
        let fake_other = dir.join("not_ffmpeg.exe");
        fs::write(&fake_other, b"dummy").expect("write dummy exe");

        assert!(resolve_custom_executable("ffmpeg.exe", &fake_other).is_none());
        let status = detect_ffmpeg_status(fake_other.to_str());
        assert_ne!(status.source, "custom");

        let _ = fs::remove_dir_all(&dir);
    }
}
