use image::codecs::png::{CompressionType, FilterType, PngEncoder};
use image::{ColorType, ImageEncoder};
use std::fs::File;
use std::io::BufWriter;
use std::path::Path;

const FORMAT_RGBA8888: i32 = 0;
const FORMAT_DXT5: i32 = 4;
const FORMAT_DXT3: i32 = 6;
const FORMAT_DXT1: i32 = 7;
const FORMAT_RG88: i32 = 8;
const FORMAT_R8: i32 = 9;
const FLAG_SPRITE_SHEET: i32 = 0x04;

#[derive(Debug, Clone)]
pub struct DecodedTexRgba {
    pub rgba: Vec<u8>,
    pub stride_width: i32,
    pub width: i32,
    pub height: i32,
}

#[derive(Debug, Clone, Copy)]
struct TexMipmapInfo {
    format: i32,
    width: i32,
    height: i32,
    image_width: i32,
    image_height: i32,
    is_lz4: bool,
    is_embedded_image: bool,
    decompressed_size: i32,
    data_offset: usize,
    data_length: usize,
}

pub fn is_sprite_sheet_tex(header: &[u8]) -> bool {
    let mut pos = 0usize;
    let Some(texv) = read_cstr(header, &mut pos) else {
        return false;
    };
    if !texv.starts_with("TEXV") {
        return false;
    }
    let Some(texi) = read_cstr(header, &mut pos) else {
        return false;
    };
    if !texi.starts_with("TEXI") || pos + 8 > header.len() {
        return false;
    }
    let flags = read_i32_le(header, pos + 4);
    (flags & FLAG_SPRITE_SHEET) != 0
}

const MAX_TEX_PIXELS: usize = 67_108_864;

pub fn try_decode_to_rgba(tex_bytes: &[u8]) -> Option<DecodedTexRgba> {
    let mipmap = try_parse_first_mipmap(tex_bytes)?;
    if mipmap.width <= 0
        || mipmap.height <= 0
        || mipmap.image_width <= 0
        || mipmap.image_height <= 0
        || mipmap.width > 16384
        || mipmap.height > 16384
    {
        return None;
    }
    let pixel_count = (mipmap.width as usize).checked_mul(mipmap.height as usize)?;
    if pixel_count > MAX_TEX_PIXELS {
        return None;
    }

    let end_offset = mipmap.data_offset.checked_add(mipmap.data_length)?;
    let raw_slice = tex_bytes.get(mipmap.data_offset..end_offset)?;
    let raw_pixels = if mipmap.is_lz4 {
        if mipmap.decompressed_size <= 0 || mipmap.decompressed_size > 256 * 1024 * 1024 {
            return None;
        }
        decompress_lz4_block(raw_slice, mipmap.decompressed_size as usize)?
    } else {
        raw_slice.to_vec()
    };

    if mipmap.is_embedded_image {
        let dyn_img = image::load_from_memory(&raw_pixels).ok()?;
        let w = dyn_img.width() as i32;
        let h = dyn_img.height() as i32;
        if w <= 0 || h <= 0 || w > 8192 || h > 8192 {
            return None;
        }
        return Some(DecodedTexRgba {
            rgba: dyn_img.to_rgba8().into_raw(),
            stride_width: w,
            width: w,
            height: h,
        });
    }

    let w = mipmap.width as usize;
    let h = mipmap.height as usize;
    let rgba_needed = pixel_count.checked_mul(4)?;
    let rgba = match mipmap.format {
        FORMAT_RGBA8888 => {
            if raw_pixels.len() >= rgba_needed {
                raw_pixels
            } else {
                return None;
            }
        }
        FORMAT_RG88 => decode_rg88(&raw_pixels, w, h)?,
        FORMAT_R8 => decode_r8(&raw_pixels, w, h)?,
        FORMAT_DXT1 => decode_dxt1(&raw_pixels, w, h)?,
        FORMAT_DXT3 => decode_dxt3(&raw_pixels, w, h)?,
        FORMAT_DXT5 => decode_dxt5(&raw_pixels, w, h)?,
        _ => return None,
    };

    let out_w = mipmap.image_width.min(mipmap.width);
    let out_h = mipmap.image_height.min(mipmap.height);
    Some(DecodedTexRgba {
        rgba,
        stride_width: mipmap.width,
        width: out_w,
        height: out_h,
    })
}

