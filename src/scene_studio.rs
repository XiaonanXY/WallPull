use crate::models::{SceneLayerGroup, SceneLayerItem, SceneLayerManifest};
use crate::tex::{
    DecodedTexRgba, encode_rgba_to_png_bytes, try_decode_to_rgba, write_rgba_to_png,
    write_rgba_to_png_with_mode,
};
use rayon::prelude::*;
use regex::Regex;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

#[derive(Debug, Clone, Copy)]
pub struct PkgSlice {
    pub abs_offset: u64,
    pub length: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BlendKind {
    Translucent,
    Opaque,
    Additive,
}

#[derive(Debug, Clone, Copy)]
struct WorldTransform {
    x: f32,
    y: f32,
    scale_x: f32,
    scale_y: f32,
    angle_z: f32,
    alpha: f32,
    color: (f32, f32, f32),
}

#[derive(Debug, Clone)]
struct SceneNode {
    id: i32,
    parent_id: Option<i32>,
    name: String,
    visible: bool,
    image_model_path: Option<String>,
    has_particle: bool,
    has_text: bool,
    origin_x: f32,
    origin_y: f32,
    scale_x: f32,
    scale_y: f32,
    angle_z: f32,
    size: Option<(f32, f32)>,
    alpha: f32,
    color: (f32, f32, f32),
}

#[derive(Debug, Clone)]
struct PuppetVertex {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
}

#[derive(Debug, Clone)]
struct PuppetMesh {
    vertices: Vec<PuppetVertex>,
    indices: Vec<u16>,
}

#[derive(Debug, Clone)]
struct ResolvedLayer {
    node_id: i32,
    root_ancestor_id: Option<i32>,
    display_name: String,
    default_visible: bool,
    is_workshop_effect: bool,
    tex_path: String,
    tex_slice: PkgSlice,
    puppet_mdl_path: Option<String>,
    puppet_slice: Option<PkgSlice>,
    blend_mode: BlendKind,
    explicit_size: Option<(f32, f32)>,
    world: WorldTransform,
}

pub struct SceneStudioSession {
    scene_package_path: PathBuf,
    canvas_width: i32,
    canvas_height: i32,
    layers: Vec<ResolvedLayer>,
    pub manifest: SceneLayerManifest,
    cache: Mutex<SessionRenderCache>,
}

struct SessionRenderCache {
    decoded_tex: HashMap<String, Arc<DecodedTexRgba>>,
    puppet_meshes: HashMap<String, Option<Arc<PuppetMesh>>>,
    cached_bytes: usize,
}

pub struct StudioRenderResult {
    pub width: i32,
    pub height: i32,
    pub has_pixels: bool,
}

const EFFECT_KEYWORDS: &[&str] = &[
    "flare", "lense", "lens", "glow", "bloom", "light", "ray", "particle", "ripple",
    "dust", "rain", "snow", "spark", "fog", "mist", "overlay", "光效", "炫光", "光晕",
    "光斑", "粒子", "水波", "雨滴", "飘雪", "滤镜",
];

const PART_SUFFIX_TOKENS: &[&str] = &[
    "发颌", "发头", "发下", "发左", "发右", "发间", "长发", "刘海", "呆毛", "蝴蝶结",
    "身体", "眉毛", "上眉", "眼眼", "右手", "左手", "右耳", "左耳", "阴影", "高光",
    "发", "头", "脸", "眼", "眉", "嘴", "口", "耳", "鼻", "手", "臂", "身", "胸", "腰",
    "腿", "脚", "裙", "衣", "领", "袖", "鞋", "袜", "饰",
    "hair", "head", "face", "body", "eye", "eyes", "brow", "bang", "arm", "hand",
    "leg", "foot", "dress", "ribbon", "ear", "mouth", "shadow", "back",
];

fn inspectable_cache() -> &'static Mutex<HashMap<PathBuf, (u128, bool)>> {
    static CACHE: OnceLock<Mutex<HashMap<PathBuf, (u128, bool)>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn trailing_digits_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)(?:副本|拷贝|copy|\d+|\s|\.)+$").expect("valid trailing regex")
    })
}

pub fn has_inspectable_2d_scene(workshop_dir: &str) -> bool {
    if workshop_dir.trim().is_empty() {
        return false;
    }
    let scene_pkg = Path::new(workshop_dir).join("scene.pkg");
    let Ok(meta) = std::fs::metadata(&scene_pkg) else {
        return false;
    };
    let mtime = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_nanos())
        .unwrap_or(0);

    if let Ok(guard) = inspectable_cache().lock() {
        if let Some((cached_mtime, res)) = guard.get(&scene_pkg) {
            if *cached_mtime == mtime {
                return *res;
            }
        }
    }

    let result = probe_inspectable_2d_scene(&scene_pkg);
    if let Ok(mut guard) = inspectable_cache().lock() {
        guard.insert(scene_pkg, (mtime, result));
    }
    result
}

fn probe_inspectable_2d_scene(scene_pkg: &Path) -> bool {
    let Ok(mut file) = File::open(scene_pkg) else {
        return false;
    };
    let Some(entry_map) = try_read_pkg_header(&mut file) else {
        return false;
    };
    try_parse_scene_header(&mut file, &entry_map, false).is_some()
}

pub fn open_studio_session(scene_package_path: &Path) -> Option<SceneStudioSession> {
    if !scene_package_path.is_file() {
        return None;
    }
    let mut file = File::open(scene_package_path).ok()?;
    let entry_map = try_read_pkg_header(&mut file)?;
    let (canvas_width, canvas_height, root_names, layers) =
        try_parse_scene_header(&mut file, &entry_map, true)?;
    let manifest = build_manifest(canvas_width, canvas_height, &layers, &root_names);
    Some(SceneStudioSession {
        scene_package_path: scene_package_path.to_path_buf(),
        canvas_width,
        canvas_height,
        layers,
        manifest,
        cache: Mutex::new(SessionRenderCache {
            decoded_tex: HashMap::new(),
            puppet_meshes: HashMap::new(),
            cached_bytes: 0,
        }),
    })
}

pub fn try_composite_2d_scene(
    pkg_file: &mut File,
    entry_map: &HashMap<String, PkgSlice>,
    output_png_path: &Path,
) -> bool {
    let Some((canvas_w, canvas_h, _, all_layers)) =
        try_parse_scene_header(pkg_file, entry_map, false)
    else {
        return false;
    };

    let visible: Vec<&ResolvedLayer> = all_layers.iter().filter(|l| l.default_visible).collect();
    if visible.len() < 2 {
        return false;
    }

    let mut canvas = vec![0u8; (canvas_w as usize) * (canvas_h as usize) * 4];
    let mut tex_cache: HashMap<String, Arc<DecodedTexRgba>> = HashMap::new();
    let mut puppet_cache: HashMap<String, Option<Arc<PuppetMesh>>> = HashMap::new();
    let mut drawn_count = 0usize;
    let mut has_true_overlay = false;

    for (idx, layer) in visible.iter().enumerate() {
        let tex_key = layer.tex_path.to_ascii_lowercase();
        let tex = if let Some(cached) = tex_cache.get(&tex_key) {
            cached.clone()
        } else {
            let Some(tex_bytes) = read_slice(pkg_file, layer.tex_slice) else {
                if idx == 0 {
                    return false;
                }
                continue;
            };
            let Some(decoded) = try_decode_to_rgba(&tex_bytes) else {
                if idx == 0 {
                    return false;
                }
                continue;
            };
            let arc = Arc::new(decoded);
            if arc.rgba.len() <= 16 * 1024 * 1024 {
                tex_cache.insert(tex_key, arc.clone());
            }
            arc
        };

        let puppet = if let (Some(mdl_slice), Some(mdl_path)) =
            (layer.puppet_slice, layer.puppet_mdl_path.as_deref())
        {
            let key = mdl_path.to_ascii_lowercase();
            if let Some(cached) = puppet_cache.get(&key) {
                cached.clone()
            } else {
                let parsed = read_slice(pkg_file, mdl_slice)
                    .and_then(|b| try_parse_puppet_mesh(&b))
                    .map(Arc::new);
                puppet_cache.insert(key, parsed.clone());
                parsed
            }
        } else {
            None
        };

        if render_single_layer(
            &mut canvas,
            canvas_w,
            canvas_h,
            1.0,
            layer,
            &tex,
            puppet.as_deref(),
            &mut has_true_overlay,
            drawn_count,
        ) {
            drawn_count += 1;
        }
    }

    if drawn_count < 2 || !has_true_overlay {
        return false;
    }

    for i in (3..canvas.len()).step_by(4) {
        canvas[i] = 255;
    }
    write_rgba_to_png(output_png_path, &canvas, canvas_w, canvas_w, canvas_h).is_ok()
}

