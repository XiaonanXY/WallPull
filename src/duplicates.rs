use crate::models::{
    CachedVisualFingerprint, DuplicateGroupMemberPayload, DuplicateGroupPayload, WallpaperItem,
    WallpaperPayloadItem,
};
use image::DynamicImage;
use image::imageops::FilterType;
use rayon::prelude::*;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::File;
use std::io::Read;
use std::path::Path;

#[derive(Clone)]
struct VisualFingerprint<'a> {
    item: &'a WallpaperItem,
    d_hash: u64,
    a_hash: u64,
    mean_r: f32,
    mean_g: f32,
    mean_b: f32,
    luma_range: u8,
    exact_digest: Option<String>,
}

pub struct DuplicateScanResult {
    pub groups: Vec<DuplicateGroupPayload>,
    pub total_reclaimable_bytes: i64,
    pub scanned_count: usize,
}

pub fn analyze_duplicates<F>(
    all_items: &[WallpaperItem],
    build_payload: F,
) -> DuplicateScanResult
where
    F: Fn(&WallpaperItem) -> Option<WallpaperPayloadItem>,
{
    let mut by_ws: HashMap<&str, &WallpaperItem> = HashMap::new();
    for item in all_items {
        if item.workshop_directory.trim().is_empty() {
            continue;
        }
        by_ws
            .entry(item.workshop_id.as_str())
            .and_modify(|cur| {
                let new_px = parse_pixel_count(item.resolution.as_deref());
                let cur_px = parse_pixel_count(cur.resolution.as_deref());
                let new_sz = if item.folder_size > 0 { item.folder_size } else { item.file_size };
                let cur_sz = if cur.folder_size > 0 { cur.folder_size } else { cur.file_size };
                if (new_px, new_sz) > (cur_px, cur_sz) {
                    *cur = item;
                }
            })
            .or_insert(item);
    }

    let distinct: Vec<&WallpaperItem> = by_ws.into_values().collect();
    let scanned_count = distinct.len();
    if scanned_count < 2 {
        return DuplicateScanResult {
            groups: Vec::new(),
            total_reclaimable_bytes: 0,
            scanned_count,
        };
    }

    let valid: Vec<VisualFingerprint<'_>> = distinct
        .par_iter()
        .filter_map(|&item| {
            if let Some(cached) = &item.visual_fingerprint {
                Some(VisualFingerprint {
                    item,
                    d_hash: cached.d_hash,
                    a_hash: cached.a_hash,
                    mean_r: cached.mean_r,
                    mean_g: cached.mean_g,
                    mean_b: cached.mean_b,
                    luma_range: cached.luma_range,
                    exact_digest: cached.exact_digest.clone(),
                })
            } else {
                compute_fingerprint(item)
            }
        })
        .collect();

    if valid.len() < 2 {
        return DuplicateScanResult {
            groups: Vec::new(),
            total_reclaimable_bytes: 0,
            scanned_count,
        };
    }

    let mut full_hash_cache: HashMap<String, Option<String>> = HashMap::new();
    let mut parent: Vec<usize> = (0..valid.len()).collect();
    for i in 0..valid.len() {
        for j in (i + 1)..valid.len() {
            if is_match(&valid[i], &valid[j], &mut full_hash_cache) {
                let ra = uf_find(&mut parent, i);
                let rb = uf_find(&mut parent, j);
                if ra != rb {
                    parent[rb] = ra;
                }
            }
        }
    }

    let mut clusters: HashMap<usize, Vec<&VisualFingerprint<'_>>> = HashMap::new();
    for i in 0..valid.len() {
        let root = uf_find(&mut parent, i);
        clusters.entry(root).or_default().push(&valid[i]);
    }

    let mut groups = Vec::new();
    let mut total_reclaimable = 0i64;

    for mut cluster in clusters.into_values().filter(|c| c.len() >= 2) {
        cluster.sort_by(|a, b| {
            let a_px = parse_pixel_count(a.item.resolution.as_deref());
            let b_px = parse_pixel_count(b.item.resolution.as_deref());
            let a_aud = a.item.audio_paths.as_ref().map(|v| !v.is_empty()).unwrap_or(false);
            let b_aud = b.item.audio_paths.as_ref().map(|v| !v.is_empty()).unwrap_or(false);
            b_px.cmp(&a_px)
                .then_with(|| b_aud.cmp(&a_aud))
                .then_with(|| b.item.file_size.cmp(&a.item.file_size))
                .then_with(|| b.item.folder_size.cmp(&a.item.folder_size))
        });

        let anchor = cluster[0];
        let direct_cluster: Vec<&VisualFingerprint<'_>> = std::iter::once(anchor)
            .chain(
                cluster[1..]
                    .iter()
                    .copied()
                    .filter(|cur| is_match(anchor, cur, &mut full_hash_cache)),
            )
            .collect();
        if direct_cluster.len() < 2 {
            continue;
        }

        let mut members = Vec::with_capacity(direct_cluster.len());
        let mut group_reclaimable = 0i64;

        for (i, cur) in direct_cluster.iter().enumerate() {
            let Some(payload_item) = build_payload(cur.item) else {
                continue;
            };
            let (sim, reason) = if i == 0 {
                (100, "最高规格 · 推荐保留".to_string())
            } else {
                let reclaim = if cur.item.folder_size > 0 {
                    cur.item.folder_size
                } else {
                    cur.item.file_size
                };
                group_reclaimable += reclaim;
                describe_match(anchor, cur, &mut full_hash_cache)
            };
            members.push(DuplicateGroupMemberPayload {
                item: payload_item,
                recommended_keep: i == 0,
                similarity_percent: sim,
                match_reason: reason,
            });
        }

        if members.len() >= 2 {
            total_reclaimable += group_reclaimable;
            groups.push(DuplicateGroupPayload {
                group_id: format!("dup-{}", anchor.item.workshop_id),
                reclaimable_bytes: group_reclaimable,
                members,
            });
        }
    }

    groups.sort_by(|a, b| {
        b.reclaimable_bytes
            .cmp(&a.reclaimable_bytes)
            .then_with(|| b.members.len().cmp(&a.members.len()))
    });

    DuplicateScanResult {
        groups,
        total_reclaimable_bytes: total_reclaimable,
        scanned_count,
    }
}

