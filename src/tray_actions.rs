use crate::models::WallpaperItem;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static SEED_COUNTER: AtomicU64 = AtomicU64::new(1);

pub fn next_random_seed() -> u64 {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0x9E37_79B9_7F4A_7C15);
    let seq = SEED_COUNTER.fetch_add(1, Ordering::Relaxed);
    nanos ^ seq.wrapping_mul(0xBF58_476D_1CE4_E5B9)
}

pub fn pick_random_wallpaper<'a>(
    wallpapers: &'a HashMap<String, WallpaperItem>,
    favorite_ids: &[String],
    favorites_only: bool,
    last_id: Option<&str>,
    seed: u64,
) -> Option<&'a WallpaperItem> {
    let fav_set: HashSet<&str> = favorite_ids.iter().map(String::as_str).collect();
    let mut candidates: Vec<&WallpaperItem> = wallpapers
        .values()
        .filter(|w| !favorites_only || fav_set.contains(w.id.as_str()))
        .collect();

    if candidates.is_empty() {
        return None;
    }

    candidates.sort_by(|a, b| a.id.cmp(&b.id));

    if candidates.len() >= 2 {
        if let Some(prev) = last_id {
            let filtered: Vec<&WallpaperItem> = candidates
                .iter()
                .copied()
                .filter(|w| w.id != prev)
                .collect();
            if !filtered.is_empty() {
                candidates = filtered;
            }
        }
    }

    let idx = (seed as usize) % candidates.len();
    Some(candidates[idx])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fake_item(id: &str) -> WallpaperItem {
        WallpaperItem {
            id: id.to_string(),
            workshop_id: id.to_string(),
            title: format!("Title {id}"),
            item_type: "image".to_string(),
            preview_path: String::new(),
            source_path: String::new(),
            workshop_directory: String::new(),
            original_type: "image".to_string(),
            resolution: Some("1920x1080".to_string()),
            duration: None,
            file_size: 100,
            asset_paths: None,
            has_preview: false,
            preview_video_path: None,
            folder_size: 100,
            audio_paths: None,
            color_bucket: None,
            visual_fingerprint: None,
        }
    }

    #[test]
    fn empty_pool_returns_none() {
        let map = HashMap::new();
        assert!(pick_random_wallpaper(&map, &[], false, None, 0).is_none());
    }

    #[test]
    fn avoids_repeating_last_id_when_multiple_candidates_exist() {
        let mut map = HashMap::new();
        map.insert("a".into(), fake_item("a"));
        map.insert("b".into(), fake_item("b"));
        for seed in 0..8 {
            let picked = pick_random_wallpaper(&map, &[], false, Some("a"), seed).unwrap();
            assert_eq!(picked.id, "b");
        }
    }

    #[test]
    fn favorites_only_filters_candidates() {
        let mut map = HashMap::new();
        map.insert("a".into(), fake_item("a"));
        map.insert("b".into(), fake_item("b"));
        let favs = vec!["b".to_string()];
        for seed in 0..5 {
            let picked = pick_random_wallpaper(&map, &favs, true, None, seed).unwrap();
            assert_eq!(picked.id, "b");
        }
        assert!(pick_random_wallpaper(&map, &[], true, None, 0).is_none());
    }

    #[test]
    fn single_candidate_still_works_with_last_id() {
        let mut map = HashMap::new();
        map.insert("only".into(), fake_item("only"));
        let picked = pick_random_wallpaper(&map, &[], false, Some("only"), 3).unwrap();
        assert_eq!(picked.id, "only");
    }
}
