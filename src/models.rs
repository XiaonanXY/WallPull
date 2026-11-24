use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::os::windows::fs::MetadataExt;
use std::path::{Path, PathBuf};

const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0400;

pub fn is_reparse_point(path: &Path) -> bool {
    let Ok(meta) = std::fs::symlink_metadata(path) else {
        return false;
    };
    meta.file_type().is_symlink() || (meta.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT) != 0
}

pub fn strip_verbatim_prefix(s: &str) -> String {
    let trimmed = s.trim();
    if let Some(rest) = trimmed.strip_prefix(r"\\?\UNC\") {
        format!(r"\\{rest}")
    } else if let Some(rest) = trimmed.strip_prefix(r"\\?\") {
        rest.to_string()
    } else {
        trimmed.to_string()
    }
}

pub fn clean_path_str(p: &Path) -> String {
    let abs = std::path::absolute(p).unwrap_or_else(|_| p.to_path_buf());
    strip_verbatim_prefix(&abs.to_string_lossy())
}

pub fn default_export_directory() -> String {
    if let Ok(profile) = std::env::var("USERPROFILE") {
        let desktop = PathBuf::from(&profile).join("Desktop");
        if desktop.exists() {
            return desktop.join("壁纸").to_string_lossy().into_owned();
        }
        return PathBuf::from(profile).join("壁纸").to_string_lossy().into_owned();
    }
    "壁纸".to_string()
}