fn uf_find(parent: &mut [usize], mut x: usize) -> usize {
    while parent[x] != x {
        parent[x] = parent[parent[x]];
        x = parent[x];
    }
    x
}

fn is_exact_same_file(
    a: &VisualFingerprint<'_>,
    b: &VisualFingerprint<'_>,
    full_hash_cache: &mut HashMap<String, Option<String>>,
) -> bool {
    if a.exact_digest.is_none()
        || a.item.file_size <= 0
        || a.item.file_size != b.item.file_size
        || a.exact_digest != b.exact_digest
    {
        return false;
    }
    let ha = cached_full_sha256(&a.item.source_path, full_hash_cache);
    let hb = cached_full_sha256(&b.item.source_path, full_hash_cache);
    matches!((ha, hb), (Some(x), Some(y)) if x == y)
}

fn is_match(
    a: &VisualFingerprint<'_>,
    b: &VisualFingerprint<'_>,
    full_hash_cache: &mut HashMap<String, Option<String>>,
) -> bool {
    if is_exact_same_file(a, b, full_hash_cache) {
        return true;
    }
    if a.luma_range < 14 || b.luma_range < 14 {
        return false;
    }
    let d_dist = (a.d_hash ^ b.d_hash).count_ones();
    let a_dist = (a.a_hash ^ b.a_hash).count_ones();
    if d_dist > 8 || a_dist > 10 {
        return false;
    }
    let dr = a.mean_r - b.mean_r;
    let dg = a.mean_g - b.mean_g;
    let db = a.mean_b - b.mean_b;
    (dr * dr + dg * dg + db * db).sqrt() < 42.0
}

fn describe_match(
    anchor: &VisualFingerprint<'_>,
    cand: &VisualFingerprint<'_>,
    full_hash_cache: &mut HashMap<String, Option<String>>,
) -> (i32, String) {
    if is_exact_same_file(anchor, cand, full_hash_cache) {
        return (100, "完全相同源文件".to_string());
    }
    let d_dist = (anchor.d_hash ^ cand.d_hash).count_ones() as f64;
    let sim = (100.0 - (d_dist / 64.0 * 100.0)).round().clamp(0.0, 99.0) as i32;
    let anchor_px = parse_pixel_count(anchor.item.resolution.as_deref());
    let cand_px = parse_pixel_count(cand.item.resolution.as_deref());
    let reason = if cand_px > 0 && anchor_px > cand_px {
        format!("疑似低清晰度版本（{sim}% 相似）")
    } else if anchor.item.item_type != cand.item.item_type {
        format!("动/静双版本近似（{sim}% 相似）")
    } else {
        format!("画面高度相似（{sim}%）")
    };
    (sim, reason)
}