impl SceneStudioSession {
    pub fn render_subset_to_png_bytes(
        &self,
        visible_layer_indices: &HashSet<usize>,
        max_dimension: i32,
        preserve_transparency: bool,
        trim_transparent_bounds: bool,
    ) -> Result<(Vec<u8>, StudioRenderResult), String> {
        let (rgba, width, height, has_pixels) = self.render_subset_rgba(
            visible_layer_indices,
            max_dimension,
            preserve_transparency,
            trim_transparent_bounds,
        )?;
        let fast_preview = max_dimension > 0;
        let bytes = encode_rgba_to_png_bytes(&rgba, width, width, height, fast_preview)
            .map_err(|e| format!("内存编码 PNG 失败：{e}"))?;
        Ok((
            bytes,
            StudioRenderResult {
                width,
                height,
                has_pixels,
            },
        ))
    }

    pub fn render_subset_to_png(
        &self,
        output_png_path: &Path,
        visible_layer_indices: &HashSet<usize>,
        max_dimension: i32,
        preserve_transparency: bool,
        trim_transparent_bounds: bool,
    ) -> Result<StudioRenderResult, String> {
        let (rgba, width, height, has_pixels) = self.render_subset_rgba(
            visible_layer_indices,
            max_dimension,
            preserve_transparency,
            trim_transparent_bounds,
        )?;
        let fast_preview = max_dimension > 0;
        write_rgba_to_png_with_mode(output_png_path, &rgba, width, width, height, fast_preview)
            .map_err(|e| format!("写入 PNG 失败：{e}"))?;
        Ok(StudioRenderResult {
            width,
            height,
            has_pixels,
        })
    }

    fn render_subset_rgba(
        &self,
        visible_layer_indices: &HashSet<usize>,
        max_dimension: i32,
        preserve_transparency: bool,
        trim_transparent_bounds: bool,
    ) -> Result<(Vec<u8>, i32, i32, bool), String> {
        let mut guard = self
            .cache
            .lock()
            .map_err(|_| "拆解台渲染锁异常。".to_string())?;

        let mut scale_factor = 1.0f32;
        let mut out_w = self.canvas_width;
        let mut out_h = self.canvas_height;
        let max_side = self.canvas_width.max(self.canvas_height);
        if max_dimension > 0 && max_side > max_dimension {
            scale_factor = max_dimension as f32 / max_side as f32;
            out_w = ((self.canvas_width as f32) * scale_factor).round().max(64.0) as i32;
            out_h = ((self.canvas_height as f32) * scale_factor).round().max(64.0) as i32;
        }

        // Collect all missing textures & puppet meshes across visible layers and decode in parallel
        let mut seen_tex_keys: HashSet<String> = HashSet::new();
        let mut missing_tex: Vec<(String, PkgSlice)> = Vec::new();
        let mut seen_puppet_keys: HashSet<String> = HashSet::new();
        let mut missing_puppets: Vec<(String, PkgSlice)> = Vec::new();

        for (i, layer) in self.layers.iter().enumerate() {
            if !visible_layer_indices.contains(&i) {
                continue;
            }
            let tex_key = layer.tex_path.to_ascii_lowercase();
            if !guard.decoded_tex.contains_key(&tex_key) && seen_tex_keys.insert(tex_key.clone()) {
                missing_tex.push((tex_key, layer.tex_slice));
            }
            if let (Some(mdl_slice), Some(mdl_path)) =
                (layer.puppet_slice, layer.puppet_mdl_path.as_deref())
            {
                let pkey = mdl_path.to_ascii_lowercase();
                if !guard.puppet_meshes.contains_key(&pkey) && seen_puppet_keys.insert(pkey.clone())
                {
                    missing_puppets.push((pkey, mdl_slice));
                }
            }
        }

        let mut local_tex: HashMap<String, Arc<DecodedTexRgba>> = HashMap::new();
        if !missing_tex.is_empty() || !missing_puppets.is_empty() {
            let mut f = File::open(&self.scene_package_path)
                .map_err(|e| format!("无法打开 scene.pkg：{e}"))?;

            let mut raw_tex_payloads: Vec<(String, Vec<u8>)> = Vec::with_capacity(missing_tex.len());
            for (k, slice) in missing_tex {
                if let Some(bytes) = read_slice(&mut f, slice) {
                    raw_tex_payloads.push((k, bytes));
                }
            }

            let mut raw_puppet_payloads: Vec<(String, Vec<u8>)> =
                Vec::with_capacity(missing_puppets.len());
            for (k, slice) in missing_puppets {
                if let Some(bytes) = read_slice(&mut f, slice) {
                    raw_puppet_payloads.push((k, bytes));
                }
            }
            drop(f);

            let decoded_tex_batch: Vec<(String, Arc<DecodedTexRgba>)> = raw_tex_payloads
                .into_par_iter()
                .filter_map(|(k, bytes)| try_decode_to_rgba(&bytes).map(|d| (k, Arc::new(d))))
                .collect();
            for (k, tex_arc) in decoded_tex_batch {
                let len = tex_arc.rgba.len();
                if guard.cached_bytes + len <= 512 * 1024 * 1024 {
                    guard.cached_bytes += len;
                    guard.decoded_tex.insert(k, tex_arc);
                } else {
                    local_tex.insert(k, tex_arc);
                }
            }

            let parsed_puppets: Vec<(String, Option<Arc<PuppetMesh>>)> = raw_puppet_payloads
                .into_par_iter()
                .map(|(k, bytes)| (k, try_parse_puppet_mesh(&bytes).map(Arc::new)))
                .collect();
            for (k, p) in parsed_puppets {
                guard.puppet_meshes.insert(k, p);
            }
        }

        let mut canvas = vec![0u8; (out_w as usize) * (out_h as usize) * 4];
        let mut dummy_overlay = false;
        let mut drawn_count = 0usize;

        for (i, layer) in self.layers.iter().enumerate() {
            if !visible_layer_indices.contains(&i) {
                continue;
            }
            let tex_key = layer.tex_path.to_ascii_lowercase();
            let Some(tex) = guard
                .decoded_tex
                .get(&tex_key)
                .or_else(|| local_tex.get(&tex_key))
                .cloned()
            else {
                continue;
            };

            let puppet = layer
                .puppet_mdl_path
                .as_deref()
                .and_then(|mdl| guard.puppet_meshes.get(&mdl.to_ascii_lowercase()))
                .and_then(|opt| opt.as_ref())
                .cloned();

            if render_single_layer(
                &mut canvas,
                out_w,
                out_h,
                scale_factor,
                layer,
                &tex,
                puppet.as_deref(),
                &mut dummy_overlay,
                drawn_count,
            ) {
                drawn_count += 1;
            }
        }
        drop(guard);

        if !preserve_transparency {
            for i in (3..canvas.len()).step_by(4) {
                canvas[i] = 255;
            }
        }

        if preserve_transparency && trim_transparent_bounds {
            if let Some((trimmed, tw, th)) = try_trim_transparent_canvas(&canvas, out_w, out_h, 16)
            {
                return Ok((trimmed, tw, th, true));
            }
            return Ok((canvas, out_w, out_h, false));
        }

        let has_pixels = drawn_count > 0 && has_any_visible_pixel(&canvas);
        Ok((canvas, out_w, out_h, has_pixels))
    }
}