pub fn try_decode_to_png(tex_bytes: &[u8], output_png_path: &Path) -> bool {
    let Some(decoded) = try_decode_to_rgba(tex_bytes) else {
        return false;
    };
    write_rgba_to_png(
        output_png_path,
        &decoded.rgba,
        decoded.stride_width,
        decoded.width,
        decoded.height,
    )
    .is_ok()
}

pub fn write_rgba_to_png(
    output_png_path: &Path,
    rgba: &[u8],
    stride_width: i32,
    out_width: i32,
    out_height: i32,
) -> std::io::Result<()> {
    write_rgba_to_png_with_mode(output_png_path, rgba, stride_width, out_width, out_height, false)
}

pub fn write_rgba_to_png_with_mode(
    output_png_path: &Path,
    rgba: &[u8],
    stride_width: i32,
    out_width: i32,
    out_height: i32,
    fast_preview: bool,
) -> std::io::Result<()> {
    if out_width <= 0 || out_height <= 0 || stride_width < out_width {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "Invalid PNG dimensions",
        ));
    }
    if let Some(parent) = output_png_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let ow = out_width as usize;
    let oh = out_height as usize;
    let sw = stride_width as usize;

    let file = File::create(output_png_path)?;
    let writer = BufWriter::with_capacity(256 * 1024, file);
    let encoder = if fast_preview {
        PngEncoder::new_with_quality(writer, CompressionType::Fast, FilterType::Sub)
    } else {
        PngEncoder::new_with_quality(writer, CompressionType::Default, FilterType::Adaptive)
    };

    if sw == ow && rgba.len() >= ow * oh * 4 {
        encoder
            .write_image(&rgba[..ow * oh * 4], out_width as u32, out_height as u32, ColorType::Rgba8.into())
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e.to_string()))
    } else {
        let mut tight = vec![0u8; ow * oh * 4];
        let row_bytes = ow * 4;
        for y in 0..oh {
            let src_off = y * sw * 4;
            if src_off + row_bytes <= rgba.len() {
                tight[y * row_bytes..(y + 1) * row_bytes]
                    .copy_from_slice(&rgba[src_off..src_off + row_bytes]);
            }
        }
        encoder
            .write_image(&tight, out_width as u32, out_height as u32, ColorType::Rgba8.into())
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e.to_string()))
    }
}