pub fn classify_color_bucket_from_image(img: &DynamicImage) -> String {
    let small = img.resize_exact(16, 16, FilterType::Triangle).to_rgb8();
    let data = small.as_raw();
    let pixel_count = (data.len() / 3) as f32;

    let mut counts = [
        ("dark", 0.0f32),
        ("light", 0.0f32),
        ("blue", 0.0f32),
        ("purple", 0.0f32),
        ("green", 0.0f32),
        ("warm", 0.0f32),
    ];
    let mut total_luma = 0.0f32;
    let mut chroma_pixels = 0.0f32;

    for rgb in data.chunks_exact(3) {
        let r = rgb[0] as f32 / 255.0;
        let g = rgb[1] as f32 / 255.0;
        let b = rgb[2] as f32 / 255.0;
        let max = r.max(g).max(b);
        let min = r.min(g).min(b);
        let delta = max - min;
        let l = (max + min) * 0.5;
        total_luma += l;

        if delta < 0.12 {
            if l < 0.28 {
                counts[0].1 += 1.0;
            } else if l > 0.78 {
                counts[1].1 += 1.0;
            }
            continue;
        }

        let denom = if l > 0.5 { 2.0 - max - min } else { max + min };
        let s = if denom > 0.0 { delta / denom } else { 0.0 };
        if s < 0.16 {
            if l < 0.28 {
                counts[0].1 += 1.0;
            } else if l > 0.78 {
                counts[1].1 += 1.0;
            }
            continue;
        }

        chroma_pixels += 1.0;
        let hue = if (max - r).abs() < f32::EPSILON {
            ((g - b) / delta + if g < b { 6.0 } else { 0.0 }) * 60.0
        } else if (max - g).abs() < f32::EPSILON {
            ((b - r) / delta + 2.0) * 60.0
        } else {
            ((r - g) / delta + 4.0) * 60.0
        };

        if !(55.0..335.0).contains(&hue) {
            counts[5].1 += 1.25;
        } else if (55.0..168.0).contains(&hue) {
            counts[4].1 += 1.25;
        } else if (168.0..252.0).contains(&hue) {
            counts[2].1 += 1.25;
        } else {
            counts[3].1 += 1.25;
        }
    }

    let avg_luma = total_luma / pixel_count.max(1.0);
    if chroma_pixels < pixel_count * 0.22 {
        if avg_luma < 0.34 {
            return "dark".to_string();
        }
        if avg_luma > 0.72 {
            return "light".to_string();
        }
    }

    let mut best_key = if avg_luma < 0.4 { "dark" } else { "light" };
    let mut best_score = -1.0f32;
    for (key, score) in counts {
        if score > best_score {
            best_score = score;
            best_key = key;
        }
    }
    best_key.to_string()
}

pub fn build_visual_fingerprint_from_image(
    img: &DynamicImage,
    exact_digest: Option<String>,
) -> CachedVisualFingerprint {
    let small = img.resize_exact(9, 8, FilterType::Triangle).to_rgb8();
    let raw = small.as_raw();

    let mut luma = [0.0f32; 9 * 8];
    let (mut sum_r, mut sum_g, mut sum_b, mut sum_l) = (0.0f32, 0.0f32, 0.0f32, 0.0f32);
    let (mut min_l, mut max_l) = (255.0f32, 0.0f32);

    for y in 0..8 {
        for x in 0..9 {
            let idx = (y * 9 + x) * 3;
            let (r, g, b) = (raw[idx] as f32, raw[idx + 1] as f32, raw[idx + 2] as f32);
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
            luma[y * 9 + x] = lum;
            if x < 8 {
                sum_r += r;
                sum_g += g;
                sum_b += b;
                sum_l += lum;
                min_l = min_l.min(lum);
                max_l = max_l.max(lum);
            }
        }
    }

    let mut d_hash = 0u64;
    let mut d_bit = 0u32;
    for y in 0..8 {
        for x in 0..8 {
            if luma[y * 9 + x] > luma[y * 9 + x + 1] {
                d_hash |= 1u64 << d_bit;
            }
            d_bit += 1;
        }
    }

    let mean_l = sum_l / 64.0;
    let mut a_hash = 0u64;
    let mut a_bit = 0u32;
    for y in 0..8 {
        for x in 0..8 {
            if luma[y * 9 + x] >= mean_l {
                a_hash |= 1u64 << a_bit;
            }
            a_bit += 1;
        }
    }

    CachedVisualFingerprint {
        d_hash,
        a_hash,
        mean_r: sum_r / 64.0,
        mean_g: sum_g / 64.0,
        mean_b: sum_b / 64.0,
        luma_range: (max_l - min_l).round().clamp(0.0, 255.0) as u8,
        exact_digest,
    }
}