pub fn try_read_pkg_header(pkg_file: &mut File) -> Option<HashMap<String, PkgSlice>> {
    let total_len = pkg_file.metadata().ok()?.len();
    if total_len < 16 {
        return None;
    }
    pkg_file.seek(SeekFrom::Start(0)).ok()?;

    let magic_len = read_le_i32(pkg_file)? as usize;
    if magic_len == 0 || magic_len > 64 {
        return None;
    }
    let mut magic_buf = vec![0u8; magic_len];
    pkg_file.read_exact(&mut magic_buf).ok()?;
    let magic = String::from_utf8_lossy(&magic_buf);
    if !magic.starts_with("PKGV") {
        return None;
    }

    let entry_count = read_le_i32(pkg_file)?;
    if entry_count <= 0 || entry_count > 50_000 {
        return None;
    }

    let mut raw_entries = Vec::with_capacity(entry_count as usize);
    for _ in 0..entry_count {
        let path_len = read_le_i32(pkg_file)? as usize;
        if path_len == 0 || path_len > 1024 {
            return None;
        }
        let mut pbuf = vec![0u8; path_len];
        pkg_file.read_exact(&mut pbuf).ok()?;
        let path = String::from_utf8_lossy(&pbuf).into_owned();
        let offset = read_le_i32(pkg_file)?;
        let length = read_le_i32(pkg_file)?;
        if offset >= 0 && length > 0 {
            raw_entries.push((path, offset as u64, length as usize));
        }
    }

    let data_start = pkg_file.stream_position().ok()?;
    let mut map = HashMap::with_capacity(raw_entries.len());
    for (path, rel_off, length) in raw_entries {
        let abs = data_start + rel_off;
        if abs >= data_start && abs + (length as u64) <= total_len {
            map.insert(
                path.to_ascii_lowercase(),
                PkgSlice {
                    abs_offset: abs,
                    length,
                },
            );
        }
    }

    if map.is_empty() {
        None
    } else {
        Some(map)
    }
}

fn read_le_i32(f: &mut File) -> Option<i32> {
    let mut buf = [0u8; 4];
    f.read_exact(&mut buf).ok()?;
    Some(i32::from_le_bytes(buf))
}

fn read_slice(f: &mut File, slice: PkgSlice) -> Option<Vec<u8>> {
    f.seek(SeekFrom::Start(slice.abs_offset)).ok()?;
    let mut buf = vec![0u8; slice.length];
    f.read_exact(&mut buf).ok()?;
    Some(buf)
}

fn try_parse_scene_header(
    pkg_file: &mut File,
    entry_map: &HashMap<String, PkgSlice>,
    include_workshop_models: bool,
) -> Option<(i32, i32, HashMap<i32, String>, Vec<ResolvedLayer>)> {
    let scene_slice = *entry_map.get("scene.json")?;
    if scene_slice.length == 0 || scene_slice.length > 16 * 1024 * 1024 {
        return None;
    }
    let scene_bytes = read_slice(pkg_file, scene_slice)?;
    let root: Value = serde_json::from_slice(&scene_bytes).ok()?;
    let ortho = root.get("general")?.get("orthogonalprojection")?;
    let canvas_w = ortho.get("width")?.as_i64()? as i32;
    let canvas_h = ortho.get("height")?.as_i64()? as i32;
    if !(256..=4096).contains(&canvas_w) || !(256..=4096).contains(&canvas_h) {
        return None;
    }
    let objects = root.get("objects")?.as_array()?;

    let mut raw_objects = Vec::with_capacity(objects.len());
    let mut by_id: HashMap<i32, SceneNode> = HashMap::new();
    let mut root_names: HashMap<i32, String> = HashMap::new();

    for obj in objects {
        let id = obj.get("id").and_then(|v| v.as_i64()).unwrap_or(-1) as i32;
        let parent_id = obj
            .get("parent")
            .and_then(|v| v.as_i64())
            .map(|p| p as i32);
        let name = obj
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let visible = read_bool(obj, "visible", true);
        let image_model_path = obj
            .get("image")
            .and_then(|v| v.as_str())
            .map(ToString::to_string);
        let has_particle = obj.get("particle").is_some();
        let has_text = obj.get("text").is_some();

        let (def_x, def_y) = if parent_id.is_none() {
            (canvas_w as f32 * 0.5, canvas_h as f32 * 0.5)
        } else {
            (0.0, 0.0)
        };
        let (ox, oy) = read_vec2(obj, "origin", def_x, def_y);
        let (sx, sy) = read_vec2(obj, "scale", 1.0, 1.0);
        let angle_z = read_vec3_z(obj, "angles", 0.0);
        let size = read_opt_vec2(obj, "size");
        let alpha = read_float(obj, "alpha", 1.0);
        let color = read_color3(obj, "color");

        let node = SceneNode {
            id,
            parent_id,
            name: name.clone(),
            visible,
            image_model_path,
            has_particle,
            has_text,
            origin_x: ox,
            origin_y: oy,
            scale_x: sx,
            scale_y: sy,
            angle_z,
            size,
            alpha,
            color,
        };
        if id >= 0 {
            if !name.trim().is_empty() {
                root_names.insert(id, name.trim().to_string());
            }
            by_id.insert(id, node.clone());
        }
        raw_objects.push(node);
    }

    let mut layers = Vec::new();
    for node in &raw_objects {
        if node.has_particle || node.has_text {
            continue;
        }
        let Some(model_path) = node.image_model_path.as_deref() else {
            continue;
        };
        let lower_model = model_path.to_ascii_lowercase();
        if lower_model.is_empty()
            || lower_model.starts_with("models/util/")
            || lower_model.starts_with("models/solid_instance_")
        {
            continue;
        }
        let is_workshop_effect = lower_model.starts_with("models/workshop/");
        if is_workshop_effect && !include_workshop_models {
            continue;
        }

        let Some((tex_path, puppet_mdl_path, blend_mode)) =
            try_resolve_tex_path(pkg_file, entry_map, &lower_model)
        else {
            continue;
        };
        let Some(&tex_slice) = entry_map.get(&tex_path.to_ascii_lowercase()) else {
            continue;
        };
        if tex_slice.length == 0 || tex_slice.length > 128 * 1024 * 1024 {
            continue;
        }

        let puppet_slice = puppet_mdl_path.as_deref().and_then(|mdl| {
            let s = entry_map.get(&mdl.to_ascii_lowercase()).copied()?;
            if s.length > 64 && s.length <= 16 * 1024 * 1024 {
                Some(s)
            } else {
                None
            }
        });

        let world = compute_world_transform(node, &by_id);
        let default_visible = is_node_visible(node, &by_id);
        if world.alpha <= 0.004 {
            continue;
        }

        let display_name = if !node.name.trim().is_empty() {
            node.name.trim().to_string()
        } else {
            Path::new(model_path)
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("layer")
                .to_string()
        };
        let root_ancestor_id = find_root_ancestor_id(node, &by_id);

        layers.push(ResolvedLayer {
            node_id: node.id,
            root_ancestor_id,
            display_name,
            default_visible,
            is_workshop_effect,
            tex_path,
            tex_slice,
            puppet_mdl_path,
            puppet_slice,
            blend_mode,
            explicit_size: node.size,
            world,
        });
    }

    if layers.len() >= 2 {
        Some((canvas_w, canvas_h, root_names, layers))
    } else {
        None
    }
}