fn try_parse_first_mipmap(buffer: &[u8]) -> Option<TexMipmapInfo> {
    if buffer.len() < 64 {
        return None;
    }

    let mut pos = 0usize;
    let texv = read_cstr(buffer, &mut pos)?;
    if !texv.starts_with("TEXV") {
        return None;
    }
    let texi = read_cstr(buffer, &mut pos)?;
    if !texi.starts_with("TEXI") || pos + 28 > buffer.len() {
        return None;
    }

    let format = read_i32_le(buffer, pos);
    let flags = read_i32_le(buffer, pos + 4);
    if (flags & FLAG_SPRITE_SHEET) != 0 {
        return None;
    }
    let texture_width = read_i32_le(buffer, pos + 8);
    let texture_height = read_i32_le(buffer, pos + 12);
    let image_width = read_i32_le(buffer, pos + 16);
    let image_height = read_i32_le(buffer, pos + 20);
    pos += 28;

    let texb = read_cstr(buffer, &mut pos)?;
    if !texb.starts_with("TEXB") || pos + 4 > buffer.len() {
        return None;
    }
    let texb_version: i32 = texb[4..].parse().unwrap_or(0);

    let image_count = read_i32_le(buffer, pos);
    pos += 4;
    if image_count <= 0 {
        return None;
    }

    let mut free_image_format = -1i32;
    if texb_version >= 3 {
        if pos + 4 > buffer.len() {
            return None;
        }
        free_image_format = read_i32_le(buffer, pos);
        pos += 4;
    }

    if texb_version >= 4 {
        if pos + 4 > buffer.len() {
            return None;
        }
        let is_video_mp4 = read_i32_le(buffer, pos);
        pos += 4;
        if is_video_mp4 != 0 {
            return None;
        }
    }

    if pos + 12 > buffer.len() {
        return None;
    }
    let mipmap_count = read_i32_le(buffer, pos);
    let mip_width = read_i32_le(buffer, pos + 4);
    let mip_height = read_i32_le(buffer, pos + 8);
    pos += 12;
    if mipmap_count <= 0 {
        return None;
    }

    let mut is_lz4 = false;
    let mut decompressed_size = 0i32;
    if texb_version >= 2 {
        if pos + 8 > buffer.len() {
            return None;
        }
        is_lz4 = read_i32_le(buffer, pos) == 1;
        decompressed_size = read_i32_le(buffer, pos + 4);
        pos += 8;
    }

    if pos + 4 > buffer.len() {
        return None;
    }
    let data_length = read_i32_le(buffer, pos);
    pos += 4;
    if data_length <= 0 {
        return None;
    }
    let data_len_usize = data_length as usize;
    if pos.checked_add(data_len_usize)? > buffer.len() {
        return None;
    }

    Some(TexMipmapInfo {
        format,
        width: if mip_width > 0 { mip_width } else { texture_width },
        height: if mip_height > 0 { mip_height } else { texture_height },
        image_width: if image_width > 0 { image_width } else { mip_width },
        image_height: if image_height > 0 { image_height } else { mip_height },
        is_lz4,
        is_embedded_image: free_image_format != -1,
        decompressed_size,
        data_offset: pos,
        data_length: data_len_usize,
    })
}

fn read_cstr<'a>(buf: &'a [u8], pos: &mut usize) -> Option<&'a str> {
    let start = *pos;
    let limit = (start + 32).min(buf.len());
    while *pos < limit && buf[*pos] != 0 {
        *pos += 1;
    }
    if *pos >= buf.len() || buf[*pos] != 0 {
        return None;
    }
    let s = std::str::from_utf8(&buf[start..*pos]).ok()?;
    *pos += 1;
    Some(s)
}

#[inline]
fn read_i32_le(buf: &[u8], off: usize) -> i32 {
    i32::from_le_bytes(buf[off..off + 4].try_into().unwrap_or([0; 4]))
}

#[inline]
fn read_u16_le(buf: &[u8], off: usize) -> u16 {
    u16::from_le_bytes(buf[off..off + 2].try_into().unwrap_or([0; 2]))
}

#[inline]
fn read_u32_le(buf: &[u8], off: usize) -> u32 {
    u32::from_le_bytes(buf[off..off + 4].try_into().unwrap_or([0; 4]))
}

#[inline]
fn read_u64_le(buf: &[u8], off: usize) -> u64 {
    u64::from_le_bytes(buf[off..off + 8].try_into().unwrap_or([0; 8]))
}

pub fn decompress_lz4_block(input: &[u8], output_len: usize) -> Option<Vec<u8>> {
    if output_len > 256 * 1024 * 1024 {
        return None;
    }
    let mut output = vec![0u8; output_len];
    let mut src = 0usize;
    let mut dst = 0usize;

    while src < input.len() {
        let token = input[src];
        src += 1;
        let mut lit_len = (token >> 4) as usize;
        if lit_len == 15 {
            loop {
                if src >= input.len() {
                    return None;
                }
                let extra = input[src] as usize;
                src += 1;
                lit_len = lit_len.checked_add(extra)?;
                if lit_len > output_len {
                    return None;
                }
                if extra != 255 {
                    break;
                }
            }
        }

        if lit_len > 0 {
            let src_end = src.checked_add(lit_len)?;
            let dst_end = dst.checked_add(lit_len)?;
            if src_end > input.len() || dst_end > output_len {
                return None;
            }
            output[dst..dst_end].copy_from_slice(&input[src..src_end]);
            src = src_end;
            dst = dst_end;
        }

        if src >= input.len() {
            break;
        }
        if src.checked_add(2)? > input.len() {
            return None;
        }
        let match_offset = (input[src] as usize) | ((input[src + 1] as usize) << 8);
        src += 2;
        if match_offset == 0 || match_offset > dst {
            return None;
        }

        let mut match_len = (token & 0x0F) as usize + 4;
        if (token & 0x0F) == 15 {
            loop {
                if src >= input.len() {
                    return None;
                }
                let extra = input[src] as usize;
                src += 1;
                match_len = match_len.checked_add(extra)?;
                if match_len > output_len {
                    return None;
                }
                if extra != 255 {
                    break;
                }
            }
        }

        let mut match_pos = dst - match_offset;
        let end = dst.checked_add(match_len)?;
        if end > output_len {
            return None;
        }
        while dst < end {
            output[dst] = output[match_pos];
            dst += 1;
            match_pos += 1;
        }
    }

    if dst != output_len {
        return None;
    }

    Some(output)
}