pub fn compute_visual_profile(
    image_path: &Path,
    source_path: Option<&Path>,
) -> Option<(String, CachedVisualFingerprint)> {
    let img = image::open(image_path).ok()?;
    let color_bucket = classify_color_bucket_from_image(&img);
    let exact_digest = source_path
        .filter(|p| p.is_file())
        .and_then(try_prefix_digest);
    let fp = build_visual_fingerprint_from_image(&img, exact_digest);
    Some((color_bucket, fp))
}

fn compute_fingerprint(item: &WallpaperItem) -> Option<VisualFingerprint<'_>> {
    let image_path = if Path::new(&item.preview_path).is_file() {
        &item.preview_path
    } else if item.item_type == "image" && Path::new(&item.source_path).is_file() {
        &item.source_path
    } else {
        return None;
    };

    let (_, cached) = compute_visual_profile(Path::new(image_path), Some(Path::new(&item.source_path)))?;
    Some(VisualFingerprint {
        item,
        d_hash: cached.d_hash,
        a_hash: cached.a_hash,
        mean_r: cached.mean_r,
        mean_g: cached.mean_g,
        mean_b: cached.mean_b,
        luma_range: cached.luma_range,
        exact_digest: cached.exact_digest,
    })
}

fn cached_full_sha256(
    path_str: &str,
    cache: &mut HashMap<String, Option<String>>,
) -> Option<String> {
    if let Some(hit) = cache.get(path_str) {
        return hit.clone();
    }
    let computed = try_full_sha256(Path::new(path_str));
    cache.insert(path_str.to_string(), computed.clone());
    computed
}

