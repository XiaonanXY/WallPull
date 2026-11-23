use crate::models::{DuplicateGroupMemberPayload, DuplicateGroupPayload, WallpaperItem, WallpaperPayloadItem};
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
        .filter_map(|&item| compute_fingerprint(item))
        .collect();

    if valid.len() < 2 {
        return DuplicateScanResult {
            groups: Vec::new(),
            total_reclaimable_bytes: 0,
            scanned_count,
        };
    }

    let mut parent: Vec<usize> = (0..valid.len()).collect();
    for i in 0..valid.len() {
        for j in (i + 1)..valid.len() {
            if is_match(&valid[i], &valid[j]) {
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
        let mut members = Vec::with_capacity(cluster.len());
        let mut group_reclaimable = 0i64;

        for (i, cur) in cluster.iter().enumerate() {
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
                describe_match(anchor, cur)
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

fn is_match(a: &VisualFingerprint<'_>, b: &VisualFingerprint<'_>) -> bool {
    if a.exact_digest.is_some()
        && a.item.file_size > 0
        && a.item.file_size == b.item.file_size
        && a.exact_digest == b.exact_digest
    {
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

fn describe_match(anchor: &VisualFingerprint<'_>, cand: &VisualFingerprint<'_>) -> (i32, String) {
    if anchor.exact_digest.is_some()
        && anchor.item.file_size == cand.item.file_size
        && anchor.exact_digest == cand.exact_digest
    {
        return (100, "完全相同源文件".to_string());
    }
    let d_dist = (anchor.d_hash ^ cand.d_hash).count_ones() as f64;
    let sim = (100.0 - (d_dist / 64.0 * 100.0)).round().clamp(75.0, 99.0) as i32;
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

fn compute_fingerprint(item: &WallpaperItem) -> Option<VisualFingerprint<'_>> {
    let image_path = if Path::new(&item.preview_path).is_file() {
        &item.preview_path
    } else if item.item_type == "image" && Path::new(&item.source_path).is_file() {
        &item.source_path
    } else {
        return None;
    };

    let exact_digest = if Path::new(&item.source_path).is_file() {
        try_prefix_digest(Path::new(&item.source_path))
    } else {
        None
    };

    let img = image::open(image_path).ok()?;
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

    Some(VisualFingerprint {
        item,
        d_hash,
        a_hash,
        mean_r: sum_r / 64.0,
        mean_g: sum_g / 64.0,
        mean_b: sum_b / 64.0,
        luma_range: (max_l - min_l).round().clamp(0.0, 255.0) as u8,
        exact_digest,
    })
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