fn decode_r8(data: &[u8], width: usize, height: usize) -> Option<Vec<u8>> {
    let count = width.checked_mul(height)?;
    if count > MAX_TEX_PIXELS || data.len() < count {
        return None;
    }
    let buf_len = count.checked_mul(4)?;
    let mut rgba = vec![0u8; buf_len];
    for i in 0..count {
        let v = data[i];
        let o = i * 4;
        rgba[o] = v;
        rgba[o + 1] = v;
        rgba[o + 2] = v;
        rgba[o + 3] = 255;
    }
    Some(rgba)
}

fn decode_rg88(data: &[u8], width: usize, height: usize) -> Option<Vec<u8>> {
    let count = width.checked_mul(height)?;
    if count > MAX_TEX_PIXELS || data.len() < count.checked_mul(2)? {
        return None;
    }
    let buf_len = count.checked_mul(4)?;
    let mut rgba = vec![0u8; buf_len];
    for i in 0..count {
        let lum = data[i * 2];
        let alpha = data[i * 2 + 1];
        let o = i * 4;
        rgba[o] = lum;
        rgba[o + 1] = lum;
        rgba[o + 2] = lum;
        rgba[o + 3] = alpha;
    }
    Some(rgba)
}

fn decode_dxt1(data: &[u8], width: usize, height: usize) -> Option<Vec<u8>> {
    let count = width.checked_mul(height)?;
    if count > MAX_TEX_PIXELS {
        return None;
    }
    let mut rgba = vec![0u8; count.checked_mul(4)?];
    let blocks_x = width.div_ceil(4);
    let blocks_y = height.div_ceil(4);
    let mut offset = 0usize;
    for by in 0..blocks_y {
        for bx in 0..blocks_x {
            if offset + 8 > data.len() {
                return Some(rgba);
            }
            decode_color_block(data, offset, &mut rgba, width, height, bx * 4, by * 4, true);
            offset += 8;
        }
    }
    Some(rgba)
}

fn decode_dxt3(data: &[u8], width: usize, height: usize) -> Option<Vec<u8>> {
    let count = width.checked_mul(height)?;
    if count > MAX_TEX_PIXELS {
        return None;
    }
    let mut rgba = vec![0u8; count.checked_mul(4)?];
    let blocks_x = width.div_ceil(4);
    let blocks_y = height.div_ceil(4);
    let mut offset = 0usize;
    for by in 0..blocks_y {
        for bx in 0..blocks_x {
            if offset + 16 > data.len() {
                return Some(rgba);
            }
            decode_color_block(data, offset + 8, &mut rgba, width, height, bx * 4, by * 4, false);
            let alpha_bits = read_u64_le(data, offset);
            for py in 0..4 {
                let y = by * 4 + py;
                if y >= height {
                    continue;
                }
                for px in 0..4 {
                    let x = bx * 4 + px;
                    if x >= width {
                        continue;
                    }
                    let a4 = ((alpha_bits >> ((py * 4 + px) * 4)) & 0xF) as u8;
                    rgba[(y * width + x) * 4 + 3] = a4 | (a4 << 4);
                }
            }
            offset += 16;
        }
    }
    Some(rgba)
}