fn try_full_sha256(path: &Path) -> Option<String> {
    let mut f = File::open(path).ok()?;
    let mut buf = vec![0u8; 64 * 1024];
    let mut hasher = Sha256::new();
    loop {
        let n = f.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Some(hex::encode_upper(hasher.finalize()))
}

fn try_prefix_digest(path: &Path) -> Option<String> {
    let mut f = File::open(path).ok()?;
    let mut buf = vec![0u8; 65536];
    let n = f.read(&mut buf).ok()?;
    if n == 0 {
        return None;
    }
    let mut hasher = Sha256::new();
    hasher.update(&buf[..n]);
    Some(hex::encode_upper(hasher.finalize()))
}

fn parse_pixel_count(res: Option<&str>) -> i64 {
    let Some(s) = res else { return 0 };
    let mut parts = s.split(['×', 'x', 'X']);
    let w = parts.next().and_then(|p| p.trim().parse::<i64>().ok());
    let h = parts.next().and_then(|p| p.trim().parse::<i64>().ok());
    match (w, h) {
        (Some(w), Some(h)) => w.saturating_mul(h),
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgba, RgbaImage};

    fn solid_dynamic(r: u8, g: u8, b: u8) -> DynamicImage {
        DynamicImage::ImageRgba8(RgbaImage::from_pixel(24, 24, Rgba([r, g, b, 255])))
    }

    #[test]
    fn classify_color_buckets_matches_expected_palette() {
        assert_eq!(classify_color_bucket_from_image(&solid_dynamic(18, 18, 22)), "dark");
        assert_eq!(classify_color_bucket_from_image(&solid_dynamic(242, 242, 246)), "light");
        assert_eq!(classify_color_bucket_from_image(&solid_dynamic(40, 120, 240)), "blue");
        assert_eq!(classify_color_bucket_from_image(&solid_dynamic(150, 70, 235)), "purple");
        assert_eq!(classify_color_bucket_from_image(&solid_dynamic(55, 200, 110)), "green");
        assert_eq!(classify_color_bucket_from_image(&solid_dynamic(240, 125, 50)), "warm");
    }

    #[test]
    fn analyze_duplicates_reuses_persisted_visual_fingerprint() {
        let fp = CachedVisualFingerprint {
            d_hash: 0x1234_5678_9abc_def0,
            a_hash: 0x0fed_cba9_8765_4321,
            mean_r: 120.0,
            mean_g: 90.0,
            mean_b: 200.0,
            luma_range: 64,
            exact_digest: None,
        };
        let make_item = |id: &str, res: &str| WallpaperItem {
            id: id.to_string(),
            workshop_id: id.to_string(),
            title: id.to_string(),
            item_type: "image".to_string(),
            preview_path: "nonexistent_preview.png".to_string(),
            source_path: "nonexistent_src.png".to_string(),
            workshop_directory: format!("C:\\ws\\{id}"),
            original_type: "image".to_string(),
            resolution: Some(res.to_string()),
            duration: None,
            file_size: 1000,
            asset_paths: None,
            has_preview: false,
            preview_video_path: None,
            folder_size: 2000,
            audio_paths: None,
            color_bucket: Some("purple".to_string()),
            visual_fingerprint: Some(fp.clone()),
        };

        let items = vec![make_item("101", "3840 × 2160"), make_item("102", "1920 × 1080")];
        let res = analyze_duplicates(&items, |w| {
            Some(WallpaperPayloadItem {
                id: w.id.clone(),
                workshop_id: w.workshop_id.clone(),
                title: w.title.clone(),
                item_type: w.item_type.clone(),
                original_type: w.original_type.clone(),
                preview_url: None,
                preview_video_url: None,
                media_url: String::new(),
                asset_urls: Vec::new(),
                resolution: w.resolution.clone(),
                duration: None,
                file_size: w.file_size,
                folder_size: w.folder_size,
                audio_tracks: Vec::new(),
                has_audio: false,
                has_preview: false,
                has_scene_layers: false,
                asset_count: 1,
                content_rating: "Everyone".to_string(),
                tags: Vec::new(),
                customizable_count: 0,
                is_archived_offline: false,
                is_slimmable_mp4: false,
                color_bucket: w.color_bucket.clone(),
            })
        });
        assert_eq!(res.groups.len(), 1);
        assert_eq!(res.groups[0].members.len(), 2);
        assert!(res.groups[0].members[0].recommended_keep);
        assert_eq!(res.groups[0].members[0].item.id, "101");
    }

    #[test]
    fn transitive_chain_excludes_unrelated_tail_member() {
        let make_fp = |id: &str, res: &str, d_hash: u64, a_hash: u64| WallpaperItem {
            id: id.to_string(),
            workshop_id: id.to_string(),
            title: id.to_string(),
            item_type: "image".to_string(),
            preview_path: "nonexistent.png".to_string(),
            source_path: "nonexistent.png".to_string(),
            workshop_directory: format!("C:\\ws\\{id}"),
            original_type: "image".to_string(),
            resolution: Some(res.to_string()),
            duration: None,
            file_size: 1000,
            asset_paths: None,
            has_preview: false,
            preview_video_path: None,
            folder_size: 2000,
            audio_paths: None,
            color_bucket: Some("blue".to_string()),
            visual_fingerprint: Some(CachedVisualFingerprint {
                d_hash,
                a_hash,
                mean_r: 100.0,
                mean_g: 100.0,
                mean_b: 100.0,
                luma_range: 80,
                exact_digest: None,
            }),
        };
        // A (d=0), B (d=0x3F = 6 bits), C (d=0x3FC = bits 2..9: dist(B,C)=4<=8, dist(A,C)=8.. wait 0x3FF has 10 bits from A and 4 bits from B)
        let items = vec![
            make_fp("A", "3840 × 2160", 0b00_0000_0000, 0),
            make_fp("B", "2560 × 1440", 0b00_0011_1111, 0),
            make_fp("C", "1920 × 1080", 0b11_1111_1111, 0),
        ];
        let res = analyze_duplicates(&items, |w| {
            Some(WallpaperPayloadItem {
                id: w.id.clone(),
                workshop_id: w.workshop_id.clone(),
                title: w.title.clone(),
                item_type: w.item_type.clone(),
                original_type: w.original_type.clone(),
                preview_url: None,
                preview_video_url: None,
                media_url: String::new(),
                asset_urls: Vec::new(),
                resolution: w.resolution.clone(),
                duration: None,
                file_size: w.file_size,
                folder_size: w.folder_size,
                audio_tracks: Vec::new(),
                has_audio: false,
                has_preview: false,
                has_scene_layers: false,
                asset_count: 1,
                content_rating: "Everyone".to_string(),
                tags: Vec::new(),
                customizable_count: 0,
                is_archived_offline: false,
                is_slimmable_mp4: false,
                color_bucket: w.color_bucket.clone(),
            })
        });
        assert_eq!(res.groups.len(), 1);
        let ids: Vec<&str> = res.groups[0].members.iter().map(|m| m.item.id.as_str()).collect();
        assert_eq!(ids, vec!["A", "B"]);
    }
}