fn find_root_ancestor_id(node: &SceneNode, by_id: &HashMap<i32, SceneNode>) -> Option<i32> {
    let mut root_id = None;
    let mut cur = node;
    for _ in 0..16 {
        let Some(pid) = cur.parent_id else { break };
        let Some(parent) = by_id.get(&pid) else {
            break;
        };
        root_id = Some(parent.id);
        cur = parent;
    }
    root_id
}

fn build_manifest(
    canvas_w: i32,
    canvas_h: i32,
    layers: &[ResolvedLayer],
    root_names: &HashMap<i32, String>,
) -> SceneLayerManifest {
    let stems: Vec<Option<String>> = layers
        .iter()
        .map(|l| extract_subject_stem(&l.display_name))
        .collect();
    let mut stem_counts: HashMap<String, usize> = HashMap::new();
    for stem in stems.iter().flatten() {
        if !is_background_name(stem) {
            *stem_counts.entry(stem.to_ascii_lowercase()).or_default() += 1;
        }
    }

    let mut items = Vec::with_capacity(layers.len());
    let mut group_meta: HashMap<String, (String, String, Vec<usize>, bool)> = HashMap::new();
    let mut group_order = Vec::new();

    for (i, layer) in layers.iter().enumerate() {
        let is_full_base =
            i == 0 && layer.puppet_slice.is_none() && is_likely_background(layer, canvas_w, canvas_h);
        let stem = stems[i].as_deref();
        let shared_stem = stem
            .map(|s| stem_counts.get(&s.to_ascii_lowercase()).copied().unwrap_or(0) >= 2)
            .unwrap_or(false);

        let (role, group_key, group_title) =
            if is_full_base || (!shared_stem && is_background_name(&layer.display_name)) {
                (
                    "background".to_string(),
                    "background".to_string(),
                    if layer.display_name.trim().is_empty() {
                        "背景底图".to_string()
                    } else {
                        layer.display_name.clone()
                    },
                )
            } else if layer.is_workshop_effect
                || (layer.blend_mode == BlendKind::Additive
                    && !shared_stem
                    && layer.root_ancestor_id.is_none())
            {
                (
                    "effect".to_string(),
                    "effects".to_string(),
                    "光效与氛围图层".to_string(),
                )
            } else if shared_stem {
                let s = stem.unwrap_or("角色");
                (
                    "character".to_string(),
                    format!("char:{s}"),
                    s.to_string(),
                )
            } else if let Some(ancestor) = layer
                .root_ancestor_id
                .and_then(|rid| root_names.get(&rid))
                .filter(|s| !s.trim().is_empty())
            {
                let rid = layer.root_ancestor_id.unwrap();
                let r = if is_effect_name(ancestor) {
                    "effect"
                } else {
                    "subject"
                };
                (r.to_string(), format!("parent:{rid}"), ancestor.clone())
            } else if is_effect_name(&layer.display_name) || layer.blend_mode == BlendKind::Additive
            {
                (
                    "effect".to_string(),
                    "effects".to_string(),
                    "光效与氛围图层".to_string(),
                )
            } else {
                (
                    "subject".to_string(),
                    format!("single:{i}"),
                    if layer.display_name.trim().is_empty() {
                        format!("图层 {}", i + 1)
                    } else {
                        layer.display_name.clone()
                    },
                )
            };

        if !group_meta.contains_key(&group_key) {
            group_order.push(group_key.clone());
            group_meta.insert(
                group_key.clone(),
                (group_title.clone(), role.clone(), Vec::new(), false),
            );
        }
        if let Some(meta) = group_meta.get_mut(&group_key) {
            meta.2.push(i);
            if layer.default_visible {
                meta.3 = true;
            }
        }

        let blend_name = match layer.blend_mode {
            BlendKind::Opaque => "opaque",
            BlendKind::Additive => "additive",
            BlendKind::Translucent => "translucent",
        };
        items.push(SceneLayerItem {
            index: i,
            node_id: layer.node_id,
            name: layer.display_name.clone(),
            group_key,
            group_title,
            role,
            default_visible: layer.default_visible,
            has_puppet_mesh: layer.puppet_slice.is_some(),
            blend_mode: blend_name.to_string(),
        });
    }

    let groups = group_order
        .into_iter()
        .filter_map(|key| {
            let (title, role, layer_indices, default_visible) = group_meta.remove(&key)?;
            Some(SceneLayerGroup {
                key,
                title,
                role,
                layer_indices,
                default_visible,
            })
        })
        .collect();

    SceneLayerManifest {
        canvas_width: canvas_w,
        canvas_height: canvas_h,
        layers: items,
        groups,
    }
}

fn is_likely_background(layer: &ResolvedLayer, canvas_w: i32, canvas_h: i32) -> bool {
    if is_background_name(&layer.display_name) {
        return true;
    }
    if let Some((w, h)) = layer.explicit_size {
        let dw = w * layer.world.scale_x.abs();
        let dh = h * layer.world.scale_y.abs();
        return dw >= (canvas_w as f32) * 0.92 && dh >= (canvas_h as f32) * 0.92;
    }
    (layer.world.x - (canvas_w as f32) * 0.5).abs() < 12.0
        && (layer.world.y - (canvas_h as f32) * 0.5).abs() < 12.0
        && layer.blend_mode == BlendKind::Opaque
}

fn is_background_name(name: &str) -> bool {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return false;
    }
    let clean = trailing_digits_regex().replace(trimmed, "").to_lowercase();
    if clean.contains("底图") || clean.contains("背景") || clean.contains("background") {
        return true;
    }
    clean
        .split(['_', '-', ' ', '.', '/'])
        .any(|tok| matches!(tok, "bg" | "bac" | "bacbcac" | "sky" | "wall" | "scene_bg"))
}

fn is_effect_name(name: &str) -> bool {
    let lower = name.to_lowercase();
    EFFECT_KEYWORDS.iter().any(|kw| lower.contains(kw))
}

pub fn extract_subject_stem(raw_name: &str) -> Option<String> {
    let trimmed = raw_name.trim();
    if trimmed.is_empty() {
        return None;
    }
    let cleaned = trailing_digits_regex().replace(trimmed, "");
    let name = cleaned.trim();
    if name.chars().count() < 3 {
        return None;
    }

    if let Some(sep_idx) = name.find(['_', '-', ' ', '.', '/']) {
        let left = name[..sep_idx].trim();
        if left.chars().count() >= 2 {
            let rest = name[sep_idx + 1..].to_lowercase();
            if PART_SUFFIX_TOKENS
                .iter()
                .any(|tok| rest.contains(&tok.to_lowercase()))
            {
                return Some(left.to_string());
            }
        }
    }

    let name_lower = name.to_lowercase();
    let char_indices: Vec<(usize, char)> = name.char_indices().collect();
    for pos in 2..char_indices.len() {
        let byte_idx = char_indices[pos].0;
        let tail = &name_lower[byte_idx..];
        for &tok in PART_SUFFIX_TOKENS {
            let tok_lower = tok.to_lowercase();
            if tail.starts_with(&tok_lower) {
                let prev_char = char_indices[pos - 1].1;
                if tok.as_bytes()[0] < 128 && prev_char.is_ascii_alphabetic() {
                    continue;
                }
                let stem = name[..byte_idx].trim_end_matches(['_', '-', ' ', '.']);
                if stem.chars().count() >= 2 {
                    return Some(stem.to_string());
                }
            }
        }
    }
    None
}