fn default_true() -> bool {
    true
}
fn default_card_mode() -> String {
    "tilt".to_string()
}
fn default_spark_size() -> i64 {
    100
}
fn default_spark_color() -> String {
    "#7c3aed".to_string()
}
fn default_selection_border_mode() -> String {
    "snake".to_string()
}
fn default_hw_accel_mode() -> String {
    "gpu".to_string()
}
fn default_theme_mode() -> String {
    "light".to_string()
}
fn default_nav_style() -> String {
    "island".to_string()
}
fn default_toolbox_layout() -> String {
    "bento".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    #[serde(default)]
    pub workshop_root: Option<String>,
    #[serde(default = "default_export_directory")]
    pub export_directory: String,
    #[serde(default = "default_true")]
    pub auto_scan: bool,
    #[serde(default = "default_true")]
    pub parse_scenes: bool,
    #[serde(default = "default_true")]
    pub high_quality_video_previews: bool,
    #[serde(default = "default_true")]
    pub hover_video_preview: bool,
    #[serde(default = "default_card_mode")]
    pub card_mode: String,
    #[serde(default = "default_spark_size")]
    pub spark_size_percent: i64,
    #[serde(default = "default_spark_color")]
    pub spark_color: String,
    #[serde(default = "default_selection_border_mode")]
    pub selection_border_mode: String,
    #[serde(default = "default_hw_accel_mode")]
    pub hardware_acceleration_mode: String,
    #[serde(default = "default_theme_mode")]
    pub theme_mode: String,
    #[serde(default = "default_nav_style")]
    pub navigation_style: String,
    #[serde(default = "default_toolbox_layout")]
    pub toolbox_layout: String,
    #[serde(default)]
    pub close_to_tray: bool,
    #[serde(default)]
    pub show_archived_badge: bool,
    #[serde(default)]
    pub favorite_ids: Vec<String>,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            workshop_root: None,
            export_directory: default_export_directory(),
            auto_scan: true,
            parse_scenes: true,
            high_quality_video_previews: true,
            hover_video_preview: true,
            card_mode: default_card_mode(),
            spark_size_percent: default_spark_size(),
            spark_color: default_spark_color(),
            selection_border_mode: default_selection_border_mode(),
            hardware_acceleration_mode: default_hw_accel_mode(),
            theme_mode: default_theme_mode(),
            navigation_style: default_nav_style(),
            toolbox_layout: default_toolbox_layout(),
            close_to_tray: false,
            show_archived_badge: false,
            favorite_ids: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GpuAdapterInfo {
    pub name: String,
    pub memory_bytes: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct MediaInfo {
    pub width: i32,
    pub height: i32,
    pub duration_seconds: Option<f64>,
    pub file_size: i64,
}

impl MediaInfo {
    pub fn resolution(&self) -> Option<String> {
        if self.width > 0 && self.height > 0 {
            Some(format!("{} × {}", self.width, self.height))
        } else {
            None
        }
    }
}

#[derive(Debug, Clone)]
pub struct ResolvedMediaAsset {
    pub media_type: String,
    pub source_path: String,
    pub preview_path: String,
    pub media_info: MediaInfo,
    pub asset_paths: Vec<String>,
    pub preview_video_path: Option<String>,
    pub audio_paths: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CachedVisualFingerprint {
    pub d_hash: u64,
    pub a_hash: u64,
    pub mean_r: f32,
    pub mean_g: f32,
    pub mean_b: f32,
    pub luma_range: u8,
    #[serde(default)]
    pub exact_digest: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolboxProgressPayload {
    pub task_kind: String,
    pub message: String,
    pub current_index: usize,
    pub total_count: usize,
    pub file_percent: Option<f64>,
    pub overall_percent: Option<f64>,
    pub saved_bytes: Option<i64>,
    pub eta_seconds: Option<u64>,
    pub cancellable: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WallpaperItem {
    pub id: String,
    pub workshop_id: String,
    pub title: String,
    #[serde(rename = "type")]
    pub item_type: String,
    pub preview_path: String,
    pub source_path: String,
    pub workshop_directory: String,
    pub original_type: String,
    pub resolution: Option<String>,
    pub duration: Option<String>,
    pub file_size: i64,
    pub asset_paths: Option<Vec<String>>,
    pub has_preview: bool,
    pub preview_video_path: Option<String>,
    pub folder_size: i64,
    pub audio_paths: Option<Vec<String>>,
    #[serde(default)]
    pub color_bucket: Option<String>,
    #[serde(default)]
    pub visual_fingerprint: Option<CachedVisualFingerprint>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WallpaperScanEntry {
    pub workshop_id: String,
    pub title: String,
    pub state: String,
    pub message: String,
    #[serde(default)]
    pub item_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WallpaperScanReport {
    pub discovered_projects: usize,
    pub successful_projects: usize,
    pub failed_projects: usize,
    pub skipped_projects: usize,
    pub entries: Vec<WallpaperScanEntry>,
}

#[derive(Debug, Clone)]
pub struct WallpaperScanResult {
    pub items: Vec<WallpaperItem>,
    pub report: WallpaperScanReport,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WallpaperScanCacheProject {
    pub workshop_id: String,
    pub project_directory: String,
    pub type_override: Option<String>,
    pub items: Vec<WallpaperItem>,
    pub entry: WallpaperScanEntry,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WallpaperScanCache {
    pub version: i32,
    pub projects: Vec<WallpaperScanCacheProject>,
}

impl WallpaperScanCache {
    pub const CURRENT_VERSION: i32 = 6;
    pub fn empty() -> Self {
        Self {
            version: Self::CURRENT_VERSION,
            projects: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SceneLayerItem {
    pub index: usize,
    pub node_id: i32,
    pub name: String,
    pub group_key: String,
    pub group_title: String,
    pub role: String,
    pub default_visible: bool,
    pub has_puppet_mesh: bool,
    pub blend_mode: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SceneLayerGroup {
    pub key: String,
    pub title: String,
    pub role: String,
    pub layer_indices: Vec<usize>,
    pub default_visible: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SceneLayerManifest {
    pub canvas_width: i32,
    pub canvas_height: i32,
    pub layers: Vec<SceneLayerItem>,
    pub groups: Vec<SceneLayerGroup>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkshopPropertyOption {
    pub label: String,
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkshopUserProperty {
    pub key: String,
    pub label: String,
    #[serde(rename = "type")]
    pub prop_type: String,
    #[serde(rename = "value")]
    pub default_value: Value,
    pub options: Vec<WorkshopPropertyOption>,
    pub min: Option<f64>,
    pub max: Option<f64>,
}

#[derive(Debug, Clone)]
pub struct WorkshopExtraMetadata {
    pub content_rating: String,
    pub tags: Vec<String>,
    pub properties: Vec<WorkshopUserProperty>,
}

#[derive(Debug, Clone, Default)]
pub struct ItemPrecomputedMeta {
    pub has_scene_layers: bool,
    pub is_archived_offline: bool,
    pub extra: WorkshopExtraMetadata,
}

impl Default for WorkshopExtraMetadata {
    fn default() -> Self {
        Self {
            content_rating: "Everyone".to_string(),
            tags: Vec::new(),
            properties: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioTrackPayload {
    pub name: String,
    pub url: String,
    pub size: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WallpaperPayloadItem {
    pub id: String,
    pub workshop_id: String,
    pub title: String,
    #[serde(rename = "type")]
    pub item_type: String,
    pub original_type: String,
    pub preview_url: Option<String>,
    pub preview_video_url: Option<String>,
    pub media_url: String,
    pub asset_urls: Vec<String>,
    pub resolution: Option<String>,
    pub duration: Option<String>,
    pub file_size: i64,
    pub folder_size: i64,
    pub audio_tracks: Vec<AudioTrackPayload>,
    pub has_audio: bool,
    pub has_preview: bool,
    pub has_scene_layers: bool,
    pub asset_count: usize,
    pub content_rating: String,
    pub tags: Vec<String>,
    pub customizable_count: usize,
    pub is_archived_offline: bool,
    pub color_bucket: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DuplicateGroupMemberPayload {
    pub item: WallpaperPayloadItem,
    pub recommended_keep: bool,
    pub similarity_percent: i32,
    pub match_reason: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DuplicateGroupPayload {
    pub group_id: String,
    pub reclaimable_bytes: i64,
    pub members: Vec<DuplicateGroupMemberPayload>,
}