fn decode_dxt5(data: &[u8], width: usize, height: usize) -> Option<Vec<u8>> {
    let count = width.checked_mul(height)?;
    if count > MAX_TEX_PIXELS {
        return None;
    }
    let mut rgba = vec![0u8; count.checked_mul(4)?];
    let blocks_x = width.div_ceil(4);
    let blocks_y = height.div_ceil(4);
    let mut offset = 0usize;
    let mut alphas = [0u8; 8];

    for by in 0..blocks_y {
        for bx in 0..blocks_x {
            if offset + 16 > data.len() {
                return Some(rgba);
            }
            let a0 = data[offset] as u16;
            let a1 = data[offset + 1] as u16;
            alphas[0] = a0 as u8;
            alphas[1] = a1 as u8;
            if a0 > a1 {
                alphas[2] = ((6 * a0 + a1) / 7) as u8;
                alphas[3] = ((5 * a0 + 2 * a1) / 7) as u8;
                alphas[4] = ((4 * a0 + 3 * a1) / 7) as u8;
                alphas[5] = ((3 * a0 + 4 * a1) / 7) as u8;
                alphas[6] = ((2 * a0 + 5 * a1) / 7) as u8;
                alphas[7] = ((a0 + 6 * a1) / 7) as u8;
            } else {
                alphas[2] = ((4 * a0 + a1) / 5) as u8;
                alphas[3] = ((3 * a0 + 2 * a1) / 5) as u8;
                alphas[4] = ((2 * a0 + 3 * a1) / 5) as u8;
                alphas[5] = ((a0 + 4 * a1) / 5) as u8;
                alphas[6] = 0;
                alphas[7] = 255;
            }

            let mut alpha_indices = 0u64;
            for i in 0..6 {
                alpha_indices |= (data[offset + 2 + i] as u64) << (8 * i);
            }

            decode_color_block(data, offset + 8, &mut rgba, width, height, bx * 4, by * 4, false);
            for py in 0..4 {
                let y = by * 4 + py;
                if y >= height {
                    continue;
                }
                for px in 0..4 {
                    let x = bx * 4 + px;
                    if x >= width {
                        continue;
                    }
                    let idx = ((alpha_indices >> ((py * 4 + px) * 3)) & 0x7) as usize;
                    rgba[(y * width + x) * 4 + 3] = alphas[idx];
                }
            }
            offset += 16;
        }
    }
    Some(rgba)
}