#[allow(clippy::too_many_arguments)]
fn render_single_layer(
    canvas: &mut [u8],
    canvas_w: i32,
    canvas_h: i32,
    scale_factor: f32,
    layer: &ResolvedLayer,
    tex: &DecodedTexRgba,
    puppet_mesh: Option<&PuppetMesh>,
    has_true_overlay: &mut bool,
    drawn_count: usize,
) -> bool {
    if let Some(mesh) = puppet_mesh {
        if drawn_count > 0 {
            *has_true_overlay = true;
        }
        blit_puppet_mesh(
            canvas,
            canvas_w,
            canvas_h,
            scale_factor,
            tex,
            mesh,
            layer.world,
            layer.blend_mode,
        );
        return true;
    }

    let (base_w, base_h) = layer
        .explicit_size
        .unwrap_or((tex.width as f32, tex.height as f32));
    let draw_w = base_w * layer.world.scale_x.abs() * scale_factor;
    let draw_h = base_h * layer.world.scale_y.abs() * scale_factor;
    if draw_w < 1.0 || draw_h < 1.0 {
        return false;
    }

    if drawn_count > 0 && !*has_true_overlay {
        if layer.blend_mode == BlendKind::Additive
            || layer.world.alpha < 0.995
            || draw_w < (canvas_w as f32) * 0.98
            || draw_h < (canvas_h as f32) * 0.98
            || (layer.blend_mode != BlendKind::Opaque && has_transparent_pixels(tex))
        {
            *has_true_overlay = true;
        }
    }

    blit_layer(
        canvas,
        canvas_w,
        canvas_h,
        tex,
        layer.world.x * scale_factor,
        (canvas_h as f32) - layer.world.y * scale_factor,
        draw_w,
        draw_h,
        layer.world.scale_x < 0.0,
        layer.world.scale_y < 0.0,
        layer.world.angle_z,
        layer.world.alpha,
        layer.world.color,
        layer.blend_mode,
    );
    true
}

fn has_transparent_pixels(tex: &DecodedTexRgba) -> bool {
    let sx = (tex.width / 64).max(1) as usize;
    let sy = (tex.height / 64).max(1) as usize;
    let w = tex.width as usize;
    let h = tex.height as usize;
    let stride = tex.stride_width as usize;
    for y in (0..h).step_by(sy) {
        let row = y * stride * 4;
        for x in (0..w).step_by(sx) {
            if tex.rgba[row + x * 4 + 3] < 250 {
                return true;
            }
        }
    }
    false
}

fn has_any_visible_pixel(canvas: &[u8]) -> bool {
    canvas.iter().skip(3).step_by(4).any(|&a| a > 2)
}

fn try_trim_transparent_canvas(
    canvas: &[u8],
    width: i32,
    height: i32,
    padding: i32,
) -> Option<(Vec<u8>, i32, i32)> {
    let w = width as usize;
    let h = height as usize;
    let mut min_x = width;
    let mut min_y = height;
    let mut max_x = -1;
    let mut max_y = -1;

    for y in 0..h {
        let row_off = y * w * 4;
        for x in 0..w {
            if canvas[row_off + x * 4 + 3] >= 4 {
                let xi = x as i32;
                let yi = y as i32;
                if xi < min_x {
                    min_x = xi;
                }
                if xi > max_x {
                    max_x = xi;
                }
                if yi < min_y {
                    min_y = yi;
                }
                if yi > max_y {
                    max_y = yi;
                }
            }
        }
    }

    if max_x < min_x || max_y < min_y {
        return None;
    }

    let crop_left = (min_x - padding).max(0);
    let crop_top = (min_y - padding).max(0);
    let crop_right = (max_x + padding).min(width - 1);
    let crop_bottom = (max_y + padding).min(height - 1);
    let trim_w = crop_right - crop_left + 1;
    let trim_h = crop_bottom - crop_top + 1;

    let mut trimmed = vec![0u8; (trim_w as usize) * (trim_h as usize) * 4];
    let row_bytes = (trim_w as usize) * 4;
    for y in 0..(trim_h as usize) {
        let src_off = (((crop_top as usize) + y) * w + (crop_left as usize)) * 4;
        trimmed[y * row_bytes..(y + 1) * row_bytes]
            .copy_from_slice(&canvas[src_off..src_off + row_bytes]);
    }
    Some((trimmed, trim_w, trim_h))
}

#[allow(clippy::too_many_arguments)]
fn blit_layer_row(
    row_slice: &mut [u8],
    py: i32,
    min_x: i32,
    max_x: i32,
    tex: &DecodedTexRgba,
    center_x: f32,
    center_y: f32,
    draw_w: f32,
    draw_h: f32,
    flip_x: bool,
    flip_y: bool,
    cos: f32,
    sin: f32,
    half_w: f32,
    half_h: f32,
    inv_scale_x: f32,
    inv_scale_y: f32,
    src_max_x: i32,
    src_max_y: i32,
    layer_alpha: f32,
    tint: (f32, f32, f32),
    blend: BlendKind,
) {
    let dy = (py as f32 + 0.5) - center_y;
    for px in min_x..=max_x {
        let dx = (px as f32 + 0.5) - center_x;
        let local_x = dx * cos + dy * sin + half_w;
        let local_y = -dx * sin + dy * cos + half_h;
        if local_x < 0.0 || local_x >= draw_w || local_y < 0.0 || local_y >= draw_h {
            continue;
        }
        let mut u = local_x * inv_scale_x - 0.5;
        let mut v = local_y * inv_scale_y - 0.5;
        if flip_x {
            u = (src_max_x as f32) - u;
        }
        if flip_y {
            v = (src_max_y as f32) - v;
        }
        let (sr, sg, sb, sa) =
            sample_bilinear(&tex.rgba, tex.stride_width, src_max_x, src_max_y, u, v);
        let effective_alpha = sa * layer_alpha;
        if effective_alpha <= 0.5 && blend != BlendKind::Opaque {
            continue;
        }
        composite_pixel(
            row_slice,
            (px as usize) * 4,
            sr * tint.0,
            sg * tint.1,
            sb * tint.2,
            effective_alpha,
            blend,
        );
    }
}

#[allow(clippy::too_many_arguments)]
fn blit_layer(
    canvas: &mut [u8],
    canvas_w: i32,
    canvas_h: i32,
    tex: &DecodedTexRgba,
    center_x: f32,
    center_y: f32,
    draw_w: f32,
    draw_h: f32,
    flip_x: bool,
    flip_y: bool,
    angle_z_deg: f32,
    layer_alpha: f32,
    tint: (f32, f32, f32),
    blend: BlendKind,
) {
    let rad = -angle_z_deg.to_radians();
    let cos = rad.cos();
    let sin = rad.sin();
    let half_w = draw_w * 0.5;
    let half_h = draw_h * 0.5;

    let bound_half_w = (half_w * cos).abs() + (half_h * sin).abs();
    let bound_half_h = (half_w * sin).abs() + (half_h * cos).abs();

    let min_x = ((center_x - bound_half_w).floor() as i32).max(0);
    let max_x = ((center_x + bound_half_w).ceil() as i32).min(canvas_w - 1);
    let min_y = ((center_y - bound_half_h).floor() as i32).max(0);
    let max_y = ((center_y + bound_half_h).ceil() as i32).min(canvas_h - 1);
    if min_x > max_x || min_y > max_y {
        return;
    }

    let inv_scale_x = (tex.width as f32) / draw_w;
    let inv_scale_y = (tex.height as f32) / draw_h;
    let src_max_x = tex.width - 1;
    let src_max_y = tex.height - 1;

    let row_stride = (canvas_w as usize) * 4;
    let start_off = (min_y as usize) * row_stride;
    let end_off = ((max_y as usize) + 1) * row_stride;
    let band = &mut canvas[start_off..end_off];
    let band_rows = (max_y - min_y + 1) as usize;

    if band_rows >= 16 && (max_x - min_x + 1) >= 64 {
        band.par_chunks_exact_mut(row_stride)
            .enumerate()
            .for_each(|(rel_y, row_slice)| {
                let py = min_y + (rel_y as i32);
                blit_layer_row(
                    row_slice, py, min_x, max_x, tex, center_x, center_y, draw_w, draw_h,
                    flip_x, flip_y, cos, sin, half_w, half_h, inv_scale_x, inv_scale_y,
                    src_max_x, src_max_y, layer_alpha, tint, blend,
                );
            });
    } else {
        for (rel_y, row_slice) in band.chunks_exact_mut(row_stride).enumerate() {
            let py = min_y + (rel_y as i32);
            blit_layer_row(
                row_slice, py, min_x, max_x, tex, center_x, center_y, draw_w, draw_h,
                flip_x, flip_y, cos, sin, half_w, half_h, inv_scale_x, inv_scale_y,
                src_max_x, src_max_y, layer_alpha, tint, blend,
            );
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn blit_puppet_mesh(
    canvas: &mut [u8],
    canvas_w: i32,
    canvas_h: i32,
    scale_factor: f32,
    tex: &DecodedTexRgba,
    mesh: &PuppetMesh,
    world: WorldTransform,
    blend: BlendKind,
) {
    let rad = world.angle_z.to_radians();
    let cos = rad.cos();
    let sin = rad.sin();
    let verts = &mesh.vertices;
    let mut screen_x_fp = Vec::with_capacity(verts.len());
    let mut screen_y_fp = Vec::with_capacity(verts.len());

    for v in verts {
        let sx = v.x * world.scale_x;
        let sy = v.y * world.scale_y;
        let wx = (world.x + sx * cos - sy * sin) * scale_factor;
        let wy = (world.y + sx * sin + sy * cos) * scale_factor;
        let py = (canvas_h as f32) - wy;
        screen_x_fp.push((wx * 16.0).round() as i32);
        screen_y_fp.push((py * 16.0).round() as i32);
    }

    let src_max_x = tex.width - 1;
    let src_max_y = tex.height - 1;
    let tex_w = tex.width as f32;
    let tex_h = tex.height as f32;

    for tri in mesh.indices.chunks_exact(3) {
        let (i0, i1, i2) = (tri[0] as usize, tri[1] as usize, tri[2] as usize);
        let (x0, y0) = (screen_x_fp[i0], screen_y_fp[i0]);
        let (mut x1, mut y1) = (screen_x_fp[i1], screen_y_fp[i1]);
        let (mut x2, mut y2) = (screen_x_fp[i2], screen_y_fp[i2]);

        let mut area = ((x1 - x0) as i64) * ((y2 - y0) as i64)
            - ((y1 - y0) as i64) * ((x2 - x0) as i64);
        if area == 0 {
            continue;
        }
        let u0 = verts[i0].u;
        let v0 = verts[i0].v;
        let (mut u1, mut v1) = (verts[i1].u, verts[i1].v);
        let (mut u2, mut v2) = (verts[i2].u, verts[i2].v);

        if area < 0 {
            std::mem::swap(&mut x1, &mut x2);
            std::mem::swap(&mut y1, &mut y2);
            std::mem::swap(&mut u1, &mut u2);
            std::mem::swap(&mut v1, &mut v2);
            area = -area;
        }

        let min_px = ((x0.min(x1).min(x2) - 8) >> 4).max(0);
        let max_px = ((x0.max(x1).max(x2) + 8) >> 4).min(canvas_w - 1);
        let min_py = ((y0.min(y1).min(y2) - 8) >> 4).max(0);
        let max_py = ((y0.max(y1).max(y2) + 8) >> 4).min(canvas_h - 1);
        if min_px > max_px || min_py > max_py {
            continue;
        }

        let (dx01, dy01) = (x1 - x0, y1 - y0);
        let (dx12, dy12) = (x2 - x1, y2 - y1);
        let (dx20, dy20) = (x0 - x2, y0 - y2);

        let bias0 = if dy01 < 0 || (dy01 == 0 && dx01 > 0) { 0 } else { -1 };
        let bias1 = if dy12 < 0 || (dy12 == 0 && dx12 > 0) { 0 } else { -1 };
        let bias2 = if dy20 < 0 || (dy20 == 0 && dx20 > 0) { 0 } else { -1 };
        let inv_area = 1.0f32 / (area as f32);

        for py in min_py..=max_py {
            let sy = (py << 4) + 8;
            let row_off = (py as usize) * (canvas_w as usize) * 4;
            for px in min_px..=max_px {
                let sx = (px << 4) + 8;
                let e0 = (dx01 as i64) * ((sy - y0) as i64) - (dy01 as i64) * ((sx - x0) as i64);
                let e1 = (dx12 as i64) * ((sy - y1) as i64) - (dy12 as i64) * ((sx - x1) as i64);
                let e2 = (dx20 as i64) * ((sy - y2) as i64) - (dy20 as i64) * ((sx - x2) as i64);
                if e0 + bias0 < 0 || e1 + bias1 < 0 || e2 + bias2 < 0 {
                    continue;
                }

                let w0 = (e1 as f32) * inv_area;
                let w1 = (e2 as f32) * inv_area;
                let w2 = 1.0 - w0 - w1;
                let u = (w0 * u0 + w1 * u1 + w2 * u2) * tex_w - 0.5;
                let v = (w0 * v0 + w1 * v1 + w2 * v2) * tex_h - 0.5;

                let (sr, sg, sb, sa) =
                    sample_bilinear(&tex.rgba, tex.stride_width, src_max_x, src_max_y, u, v);
                let effective_alpha = sa * world.alpha;
                if effective_alpha <= 0.5 && blend != BlendKind::Opaque {
                    continue;
                }
                composite_pixel(
                    canvas,
                    row_off + (px as usize) * 4,
                    sr * world.color.0,
                    sg * world.color.1,
                    sb * world.color.2,
                    effective_alpha,
                    blend,
                );
            }
        }
    }
}

#[inline]
fn clamp_byte(v: f32) -> u8 {
    if v <= 0.0 {
        0
    } else if v >= 255.0 {
        255
    } else {
        (v + 0.5) as u8
    }
}

fn composite_pixel(
    canvas: &mut [u8],
    dst_idx: usize,
    sr: f32,
    sg: f32,
    sb: f32,
    effective_alpha: f32,
    blend: BlendKind,
) {
    match blend {
        BlendKind::Opaque => {
            canvas[dst_idx] = clamp_byte(sr);
            canvas[dst_idx + 1] = clamp_byte(sg);
            canvas[dst_idx + 2] = clamp_byte(sb);
            canvas[dst_idx + 3] = 255;
        }
        BlendKind::Additive => {
            let factor = effective_alpha / 255.0;
            let dst_a = canvas[dst_idx + 3];
            if dst_a == 255 {
                canvas[dst_idx] = clamp_byte(canvas[dst_idx] as f32 + sr * factor);
                canvas[dst_idx + 1] = clamp_byte(canvas[dst_idx + 1] as f32 + sg * factor);
                canvas[dst_idx + 2] = clamp_byte(canvas[dst_idx + 2] as f32 + sb * factor);
                return;
            }
            let da = dst_a as f32 / 255.0;
            let add_a = factor * (sr.max(sg).max(sb) / 255.0);
            let out_a = (da + add_a * (1.0 - da)).clamp(0.0, 1.0);
            if out_a <= 0.002 {
                return;
            }
            canvas[dst_idx] = clamp_byte((canvas[dst_idx] as f32 * da + sr * factor) / out_a);
            canvas[dst_idx + 1] = clamp_byte((canvas[dst_idx + 1] as f32 * da + sg * factor) / out_a);
            canvas[dst_idx + 2] = clamp_byte((canvas[dst_idx + 2] as f32 * da + sb * factor) / out_a);
            canvas[dst_idx + 3] = clamp_byte(out_a * 255.0);
        }
        BlendKind::Translucent => {
            let sa = effective_alpha / 255.0;
            if sa <= 0.001 {
                return;
            }
            let dst_a = canvas[dst_idx + 3];
            if dst_a == 255 {
                let inv_a = 1.0 - sa;
                canvas[dst_idx] = clamp_byte(sr * sa + (canvas[dst_idx] as f32) * inv_a);
                canvas[dst_idx + 1] = clamp_byte(sg * sa + (canvas[dst_idx + 1] as f32) * inv_a);
                canvas[dst_idx + 2] = clamp_byte(sb * sa + (canvas[dst_idx + 2] as f32) * inv_a);
                return;
            }
            if dst_a == 0 {
                canvas[dst_idx] = clamp_byte(sr);
                canvas[dst_idx + 1] = clamp_byte(sg);
                canvas[dst_idx + 2] = clamp_byte(sb);
                canvas[dst_idx + 3] = clamp_byte(effective_alpha);
                return;
            }
            let da = dst_a as f32 / 255.0;
            let out_a = sa + da * (1.0 - sa);
            let w_src = sa / out_a;
            let w_dst = (da * (1.0 - sa)) / out_a;
            canvas[dst_idx] = clamp_byte(sr * w_src + (canvas[dst_idx] as f32) * w_dst);
            canvas[dst_idx + 1] = clamp_byte(sg * w_src + (canvas[dst_idx + 1] as f32) * w_dst);
            canvas[dst_idx + 2] = clamp_byte(sb * w_src + (canvas[dst_idx + 2] as f32) * w_dst);
            canvas[dst_idx + 3] = clamp_byte(out_a * 255.0);
        }
    }
}

fn sample_bilinear(
    rgba: &[u8],
    stride_width: i32,
    max_x: i32,
    max_y: i32,
    u: f32,
    v: f32,
) -> (f32, f32, f32, f32) {
    let x0 = (u.floor() as i32).clamp(0, max_x) as usize;
    let y0 = (v.floor() as i32).clamp(0, max_y) as usize;
    let x1 = (x0 + 1).min(max_x as usize);
    let y1 = (y0 + 1).min(max_y as usize);
    let fx = (u - x0 as f32).clamp(0.0, 1.0);
    let fy = (v - y0 as f32).clamp(0.0, 1.0);
    let sw = stride_width as usize;

    let i00 = (y0 * sw + x0) * 4;
    let i10 = (y0 * sw + x1) * 4;
    let i01 = (y1 * sw + x0) * 4;
    let i11 = (y1 * sw + x1) * 4;

    let w00 = (1.0 - fx) * (1.0 - fy);
    let w10 = fx * (1.0 - fy);
    let w01 = (1.0 - fx) * fy;
    let w11 = fx * fy;

    let a00 = rgba[i00 + 3] as f32;
    let a10 = rgba[i10 + 3] as f32;
    let a01 = rgba[i01 + 3] as f32;
    let a11 = rgba[i11 + 3] as f32;
    let a = a00 * w00 + a10 * w10 + a01 * w01 + a11 * w11;
    if a <= 0.01 {
        return (0.0, 0.0, 0.0, 0.0);
    }

    let pr = (rgba[i00] as f32) * a00 * w00
        + (rgba[i10] as f32) * a10 * w10
        + (rgba[i01] as f32) * a01 * w01
        + (rgba[i11] as f32) * a11 * w11;
    let pg = (rgba[i00 + 1] as f32) * a00 * w00
        + (rgba[i10 + 1] as f32) * a10 * w10
        + (rgba[i01 + 1] as f32) * a01 * w01
        + (rgba[i11 + 1] as f32) * a11 * w11;
    let pb = (rgba[i00 + 2] as f32) * a00 * w00
        + (rgba[i10 + 2] as f32) * a10 * w10
        + (rgba[i01 + 2] as f32) * a01 * w01
        + (rgba[i11 + 2] as f32) * a11 * w11;
    (pr / a, pg / a, pb / a, a)
}

fn try_parse_puppet_mesh(mdl: &[u8]) -> Option<PuppetMesh> {
    if mdl.len() < 64 || &mdl[0..4] != b"MDLV" {
        return None;
    }
    let mut pos = 0usize;
    while pos < mdl.len() && mdl[pos] != 0 {
        pos += 1;
    }
    pos += 1;
    if pos + 12 >= mdl.len() {
        return None;
    }
    let mat_count = i32::from_le_bytes(mdl[pos + 8..pos + 12].try_into().ok()?);
    pos += 12;
    if mat_count <= 0 || mat_count > 32 {
        return None;
    }
    for _ in 0..mat_count {
        while pos < mdl.len() && mdl[pos] != 0 {
            pos += 1;
        }
        pos += 1;
        if pos >= mdl.len() {
            return None;
        }
    }
    if pos + 36 > mdl.len() {
        return None;
    }

    let v_flags_off = pos + 28;
    let v_flags = u32::from_le_bytes(mdl[v_flags_off..v_flags_off + 4].try_into().ok()?);
    let v_byte_len = i32::from_le_bytes(mdl[v_flags_off + 4..v_flags_off + 8].try_into().ok()?) as usize;
    let v_data_off = v_flags_off + 8;

    let (stride, uv_offset) = resolve_mdl_vertex_layout(v_flags, v_byte_len);
    if stride == 0
        || v_byte_len == 0
        || v_byte_len % stride != 0
        || v_data_off + v_byte_len + 4 > mdl.len()
    {
        return None;
    }
    let vert_count = v_byte_len / stride;
    if vert_count < 3 || vert_count > 65535 {
        return None;
    }

    let idx_byte_len = i32::from_le_bytes(
        mdl[v_data_off + v_byte_len..v_data_off + v_byte_len + 4]
            .try_into()
            .ok()?,
    ) as usize;
    let idx_data_off = v_data_off + v_byte_len + 4;
    if idx_byte_len < 6 || idx_byte_len % 6 != 0 || idx_data_off + idx_byte_len > mdl.len() {
        return None;
    }

    let mut verts = Vec::with_capacity(vert_count);
    for i in 0..vert_count {
        let vo = v_data_off + i * stride;
        let x = f32::from_le_bytes(mdl[vo..vo + 4].try_into().ok()?);
        let y = f32::from_le_bytes(mdl[vo + 4..vo + 8].try_into().ok()?);
        let u = f32::from_le_bytes(mdl[vo + uv_offset..vo + uv_offset + 4].try_into().ok()?);
        let v = f32::from_le_bytes(mdl[vo + uv_offset + 4..vo + uv_offset + 8].try_into().ok()?);
        verts.push(PuppetVertex { x, y, u, v });
    }

    let index_count = idx_byte_len / 2;
    let mut indices = Vec::with_capacity(index_count);
    for i in 0..index_count {
        let idx = u16::from_le_bytes(mdl[idx_data_off + i * 2..idx_data_off + i * 2 + 2].try_into().ok()?);
        if (idx as usize) >= vert_count {
            return None;
        }
        indices.push(idx);
    }

    Some(PuppetMesh {
        vertices: verts,
        indices,
    })
}

fn resolve_mdl_vertex_layout(v_flags: u32, v_byte_len: usize) -> (usize, usize) {
    match v_flags {
        0x0180000F => (80, 72),
        0x0180001F => (88, 72),
        0x01800009 | 0x00000009 => (52, 44),
        0x01800007 | 0x00000007 => (52, 44),
        0x01800003 | 0x00000003 => (20, 12),
        _ if v_byte_len.is_multiple_of(80) => (80, 72),
        _ if v_byte_len.is_multiple_of(52) => (52, 44),
        _ if v_byte_len.is_multiple_of(20) => (20, 12),
        _ => (0, 0),
    }
}

fn try_resolve_tex_path(
    pkg_file: &mut File,
    entry_map: &HashMap<String, PkgSlice>,
    model_json_path: &str,
) -> Option<(String, Option<String>, BlendKind)> {
    let model_slice = *entry_map.get(model_json_path)?;
    if model_slice.length > 256 * 1024 {
        return None;
    }
    let m_root: Value = serde_json::from_slice(&read_slice(pkg_file, model_slice)?).ok()?;
    if read_bool(&m_root, "solidlayer", false) {
        return None;
    }
    let puppet_mdl_path = m_root
        .get("puppet")
        .and_then(|v| v.as_str())
        .map(ToString::to_string);
    let mat_path = m_root.get("material").and_then(|v| v.as_str())?;
    let mat_slice = *entry_map.get(&mat_path.to_ascii_lowercase())?;
    if mat_slice.length > 256 * 1024 {
        return None;
    }

    let mat_root: Value = serde_json::from_slice(&read_slice(pkg_file, mat_slice)?).ok()?;
    let pass = mat_root.get("passes")?.as_array()?.first()?;
    let shader = pass.get("shader").and_then(|v| v.as_str()).unwrap_or("");
    if !shader.to_ascii_lowercase().starts_with("genericimage") {
        return None;
    }

    if let Some(combos) = pass.get("combos") {
        if read_int(combos, "spritesheet", 0) != 0
            || read_int(combos, "SPRITESHEET", 0) != 0
            || read_bool(combos, "spritesheet", false)
            || read_bool(combos, "SPRITESHEET", false)
        {
            return None;
        }
    }

    let blend_str = pass
        .get("blending")
        .and_then(|v| v.as_str())
        .unwrap_or("translucent")
        .to_ascii_lowercase();
    let blend_mode = match blend_str.as_str() {
        "normal" | "opaque" => BlendKind::Opaque,
        "additive" | "add" => BlendKind::Additive,
        _ => BlendKind::Translucent,
    };

    let tex_name = pass
        .get("textures")?
        .as_array()?
        .first()?
        .as_str()?
        .trim();
    if tex_name.is_empty() {
        return None;
    }

    let candidate = if tex_name.to_ascii_lowercase().ends_with(".tex") {
        format!("materials/{tex_name}")
    } else {
        format!("materials/{tex_name}.tex")
    };
    if entry_map.contains_key(&candidate.to_ascii_lowercase()) {
        return Some((candidate, puppet_mdl_path, blend_mode));
    }
    let alt = format!("{tex_name}.tex");
    if entry_map.contains_key(&alt.to_ascii_lowercase()) {
        return Some((alt, puppet_mdl_path, blend_mode));
    }
    None
}

fn is_node_visible(node: &SceneNode, by_id: &HashMap<i32, SceneNode>) -> bool {
    let mut cur = Some(node);
    for _ in 0..16 {
        let Some(n) = cur else { break };
        if !n.visible {
            return false;
        }
        cur = n.parent_id.and_then(|pid| by_id.get(&pid));
    }
    true
}

fn compute_world_transform(node: &SceneNode, by_id: &HashMap<i32, SceneNode>) -> WorldTransform {
    let mut chain = vec![node.clone()];
    let mut cur = node;
    for _ in 0..16 {
        let Some(pid) = cur.parent_id else { break };
        let Some(p) = by_id.get(&pid) else { break };
        chain.push(p.clone());
        cur = p;
    }
    chain.reverse();

    let (mut wx, mut wy, mut sx, mut sy, mut az, mut alpha) =
        (0.0f32, 0.0f32, 1.0f32, 1.0f32, 0.0f32, 1.0f32);
    let mut color = (1.0f32, 1.0f32, 1.0f32);
    for (i, n) in chain.iter().enumerate() {
        if i == 0 {
            wx = n.origin_x;
            wy = n.origin_y;
        } else {
            let rad = az.to_radians();
            let cos = rad.cos();
            let sin = rad.sin();
            let lx = n.origin_x * sx;
            let ly = n.origin_y * sy;
            wx += lx * cos - ly * sin;
            wy += lx * sin + ly * cos;
        }
        sx *= n.scale_x;
        sy *= n.scale_y;
        az += n.angle_z;
        alpha *= n.alpha;
        color = (color.0 * n.color.0, color.1 * n.color.1, color.2 * n.color.2);
    }

    WorldTransform {
        x: wx,
        y: wy,
        scale_x: sx,
        scale_y: sy,
        angle_z: az,
        alpha: alpha.clamp(0.0, 1.0),
        color,
    }
}

fn read_int(obj: &Value, prop: &str, fallback: i32) -> i32 {
    obj.get(prop)
        .and_then(|v| v.as_i64())
        .map(|n| n as i32)
        .unwrap_or(fallback)
}

fn read_bool(obj: &Value, prop: &str, fallback: bool) -> bool {
    let Some(p) = obj.get(prop) else {
        return fallback;
    };
    if let Some(b) = p.as_bool() {
        return b;
    }
    if let Some(v) = p.get("value").and_then(|val| val.as_bool()) {
        return v;
    }
    fallback
}

fn read_float(obj: &Value, prop: &str, fallback: f32) -> f32 {
    let Some(p) = obj.get(prop) else {
        return fallback;
    };
    if let Some(f) = p.as_f64() {
        return f as f32;
    }
    if let Some(f) = p.get("value").and_then(|v| v.as_f64()) {
        return f as f32;
    }
    fallback
}

fn read_vec_string<'a>(obj: &'a Value, prop: &str) -> Option<&'a str> {
    let p = obj.get(prop)?;
    if let Some(s) = p.as_str() {
        return Some(s);
    }
    p.get("value")?.as_str()
}

fn read_vec2(obj: &Value, prop: &str, def_x: f32, def_y: f32) -> (f32, f32) {
    let Some(raw) = read_vec_string(obj, prop) else {
        return (def_x, def_y);
    };
    let mut parts = raw.split_whitespace();
    let x = parts.next().and_then(|s| s.parse::<f32>().ok()).unwrap_or(def_x);
    let y = parts.next().and_then(|s| s.parse::<f32>().ok()).unwrap_or(def_y);
    (x, y)
}

fn read_opt_vec2(obj: &Value, prop: &str) -> Option<(f32, f32)> {
    let raw = read_vec_string(obj, prop)?;
    let mut parts = raw.split_whitespace();
    let x = parts.next()?.parse::<f32>().ok()?;
    let y = parts.next()?.parse::<f32>().ok()?;
    Some((x, y))
}

fn read_vec3_z(obj: &Value, prop: &str, def_z: f32) -> f32 {
    let Some(raw) = read_vec_string(obj, prop) else {
        return def_z;
    };
    raw.split_whitespace()
        .nth(2)
        .and_then(|s| s.parse::<f32>().ok())
        .unwrap_or(def_z)
}

fn read_color3(obj: &Value, prop: &str) -> (f32, f32, f32) {
    let Some(raw) = read_vec_string(obj, prop) else {
        return (1.0, 1.0, 1.0);
    };
    let mut parts = raw.split_whitespace();
    let r = parts.next().and_then(|s| s.parse::<f32>().ok()).unwrap_or(1.0);
    let g = parts.next().and_then(|s| s.parse::<f32>().ok()).unwrap_or(1.0);
    let b = parts.next().and_then(|s| s.parse::<f32>().ok()).unwrap_or(1.0);
    (r.clamp(0.0, 1.0), g.clamp(0.0, 1.0), b.clamp(0.0, 1.0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subject_stem_groups_chinese_and_english_character_parts() {
        assert_eq!(extract_subject_stem("芙宁娜头发").as_deref(), Some("芙宁娜"));
        assert_eq!(extract_subject_stem("芙宁娜身体 2").as_deref(), Some("芙宁娜"));
        assert_eq!(extract_subject_stem("Jinx_hair_L").as_deref(), Some("Jinx"));
        assert_eq!(extract_subject_stem("背景底图"), None);
    }

    #[test]
    fn transparent_trim_tightly_crops_alpha_bounds() {
        let mut rgba = vec![0u8; 64 * 64 * 4];
        for y in 20..30 {
            for x in 24..34 {
                let off = (y * 64 + x) * 4;
                rgba[off] = 255;
                rgba[off + 3] = 255;
            }
        }
        let (_, tw, th) =
            try_trim_transparent_canvas(&rgba, 64, 64, 4).expect("non-empty crop");
        assert_eq!((tw, th), (18, 18));
    }
}