#[allow(clippy::too_many_arguments)]
fn decode_color_block(
    data: &[u8],
    offset: usize,
    rgba: &mut [u8],
    width: usize,
    height: usize,
    start_x: usize,
    start_y: usize,
    dxt1_alpha: bool,
) {
    let c0 = read_u16_le(data, offset);
    let c1 = read_u16_le(data, offset + 2);
    let indices = read_u32_le(data, offset + 4);

    let mut r = [0u8; 4];
    let mut g = [0u8; 4];
    let mut b = [0u8; 4];
    let mut a = [255u8; 4];

    r[0] = (((c0 >> 11) & 0x1F) * 255 / 31) as u8;
    g[0] = (((c0 >> 5) & 0x3F) * 255 / 63) as u8;
    b[0] = ((c0 & 0x1F) * 255 / 31) as u8;

    r[1] = (((c1 >> 11) & 0x1F) * 255 / 31) as u8;
    g[1] = (((c1 >> 5) & 0x3F) * 255 / 63) as u8;
    b[1] = ((c1 & 0x1F) * 255 / 31) as u8;

    if !dxt1_alpha || c0 > c1 {
        r[2] = ((2 * r[0] as u16 + r[1] as u16) / 3) as u8;
        g[2] = ((2 * g[0] as u16 + g[1] as u16) / 3) as u8;
        b[2] = ((2 * b[0] as u16 + b[1] as u16) / 3) as u8;

        r[3] = ((r[0] as u16 + 2 * r[1] as u16) / 3) as u8;
        g[3] = ((g[0] as u16 + 2 * g[1] as u16) / 3) as u8;
        b[3] = ((b[0] as u16 + 2 * b[1] as u16) / 3) as u8;
    } else {
        r[2] = ((r[0] as u16 + r[1] as u16) / 2) as u8;
        g[2] = ((g[0] as u16 + g[1] as u16) / 2) as u8;
        b[2] = ((b[0] as u16 + b[1] as u16) / 2) as u8;
        a[3] = 0;
    }

    for py in 0..4 {
        let y = start_y + py;
        if y >= height {
            continue;
        }
        for px in 0..4 {
            let x = start_x + px;
            if x >= width {
                continue;
            }
            let idx = ((indices >> ((py * 4 + px) * 2)) & 0x3) as usize;
            let dst = (y * width + x) * 4;
            rgba[dst] = r[idx];
            rgba[dst + 1] = g[idx];
            rgba[dst + 2] = b[idx];
            rgba[dst + 3] = a[idx];
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_rgba_tex_and_write_png() {
        let mut tex = Vec::new();
        tex.extend_from_slice(b"TEXV0005\0");
        tex.extend_from_slice(b"TEXI0001\0");
        tex.extend_from_slice(&FORMAT_RGBA8888.to_le_bytes());
        tex.extend_from_slice(&0i32.to_le_bytes());
        tex.extend_from_slice(&2i32.to_le_bytes());
        tex.extend_from_slice(&2i32.to_le_bytes());
        tex.extend_from_slice(&2i32.to_le_bytes());
        tex.extend_from_slice(&2i32.to_le_bytes());
        tex.extend_from_slice(&0i32.to_le_bytes());
        tex.extend_from_slice(b"TEXB0003\0");
        tex.extend_from_slice(&1i32.to_le_bytes()); // image_count
        tex.extend_from_slice(&(-1i32).to_le_bytes()); // free_image_format
        tex.extend_from_slice(&1i32.to_le_bytes()); // mipmap_count
        tex.extend_from_slice(&2i32.to_le_bytes());
        tex.extend_from_slice(&2i32.to_le_bytes());
        tex.extend_from_slice(&0i32.to_le_bytes()); // not lz4
        tex.extend_from_slice(&16i32.to_le_bytes()); // decompressed
        tex.extend_from_slice(&16i32.to_le_bytes()); // data_length
        let pixels = [
            255u8, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 128,
        ];
        tex.extend_from_slice(&pixels);

        let decoded = try_decode_to_rgba(&tex).expect("decode rgba");
        assert_eq!(decoded.width, 2);
        assert_eq!(decoded.height, 2);
        assert_eq!(&decoded.rgba[0..4], &[255, 0, 0, 255]);

        let tmp = std::env::temp_dir().join("wallpull_tex_test.png");
        assert!(try_decode_to_png(&tex, &tmp));
        let dims = image::image_dimensions(&tmp).expect("valid png");
        assert_eq!(dims, (2, 2));
        let _ = std::fs::remove_file(tmp);
    }

    #[test]
    fn sprite_sheet_flag_detected() {
        let mut tex = Vec::new();
        tex.extend_from_slice(b"TEXV0005\0");
        tex.extend_from_slice(b"TEXI0001\0");
        tex.extend_from_slice(&0i32.to_le_bytes());
        tex.extend_from_slice(&FLAG_SPRITE_SHEET.to_le_bytes());
        assert!(is_sprite_sheet_tex(&tex));
    }

    #[test]
    fn malformed_lz4_rejects_overflow_truncation_and_overrun() {
        // 1) Overrun past declared output_len (token 0x20: 2 literals, then match off=1, len=4 => 6 > 4)
        let overrun = [0x20u8, b'a', b'b', 0x01, 0x00];
        assert!(decompress_lz4_block(&overrun, 4).is_none());
        // 2) Truncated stream (only 2 bytes written for output_len = 8)
        let truncated = [0x20u8, b'a', b'b'];
        assert!(decompress_lz4_block(&truncated, 8).is_none());
        // 3) Valid block writes exact output_len
        let valid = [0x22u8, b'a', b'b', 0x02, 0x00];
        let dec = decompress_lz4_block(&valid, 8).expect("valid lz4");
        assert_eq!(&dec, b"abababab");
    }
}
