use crate::actions::{clean_track_title, format_byte_size, get_safe_file_name, get_unique_destination_path};
use crate::clipboard::copy_media_to_clipboard;
use crate::models::{SceneLayerManifest, WallpaperItem};
use crate::scene_studio::{SceneStudioSession, has_inspectable_2d_scene, open_studio_session};
use crate::settings::cache_root;
use crate::we_bridge::resolve_wallpaper_asset_path;
use image::GenericImageView;
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use rayon::prelude::*;
use rustls::DigitallySignedStruct;
use rustls::SignatureScheme;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{BufReader, Read, Seek, SeekFrom, Write};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpListener, TcpStream, ToSocketAddrs, UdpSocket};
use std::os::windows::io::FromRawSocket;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use windows::Win32::Networking::WinSock::{
    AF_INET, IN_ADDR, INVALID_SOCKET, IPPROTO_UDP, SO_REUSEADDR, SOCK_DGRAM, SOCKADDR,
    SOCKADDR_IN, SOL_SOCKET, WSADATA, WSAStartup, bind, gethostname, setsockopt, socket,
};

pub const LOCALSEND_MULTICAST_IP: Ipv4Addr = Ipv4Addr::new(239, 255, 77, 88);
pub const LOCALSEND_DEFAULT_PORT: u16 = 53417;
pub const WALLPULL_LAN_CHANNEL: &str = "wallpull-lan-v2";
const LOCALSEND_VERSION: &str = "2.1";
const PEER_TTL_MS: u64 = 95_000;
const PEER_HEARTBEAT_STALE_MS: u64 = 25_000;
const PEER_MAX_MISSED_PROBES: u8 = 3;
const SESSION_TTL_MS: u64 = 1_800_000;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalSendDeviceInfo {
    pub alias: String,
    pub version: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_type: Option<String>,
    pub fingerprint: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub protocol: Option<String>,
    #[serde(default)]
    pub download: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub announce: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wallpull_channel: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalSendPeer {
    pub fingerprint: String,
    pub alias: String,
    pub device_model: Option<String>,
    pub device_type: Option<String>,
    pub ip: String,
    pub port: u16,
    pub protocol: String,
    pub download: bool,
    pub is_wallpull_ipad: bool,
    pub last_seen_ms: u64,
    #[serde(skip)]
    pub missed_probes: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogAudioTrack {
    pub index: usize,
    pub name: String,
    pub file_name: String,
    pub mime_type: String,
    pub size: u64,
    #[serde(skip_serializing)]
    pub source_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogEntry {
    pub id: String,
    pub workshop_id: String,
    pub title: String,
    #[serde(rename = "type")]
    pub media_type: String,
    pub resolution: Option<String>,
    pub duration: Option<String>,
    pub file_size: i64,
    pub color_bucket: Option<String>,
    pub file_name: String,
    pub mime_type: String,
    #[serde(default)]
    pub content_rating: String,
    #[serde(default)]
    pub has_preview_video: bool,
    #[serde(default)]
    pub has_scene_layers: bool,
    #[serde(default)]
    pub asset_count: usize,
    #[serde(default)]
    pub audio_tracks: Vec<CatalogAudioTrack>,
    #[serde(skip_serializing)]
    pub source_path: String,
    #[serde(skip_serializing)]
    pub asset_paths: Vec<String>,
    #[serde(skip_serializing)]
    pub preview_path: String,
    #[serde(skip_serializing)]
    pub preview_video_path: Option<String>,
    #[serde(skip_serializing)]
    pub workshop_directory: String,
}

#[derive(Debug, Clone)]
pub enum TransferSource {
    File(PathBuf),
    Memory(Arc<Vec<u8>>),
}

#[derive(Debug, Clone)]
pub struct OutgoingTransferFile {
    pub id: String,
    pub file_name: String,
    pub mime_type: String,
    pub source: TransferSource,
    pub wallpull_target: String,
    pub wallpull_kind: String,
    pub wallpull_title: String,
    pub wallpull_resolution: Option<String>,
    pub wallpull_item_id: Option<String>,
    pub wallpull_has_scene_layers: bool,
    pub wallpull_content_rating: Option<String>,
}

#[derive(Debug, Clone)]
pub enum LocalSendEvent {
    PeersChanged,
    FileReceived {
        message: String,
        destination: Option<String>,
    },
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PrepareUploadRequest {
    info: LocalSendDeviceInfo,
    files: HashMap<String, IncomingFileDto>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct IncomingFileDto {
    id: String,
    file_name: String,
    size: u64,
    file_type: String,
    sha256: Option<String>,
    preview: Option<String>,
    metadata: Option<IncomingFileMetadata>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct IncomingFileMetadata {
    modified: Option<String>,
    accessed: Option<String>,
    wallpull_target: Option<String>,
    wallpull_kind: Option<String>,
    wallpull_title: Option<String>,
    wallpull_resolution: Option<String>,
    wallpull_item_id: Option<String>,
    wallpull_has_scene_layers: Option<bool>,
    wallpull_content_rating: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct PrepareUploadResponse {
    session_id: String,
    files: HashMap<String, String>,
}

#[derive(Debug, Clone)]
struct PendingUploadFile {
    dto: IncomingFileDto,
    token: String,
}

#[derive(Debug, Clone)]
struct UploadSession {
    sender_alias: String,
    files: HashMap<String, PendingUploadFile>,
    temp_paths: Vec<PathBuf>,
    created_at_ms: u64,
}

struct HubRuntimeState {
    enabled: bool,
    alias: String,
    export_dir: String,
    port: u16,
    fingerprint: String,
    peers: HashMap<String, LocalSendPeer>,
    known_endpoints: HashSet<(Ipv4Addr, u16)>,
    sessions: HashMap<String, UploadSession>,
    catalog: Vec<CatalogEntry>,
    catalog_by_id: HashMap<String, CatalogEntry>,
    studio_cache: Option<(String, Arc<SceneStudioSession>)>,
}

pub struct LocalSendHub {
    state: Arc<RwLock<HubRuntimeState>>,
    stop: Arc<AtomicBool>,
    event_cb: Arc<Mutex<Option<Box<dyn Fn(LocalSendEvent) + Send + Sync>>>>,
}

impl LocalSendHub {
    pub fn start(
        enabled: bool,
        alias: &str,
        export_dir: &str,
        bind_sockets: bool,
        on_event: impl Fn(LocalSendEvent) + Send + Sync + 'static,
    ) -> Arc<Self> {
        let state = Arc::new(RwLock::new(HubRuntimeState {
            enabled,
            alias: clean_alias(alias),
            export_dir: export_dir.to_string(),
            port: 0,
            fingerprint: generate_fingerprint(),
            peers: HashMap::new(),
            known_endpoints: HashSet::new(),
            sessions: HashMap::new(),
            catalog: Vec::new(),
            catalog_by_id: HashMap::new(),
            studio_cache: None,
        }));
        let stop = Arc::new(AtomicBool::new(false));
        let event_cb: Arc<Mutex<Option<Box<dyn Fn(LocalSendEvent) + Send + Sync>>>> =
            Arc::new(Mutex::new(Some(Box::new(on_event))));

        let hub = Arc::new(Self {
            state,
            stop,
            event_cb,
        });

        if bind_sockets {
            hub.spawn_services();
        }
        hub
    }

    pub fn update_config(&self, enabled: bool, alias: &str, export_dir: &str) {
        if let Ok(mut guard) = self.state.write() {
            guard.enabled = enabled;
            guard.alias = clean_alias(alias);
            guard.export_dir = export_dir.to_string();
        }
        if enabled {
            self.announce_multicast();
        }
    }

    pub fn update_catalog(&self, items: &[WallpaperItem]) {
        let mut entries = Vec::with_capacity(items.len());
        let mut by_id = HashMap::with_capacity(items.len());
        let has_ffmpeg = crate::media::find_executable("ffmpeg.exe").is_some();
        for w in items {
            let resolved = resolve_wallpaper_asset_path(w, None);
            let path = Path::new(&resolved);
            if !path.is_file() {
                continue;
            }
            let raw_file_name = path
                .file_name()
                .and_then(|n| n.to_str())
                .map(ToString::to_string)
                .unwrap_or_else(|| format!("{}.bin", get_safe_file_name(&w.title, &w.workshop_id)));
            let ext_lower = path
                .extension()
                .and_then(|e| e.to_str())
                .map(|s| s.to_ascii_lowercase())
                .unwrap_or_default();
            let preview_video_path = w
                .preview_video_path
                .as_ref()
                .filter(|p| Path::new(p).is_file())
                .cloned();
            let needs_ios_mp4 = w.item_type == "video"
                && !matches!(ext_lower.as_str(), "mp4" | "mov" | "m4v")
                && (has_ffmpeg || preview_video_path.is_some());
            let file_name = if needs_ios_mp4 {
                let stem = Path::new(&raw_file_name)
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .filter(|s| !s.is_empty())
                    .unwrap_or("video");
                format!("{stem}.mp4")
            } else {
                raw_file_name
            };
            let mime_type = if needs_ios_mp4 {
                "video/mp4".to_string()
            } else {
                mime_for_path(path, &w.item_type)
            };
            let file_size = fs::metadata(path).map(|m| m.len() as i64).unwrap_or(w.file_size);
            let asset_paths: Vec<String> = w
                .asset_paths
                .as_ref()
                .map(|list| list.iter().filter(|p| Path::new(p).is_file()).cloned().collect())
                .filter(|v: &Vec<String>| !v.is_empty())
                .unwrap_or_else(|| vec![resolved.clone()]);
            let asset_count = asset_paths.len();
            let has_scene_layers = w.item_type == "image"
                && !w.workshop_directory.is_empty()
                && has_inspectable_2d_scene(&w.workshop_directory);
            let content_rating = if !w.workshop_directory.is_empty() {
                crate::scanner::inspect_workshop_extra(&w.workshop_directory).content_rating
            } else {
                "Everyone".to_string()
            };
            let has_preview_video =
                w.item_type == "video" && (preview_video_path.is_some() || has_ffmpeg);
            let mut audio_tracks = Vec::new();
            if let Some(tracks) = &w.audio_paths {
                for (t_idx, raw_p) in tracks.iter().enumerate() {
                    let tp = Path::new(raw_p);
                    if !tp.is_file() {
                        continue;
                    }
                    let ext = tp
                        .extension()
                        .and_then(|e| e.to_str())
                        .map(|s| s.to_ascii_lowercase())
                        .unwrap_or_default();
                    let safe_title = get_safe_file_name(&clean_track_title(raw_p), "bgm");
                    let (out_name, out_mime) = if ext == "ogg" {
                        (format!("{safe_title}.wav"), "audio/wav".to_string())
                    } else {
                        let actual_name = tp
                            .file_name()
                            .and_then(|n| n.to_str())
                            .map(ToString::to_string)
                            .unwrap_or_else(|| format!("{safe_title}.{ext}"));
                        (actual_name, audio_mime_for_ext(&ext).to_string())
                    };
                    let size = fs::metadata(tp).map(|m| m.len()).unwrap_or(0);
                    audio_tracks.push(CatalogAudioTrack {
                        index: audio_tracks.len(),
                        name: clean_track_title(raw_p),
                        file_name: out_name,
                        mime_type: out_mime,
                        size,
                        source_path: raw_p.clone(),
                    });
                    let _ = t_idx;
                }
            }
            let entry = CatalogEntry {
                id: w.id.clone(),
                workshop_id: w.workshop_id.clone(),
                title: w.title.clone(),
                media_type: w.item_type.clone(),
                resolution: w.resolution.clone(),
                duration: w.duration.clone(),
                file_size,
                color_bucket: w.color_bucket.clone(),
                file_name,
                mime_type,
                content_rating,
                has_preview_video,
                has_scene_layers,
                asset_count,
                audio_tracks,
                source_path: resolved,
                asset_paths,
                preview_path: w.preview_path.clone(),
                preview_video_path,
                workshop_directory: w.workshop_directory.clone(),
            };
            by_id.insert(entry.id.clone(), entry.clone());
            entries.push(entry);
        }
        entries.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()));
        if let Ok(mut guard) = self.state.write() {
            guard.catalog = entries;
            guard.catalog_by_id = by_id;
        }
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
    }

    pub fn status_snapshot(&self) -> serde_json::Value {
        let now = now_ms();
        let (enabled, alias, port, fingerprint, peers) = {
            let mut guard = self.state.write().unwrap_or_else(|e| e.into_inner());
            guard.peers.retain(|_, p| !is_peer_expired(p, now));
            let mut peer_list: Vec<LocalSendPeer> = guard.peers.values().cloned().collect();
            peer_list.sort_by(|a, b| {
                b.is_wallpull_ipad
                    .cmp(&a.is_wallpull_ipad)
                    .then_with(|| a.alias.to_lowercase().cmp(&b.alias.to_lowercase()))
            });
            (
                guard.enabled,
                guard.alias.clone(),
                guard.port,
                guard.fingerprint.clone(),
                peer_list,
            )
        };
        serde_json::json!({
            "enabled": enabled,
            "alias": alias,
            "port": port,
            "fingerprint": fingerprint,
            "localIps": list_lan_ipv4s(),
            "peers": peers,
        })
    }

    pub fn peers_snapshot(&self) -> Vec<LocalSendPeer> {
        let now = now_ms();
        let mut guard = self.state.write().unwrap_or_else(|e| e.into_inner());
        guard.peers.retain(|_, p| !is_peer_expired(p, now));
        let mut list: Vec<LocalSendPeer> = guard.peers.values().cloned().collect();
        list.sort_by(|a, b| {
            b.is_wallpull_ipad
                .cmp(&a.is_wallpull_ipad)
                .then_with(|| b.last_seen_ms.cmp(&a.last_seen_ms))
        });
        list
    }

    pub fn find_peer(&self, fingerprint: Option<&str>) -> Option<LocalSendPeer> {
        let peers = self.peers_snapshot();
        if let Some(fp) = fingerprint {
            if let Some(found) = peers.iter().find(|p| p.fingerprint == fp) {
                return Some(found.clone());
            }
        }
        peers
            .iter()
            .find(|p| p.is_wallpull_ipad)
            .cloned()
            .or_else(|| peers.into_iter().next())
    }

    pub fn device_info(&self, announce: Option<bool>) -> LocalSendDeviceInfo {
        let guard = self.state.read().unwrap_or_else(|e| e.into_inner());
        LocalSendDeviceInfo {
            alias: guard.alias.clone(),
            version: LOCALSEND_VERSION.to_string(),
            device_model: Some("WallPull Windows".to_string()),
            device_type: Some("desktop".to_string()),
            fingerprint: guard.fingerprint.clone(),
            port: Some(if guard.port > 0 {
                guard.port
            } else {
                LOCALSEND_DEFAULT_PORT
            }),
            protocol: Some("http".to_string()),
            download: true,
            announce,
            wallpull_channel: Some(WALLPULL_LAN_CHANNEL.to_string()),
        }
    }

    pub fn heartbeat_known_peers(&self) {
        let now = now_ms();
        cleanup_expired_sessions(&self.state, now);

        let (enabled, my_fp, targets) = {
            let guard = self.state.read().unwrap_or_else(|e| e.into_inner());
            if !guard.enabled {
                return;
            }
            let mut ep_map: HashMap<(Ipv4Addr, u16), String> = HashMap::new();
            for &(ip, port) in &guard.known_endpoints {
                ep_map.insert((ip, port), "http".to_string());
            }
            for peer in guard.peers.values() {
                if let Ok(ip) = peer.ip.parse::<Ipv4Addr>() {
                    ep_map.insert((ip, peer.port), peer.protocol.clone());
                }
            }
            let list: Vec<(Ipv4Addr, u16, String)> = ep_map
                .into_iter()
                .map(|((ip, port), proto)| (ip, port, proto))
                .collect();
            (guard.enabled, guard.fingerprint.clone(), list)
        };
        if !enabled || targets.is_empty() {
            let mut changed = false;
            if let Ok(mut guard) = self.state.write() {
                let before = guard.peers.len();
                guard.peers.retain(|_, p| !is_peer_expired(p, now));
                changed = guard.peers.len() != before;
            }
            if changed {
                emit_event(&self.event_cb, LocalSendEvent::PeersChanged);
            }
            return;
        }

        let info = self.device_info(None);
        let body_bytes = serde_json::to_vec(&info).unwrap_or_default();
        let mut any_changed = false;
        let mut failed_endpoints: HashSet<(String, u16)> = HashSet::new();

        for (ip, port, proto) in targets {
            let mut responded_info: Option<(LocalSendDeviceInfo, &str)> = None;
            if proto.eq_ignore_ascii_case("http") {
                if let Ok((200, resp_bytes)) = lan_http_post_json(
                    ip,
                    port,
                    "/api/localsend/v2/register",
                    &body_bytes,
                    Duration::from_millis(1600),
                ) {
                    if let Ok(peer_info) = serde_json::from_slice::<LocalSendDeviceInfo>(&resp_bytes) {
                        responded_info = Some((peer_info, "http"));
                    }
                }
            } else {
                let agent = build_lan_https_agent(Duration::from_millis(1600));
                let url = format!("https://{ip}:{port}/api/localsend/v2/register");
                if let Ok(payload) = serde_json::to_value(&info) {
                    if let Ok(resp) = agent.post(&url).send_json(payload) {
                        if let Ok(peer_info) = resp.into_json::<LocalSendDeviceInfo>() {
                            responded_info = Some((peer_info, "https"));
                        }
                    }
                }
            }

            if let Some((peer_info, used_proto)) = responded_info {
                if peer_info.fingerprint != my_fp && is_wallpull_device_info(&peer_info) {
                    if upsert_peer(&self.state, peer_info, ip.to_string(), Some(port), Some(used_proto)) {
                        any_changed = true;
                    }
                }
            } else {
                failed_endpoints.insert((ip.to_string(), port));
            }
        }

        {
            let check_now = now_ms();
            let mut guard = self.state.write().unwrap_or_else(|e| e.into_inner());
            for peer in guard.peers.values_mut() {
                if failed_endpoints.contains(&(peer.ip.clone(), peer.port)) {
                    peer.missed_probes = peer.missed_probes.saturating_add(1);
                }
            }
            let before = guard.peers.len();
            guard.peers.retain(|_, p| !is_peer_expired(p, check_now));
            if guard.peers.len() != before {
                any_changed = true;
            }
        }
        if any_changed {
            emit_event(&self.event_cb, LocalSendEvent::PeersChanged);
        }
    }

    pub fn announce_multicast(&self) {
        let enabled = self.state.read().map(|g| g.enabled).unwrap_or(false);
        if !enabled {
            return;
        }
        let info = self.device_info(Some(true));
        let Ok(payload) = serde_json::to_vec(&info) else {
            return;
        };
        let target = SocketAddrV4::new(LOCALSEND_MULTICAST_IP, LOCALSEND_DEFAULT_PORT);
        let ips = list_lan_ipv4s();
        for ip in ips {
            if let Ok(sock) = UdpSocket::bind(SocketAddrV4::new(ip, 0)) {
                let _ = sock.set_multicast_ttl_v4(2);
                let _ = sock.send_to(&payload, target);
            }
        }
        if let Ok(sock) = UdpSocket::bind("0.0.0.0:0") {
            let _ = sock.set_multicast_ttl_v4(2);
            let _ = sock.send_to(&payload, target);
        }
    }

    pub fn refresh_discovery(&self) {
        self.announce_multicast();
        let hub_state = self.state.clone();
        let cb = self.event_cb.clone();
        let info = self.device_info(None);
        std::thread::spawn(move || {
            let mut candidates: HashSet<(Ipv4Addr, u16)> = HashSet::new();
            for lan_ip in list_lan_ipv4s() {
                let octets = lan_ip.octets();
                for host in 1u8..=254 {
                    let target = Ipv4Addr::new(octets[0], octets[1], octets[2], host);
                    if target == lan_ip {
                        continue;
                    }
                    candidates.insert((target, LOCALSEND_DEFAULT_PORT));
                    candidates.insert((target, LOCALSEND_DEFAULT_PORT + 1));
                }
            }
            let list: Vec<(Ipv4Addr, u16)> = candidates.into_iter().collect();
            let worker_count = 24usize;
            let chunk_size = (list.len() + worker_count - 1) / worker_count;
            let found_any = Arc::new(AtomicBool::new(false));
            std::thread::scope(|s| {
                for chunk in list.chunks(chunk_size.max(1)) {
                    let info_ref = &info;
                    let state_ref = &hub_state;
                    let found_ref = &found_any;
                    s.spawn(move || {
                        let body_bytes = serde_json::to_vec(info_ref).unwrap_or_default();
                        let https_agent = build_lan_https_agent(Duration::from_millis(450));
                        for &(ip, port) in chunk {
                            // Prefer direct TcpStream HTTP/1.1 first (zero proxy interference)
                            if let Ok((200, resp_bytes)) = lan_http_post_json(
                                ip,
                                port,
                                "/api/localsend/v2/register",
                                &body_bytes,
                                Duration::from_millis(420),
                            ) {
                                if let Ok(peer_info) = serde_json::from_slice::<LocalSendDeviceInfo>(&resp_bytes) {
                                    if peer_info.fingerprint != info_ref.fingerprint {
                                        upsert_peer(state_ref, peer_info, ip.to_string(), Some(port), Some("http"));
                                        found_ref.store(true, Ordering::SeqCst);
                                    }
                                    continue;
                                }
                            }
                            let url = format!("https://{ip}:{port}/api/localsend/v2/register");
                            if let Ok(payload) = serde_json::to_value(info_ref) {
                                if let Ok(resp) = https_agent.post(&url).send_json(payload) {
                                    if let Ok(peer_info) = resp.into_json::<LocalSendDeviceInfo>() {
                                        if peer_info.fingerprint != info_ref.fingerprint {
                                            upsert_peer(state_ref, peer_info, ip.to_string(), Some(port), Some("https"));
                                            found_ref.store(true, Ordering::SeqCst);
                                        }
                                    }
                                }
                            }
                        }
                    });
                }
            });
            if found_any.load(Ordering::SeqCst) {
                emit_event(&cb, LocalSendEvent::PeersChanged);
            }
        });
    }

    pub fn send_files_to_peer(
        &self,
        peer: &LocalSendPeer,
        files: &[OutgoingTransferFile],
    ) -> Result<String, String> {
        if files.is_empty() {
            return Err("没有可发送的文件。".to_string());
        }
        let mut file_dtos: HashMap<String, serde_json::Value> = HashMap::new();
        let mut hashes: HashMap<String, String> = HashMap::new();
        let mut sizes: HashMap<String, u64> = HashMap::new();

        for item in files {
            let (size, sha256) = compute_source_metrics(&item.source)?;
            sizes.insert(item.id.clone(), size);
            hashes.insert(item.id.clone(), sha256.clone());
            let mut meta = serde_json::Map::new();
            meta.insert("wallpullTarget".into(), serde_json::Value::String(item.wallpull_target.clone()));
            meta.insert("wallpullKind".into(), serde_json::Value::String(item.wallpull_kind.clone()));
            meta.insert("wallpullTitle".into(), serde_json::Value::String(item.wallpull_title.clone()));
            if let Some(res) = &item.wallpull_resolution {
                meta.insert("wallpullResolution".into(), serde_json::Value::String(res.clone()));
            }
            if let Some(item_id) = &item.wallpull_item_id {
                meta.insert("wallpullItemId".into(), serde_json::Value::String(item_id.clone()));
            }
            if item.wallpull_has_scene_layers {
                meta.insert("wallpullHasSceneLayers".into(), serde_json::Value::Bool(true));
            }
            if let Some(rating) = &item.wallpull_content_rating {
                if !rating.trim().is_empty() {
                    meta.insert("wallpullContentRating".into(), serde_json::Value::String(rating.clone()));
                }
            }
            file_dtos.insert(
                item.id.clone(),
                serde_json::json!({
                    "id": item.id,
                    "fileName": item.file_name,
                    "size": size,
                    "fileType": item.mime_type,
                    "sha256": sha256,
                    "metadata": meta,
                }),
            );
        }

        let prepare_body = serde_json::json!({
            "info": self.device_info(None),
            "files": file_dtos,
        });
        let prepare_bytes = serde_json::to_vec(&prepare_body).map_err(|e| e.to_string())?;
        let parsed: serde_json::Value = if peer.protocol.eq_ignore_ascii_case("http") {
            let ip: Ipv4Addr = peer
                .ip
                .parse()
                .map_err(|_| format!("设备 IP 无效：{}", peer.ip))?;
            let (status, resp_bytes) = lan_http_post_json(
                ip,
                peer.port,
                "/api/localsend/v2/prepare-upload",
                &prepare_bytes,
                Duration::from_secs(15),
            )
            .map_err(|e| format!("无法连接设备「{}」({}:{})：{e}", peer.alias, peer.ip, peer.port))?;
            if status == 204 {
                return Ok(format!("{} 已确认无需重复传输。", peer.alias));
            }
            if status != 200 {
                return Err(format!("设备「{}」返回状态码 {status}。", peer.alias));
            }
            serde_json::from_slice(&resp_bytes)
                .map_err(|e| format!("解析设备响应失败：{e}"))?
        } else {
            let agent = build_lan_https_agent(Duration::from_secs(120));
            let base_url = format!("https://{}:{}", peer.ip, peer.port);
            let prepare_resp = agent
                .post(&format!("{base_url}/api/localsend/v2/prepare-upload"))
                .send_json(prepare_body)
                .map_err(|e| format!("无法连接设备「{}」({}:{})：{e}", peer.alias, peer.ip, peer.port))?;
            if prepare_resp.status() == 204 {
                return Ok(format!("{} 已确认无需重复传输。", peer.alias));
            }
            prepare_resp
                .into_json()
                .map_err(|e| format!("解析设备响应失败：{e}"))?
        };

        let session_id = parsed
            .get("sessionId")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| "对端未返回有效的传输会话 ID。".to_string())?
            .to_string();
        let accepted_tokens = parsed
            .get("files")
            .and_then(|v| v.as_object())
            .ok_or_else(|| "对端拒绝了本次传输请求。".to_string())?;

        let mut sent_count = 0usize;
        let mut total_bytes = 0u64;
        for item in files {
            let Some(token) = accepted_tokens.get(&item.id).and_then(|v| v.as_str()) else {
                continue;
            };
            let upload_path = format!(
                "/api/localsend/v2/upload?sessionId={}&fileId={}&token={}",
                urlencoding::encode(&session_id),
                urlencoding::encode(&item.id),
                urlencoding::encode(token)
            );

            let res = if peer.protocol.eq_ignore_ascii_case("http") {
                let ip: Ipv4Addr = peer.ip.parse().map_err(|_| "无效 IP".to_string())?;
                match &item.source {
                    TransferSource::Memory(bytes) => {
                        total_bytes = total_bytes.saturating_add(bytes.len() as u64);
                        lan_http_upload_bytes(ip, peer.port, &upload_path, bytes.as_slice(), Duration::from_secs(120))
                    }
                    TransferSource::File(path) => {
                        let size = *sizes.get(&item.id).unwrap_or(&0);
                        total_bytes = total_bytes.saturating_add(size);
                        lan_http_upload_file(ip, peer.port, &upload_path, path, size, Duration::from_secs(180))
                    }
                }
            } else {
                let agent = build_lan_https_agent(Duration::from_secs(180));
                let upload_url = format!("https://{}:{}{upload_path}", peer.ip, peer.port);
                let req = agent
                    .post(&upload_url)
                    .set("Content-Type", "application/octet-stream");
                let r = match &item.source {
                    TransferSource::Memory(bytes) => {
                        total_bytes = total_bytes.saturating_add(bytes.len() as u64);
                        req.set("Content-Length", &bytes.len().to_string())
                            .send_bytes(bytes.as_slice())
                    }
                    TransferSource::File(path) => {
                        let size = *sizes.get(&item.id).unwrap_or(&0);
                        total_bytes = total_bytes.saturating_add(size);
                        let f = File::open(path).map_err(|e| format!("打开待发文件失败：{e}"))?;
                        req.set("Content-Length", &size.to_string()).send(f)
                    }
                };
                r.map(|_| ()).map_err(|e| e.to_string())
            };

            if let Err(err) = res {
                if peer.protocol.eq_ignore_ascii_case("http") {
                    if let Ok(ip) = peer.ip.parse::<Ipv4Addr>() {
                        let _ = lan_http_post_json(
                            ip,
                            peer.port,
                            &format!("/api/localsend/v2/cancel?sessionId={}", urlencoding::encode(&session_id)),
                            &[],
                            Duration::from_secs(3),
                        );
                    }
                }
                return Err(format!("发送到「{}」时中断：{err}", peer.alias));
            }
            sent_count += 1;
        }

        if sent_count == 0 {
            return Err(format!("设备「{}」未接收任何文件。", peer.alias));
        }
        touch_peer_by_ip(&self.state, &peer.ip);
        let target_clipboard = files.iter().all(|f| f.wallpull_target == "clipboard");
        if target_clipboard {
            Ok(format!("已通过 WallPull 跨端直传隔空推送到「{}」剪贴板，切去微信直接粘贴即可", peer.alias))
        } else if sent_count == 1 {
            Ok(format!(
                "已通过 WallPull 跨端直传发送给「{}」：{}（{}）",
                peer.alias,
                files[0].wallpull_title,
                format_byte_size(total_bytes as i64)
            ))
        } else {
            Ok(format!(
                "已通过 WallPull 跨端直传发送 {sent_count} 项到「{}」（共 {}）",
                peer.alias,
                format_byte_size(total_bytes as i64)
            ))
        }
    }

    fn spawn_services(self: &Arc<Self>) {
        // 1. Bind HTTP server on 53417..53422
        let mut listener_opt = None;
        let mut bound_port = 0u16;
        for port in LOCALSEND_DEFAULT_PORT..=(LOCALSEND_DEFAULT_PORT + 5) {
            if let Ok(listener) = TcpListener::bind(("0.0.0.0", port)) {
                bound_port = port;
                listener_opt = Some(listener);
                break;
            }
        }
        if let Some(listener) = listener_opt {
            if let Ok(mut guard) = self.state.write() {
                guard.port = bound_port;
            }
            let hub_http = self.clone();
            std::thread::spawn(move || {
                run_http_accept_loop(hub_http, listener);
            });
        }

        // 2. Bind UDP multicast listener 239.255.77.88:53417 with SO_REUSEADDR
        let hub_udp = self.clone();
        std::thread::spawn(move || {
            run_udp_multicast_loop(hub_udp);
        });

        // 3. Initial LAN sweep + periodic 8s multicast & unicast TCP keep-alive heartbeat
        let hub_beacon = self.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(600));
            if hub_beacon.stop.load(Ordering::SeqCst) {
                return;
            }
            hub_beacon.refresh_discovery();
            while !hub_beacon.stop.load(Ordering::SeqCst) {
                hub_beacon.announce_multicast();
                hub_beacon.heartbeat_known_peers();
                for _ in 0..16 {
                    if hub_beacon.stop.load(Ordering::SeqCst) {
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(500));
                }
            }
        });
    }
}

fn run_http_accept_loop(hub: Arc<LocalSendHub>, listener: TcpListener) {
    let _ = listener.set_nonblocking(true);
    while !hub.stop.load(Ordering::SeqCst) {
        match listener.accept() {
            Ok((stream, remote_addr)) => {
                // CRITICAL: Always force blocking I/O + TCP_NODELAY so large media never hits WouldBlock
                let _ = stream.set_nonblocking(false);
                let _ = stream.set_nodelay(true);
                let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));
                let _ = stream.set_write_timeout(Some(Duration::from_secs(30)));
                let hub_clone = hub.clone();
                std::thread::spawn(move || {
                    let _ = handle_http_connection(&hub_clone, stream, remote_addr);
                });
            }
            Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(25));
            }
            Err(_) => {
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }
}

fn handle_http_connection(
    hub: &LocalSendHub,
    mut stream: TcpStream,
    remote_addr: SocketAddr,
) -> Result<(), String> {
    let enabled = hub.state.read().map(|g| g.enabled).unwrap_or(false);
    let mut header_buf = Vec::with_capacity(4096);
    let mut chunk = [0u8; 4096];
    let header_end;
    loop {
        if header_buf.len() > 64 * 1024 {
            write_json_error(&mut stream, 431, "Headers too large")?;
            return Ok(());
        }
        let n = stream.read(&mut chunk).map_err(|e| e.to_string())?;
        if n == 0 {
            return Ok(());
        }
        header_buf.extend_from_slice(&chunk[..n]);
        if let Some(pos) = find_subsequence(&header_buf, b"\r\n\r\n") {
            header_end = pos + 4;
            break;
        }
    }

    let head_str = String::from_utf8_lossy(&header_buf[..header_end]);
    let mut lines = head_str.lines();
    let request_line = lines.next().unwrap_or("");
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("").to_ascii_uppercase();
    let raw_target = parts.next().unwrap_or("/");
    let (path, query_str) = match raw_target.split_once('?') {
        Some((p, q)) => (p, q),
        None => (raw_target, ""),
    };
    let query = parse_query_params(query_str);

    let mut headers: HashMap<String, String> = HashMap::new();
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }
    let leftover = &header_buf[header_end..];
    let content_len = headers
        .get("content-length")
        .and_then(|v| v.parse::<u64>().ok());
    let is_chunked = headers
        .get("transfer-encoding")
        .map(|v| v.to_ascii_lowercase().contains("chunked"))
        .unwrap_or(false);

    if !enabled {
        write_json_error(&mut stream, 503, "LocalSend receiver disabled")?;
        return Ok(());
    }

    match (method.as_str(), path) {
        ("GET", "/api/localsend/v2/info") => {
            let info = hub.device_info(None);
            write_json_response(&mut stream, 200, &info)?;
        }
        ("POST", "/api/localsend/v2/register") => {
            let body = read_small_body(&mut stream, leftover, content_len, is_chunked, 256 * 1024)?;
            let peer_info: LocalSendDeviceInfo = match serde_json::from_slice(&body) {
                Ok(v) => v,
                Err(_) => {
                    write_json_error(&mut stream, 400, "Invalid register payload")?;
                    return Ok(());
                }
            };
            let my_fp = hub.state.read().map(|g| g.fingerprint.clone()).unwrap_or_default();
            if peer_info.fingerprint != my_fp {
                let peer_ip = remote_addr.ip().to_string();
                let changed = upsert_peer(&hub.state, peer_info, peer_ip, None, None);
                if changed {
                    emit_event(&hub.event_cb, LocalSendEvent::PeersChanged);
                }
            }
            let reply = hub.device_info(None);
            write_json_response(&mut stream, 200, &reply)?;
        }
        ("POST", "/api/localsend/v2/prepare-upload") => {
            let body = read_small_body(&mut stream, leftover, content_len, is_chunked, 8 * 1024 * 1024)?;
            let req: PrepareUploadRequest = match serde_json::from_slice(&body) {
                Ok(v) => v,
                Err(_) => {
                    write_json_error(&mut stream, 400, "Invalid prepare-upload payload")?;
                    return Ok(());
                }
            };
            if req.files.is_empty() {
                write_status_empty(&mut stream, 204, "No Content")?;
                return Ok(());
            }
            let session_id = format!("wp-{}", generate_token());
            let mut file_tokens = HashMap::new();
            let mut session_files = HashMap::new();
            for (fid, dto) in req.files {
                let tok = generate_token();
                file_tokens.insert(fid.clone(), tok.clone());
                session_files.insert(fid, PendingUploadFile { dto, token: tok });
            }
            let sender_ip = remote_addr.ip().to_string();
            let sender_alias = req.info.alias.clone();
            upsert_peer(&hub.state, req.info, sender_ip, None, None);
            emit_event(&hub.event_cb, LocalSendEvent::PeersChanged);

            {
                let mut guard = hub.state.write().unwrap_or_else(|e| e.into_inner());
                guard.sessions.insert(
                    session_id.clone(),
                    UploadSession {
                        sender_alias,
                        files: session_files,
                        temp_paths: Vec::new(),
                        created_at_ms: now_ms(),
                    },
                );
            }
            write_json_response(
                &mut stream,
                200,
                &PrepareUploadResponse {
                    session_id,
                    files: file_tokens,
                },
            )?;
        }
        ("POST", "/api/localsend/v2/upload") => {
            let Some(session_id) = query.get("sessionId").cloned() else {
                write_json_error(&mut stream, 400, "Missing sessionId")?;
                return Ok(());
            };
            let Some(file_id) = query.get("fileId").cloned() else {
                write_json_error(&mut stream, 400, "Missing fileId")?;
                return Ok(());
            };
            let Some(token) = query.get("token").cloned() else {
                write_json_error(&mut stream, 400, "Missing token")?;
                return Ok(());
            };

            let (pending, sender_alias, export_dir) = {
                let guard = hub.state.read().unwrap_or_else(|e| e.into_inner());
                let Some(sess) = guard.sessions.get(&session_id) else {
                    write_json_error(&mut stream, 403, "Invalid session")?;
                    return Ok(());
                };
                let Some(item) = sess.files.get(&file_id) else {
                    write_json_error(&mut stream, 403, "Invalid fileId")?;
                    return Ok(());
                };
                if item.token != token {
                    write_json_error(&mut stream, 403, "Invalid token")?;
                    return Ok(());
                }
                (item.clone(), sess.sender_alias.clone(), guard.export_dir.clone())
            };

            let tmp_dir = cache_root().join("localsend-tmp");
            let _ = fs::create_dir_all(&tmp_dir);
            let tmp_file = tmp_dir.join(format!("{}_{}.part", get_safe_file_name(&session_id, "s"), generate_token()));
            if let Ok(mut guard) = hub.state.write() {
                if let Some(sess) = guard.sessions.get_mut(&session_id) {
                    sess.temp_paths.push(tmp_file.clone());
                }
            }

            let sha_hex = match stream_body_to_file(&mut stream, leftover, content_len, is_chunked, &tmp_file) {
                Ok(h) => h,
                Err(e) => {
                    let _ = fs::remove_file(&tmp_file);
                    write_json_error(&mut stream, 500, &format!("Receive error: {e}"))?;
                    return Ok(());
                }
            };

            if let Some(expected) = pending.dto.sha256.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
                if !expected.eq_ignore_ascii_case(&sha_hex) {
                    let _ = fs::remove_file(&tmp_file);
                    write_json_error(&mut stream, 422, "Checksum mismatch (sha256)")?;
                    return Ok(());
                }
            }

            let meta_target = pending
                .dto
                .metadata
                .as_ref()
                .and_then(|m| m.wallpull_target.as_deref())
                .unwrap_or("vault");
            let is_img = pending.dto.file_type.starts_with("image/")
                || matches!(
                    Path::new(&pending.dto.file_name)
                        .extension()
                        .and_then(|e| e.to_str())
                        .map(|s| s.to_ascii_lowercase())
                        .as_deref(),
                    Some("png" | "jpg" | "jpeg" | "webp" | "bmp" | "gif")
                );

            if meta_target == "clipboard" && is_img {
                if let Err(err) = copy_media_to_clipboard(&tmp_file, true) {
                    let _ = fs::remove_file(&tmp_file);
                    write_json_error(&mut stream, 500, &err)?;
                    return Ok(());
                }
                let _ = fs::remove_file(&tmp_file);
                complete_session_file(&hub.state, &session_id, &file_id);
                touch_peer_by_ip(&hub.state, &remote_addr.ip().to_string());
                write_status_empty(&mut stream, 200, "OK")?;
                emit_event(
                    &hub.event_cb,
                    LocalSendEvent::FileReceived {
                        message: format!("已接收来自「{sender_alias}」的图片并写入剪贴板，可直接 Ctrl+V 发送"),
                        destination: None,
                    },
                );
                return Ok(());
            }

            let dest_dir = Path::new(&export_dir).join("LocalSend接收");
            fs::create_dir_all(&dest_dir).map_err(|e| e.to_string())?;
            let clean_name = sanitize_incoming_filename(&pending.dto.file_name);
            let final_path = get_unique_destination_path(&dest_dir, &clean_name);
            if fs::rename(&tmp_file, &final_path).is_err() {
                fs::copy(&tmp_file, &final_path).map_err(|e| e.to_string())?;
                let _ = fs::remove_file(&tmp_file);
            }
            complete_session_file(&hub.state, &session_id, &file_id);
            touch_peer_by_ip(&hub.state, &remote_addr.ip().to_string());
            write_status_empty(&mut stream, 200, "OK")?;
            emit_event(
                &hub.event_cb,
                LocalSendEvent::FileReceived {
                    message: format!("已从「{sender_alias}」无损接收：{clean_name}"),
                    destination: Some(dest_dir.to_string_lossy().into_owned()),
                },
            );
        }
        ("POST", "/api/localsend/v2/cancel") => {
            if let Some(session_id) = query.get("sessionId") {
                if let Ok(mut guard) = hub.state.write() {
                    if let Some(sess) = guard.sessions.remove(session_id) {
                        for p in sess.temp_paths {
                            let _ = fs::remove_file(p);
                        }
                    }
                }
            }
            write_status_empty(&mut stream, 200, "OK")?;
        }
        ("GET", "/api/localsend/v2/wallpull/catalog") => {
            touch_peer_by_ip(&hub.state, &remote_addr.ip().to_string());
            let catalog = hub.state.read().map(|g| g.catalog.clone()).unwrap_or_default();
            write_json_response(&mut stream, 200, &catalog)?;
        }
        ("GET", "/api/localsend/v2/wallpull/thumb") => {
            touch_peer_by_ip(&hub.state, &remote_addr.ip().to_string());
            let Some(id) = query.get("id") else {
                write_json_error(&mut stream, 400, "Missing id")?;
                return Ok(());
            };
            let entry_opt = hub.state.read().ok().and_then(|g| g.catalog_by_id.get(id).cloned());
            let Some(entry) = entry_opt else {
                write_json_error(&mut stream, 404, "Not found")?;
                return Ok(());
            };
            match get_or_build_lan_thumb(&entry) {
                Ok(bytes) => write_binary_response(&mut stream, "image/jpeg", &bytes)?,
                Err(_) => write_json_error(&mut stream, 404, "Thumbnail unavailable")?,
            }
        }
        ("GET", "/api/localsend/v2/wallpull/asset") => {
            touch_peer_by_ip(&hub.state, &remote_addr.ip().to_string());
            let Some(id) = query.get("id") else {
                write_json_error(&mut stream, 400, "Missing id")?;
                return Ok(());
            };
            let entry_opt = hub.state.read().ok().and_then(|g| g.catalog_by_id.get(id).cloned());
            let Some(entry) = entry_opt else {
                write_json_error(&mut stream, 404, "Not found")?;
                return Ok(());
            };
            let asset_idx = query.get("index").and_then(|s| s.parse::<usize>().ok());
            let (raw_path, raw_mime) = if let Some(idx) = asset_idx {
                if let Some(p) = entry.asset_paths.get(idx) {
                    (PathBuf::from(p), mime_for_path(Path::new(p), &entry.media_type))
                } else {
                    (PathBuf::from(&entry.source_path), mime_for_path(Path::new(&entry.source_path), &entry.media_type))
                }
            } else {
                (PathBuf::from(&entry.source_path), mime_for_path(Path::new(&entry.source_path), &entry.media_type))
            };
            let (serve_path, serve_mime) = if entry.media_type == "video" {
                match ensure_ios_compatible_mp4(&entry.id, &raw_path, entry.preview_video_path.as_deref()) {
                    Ok(mp4_path) => (mp4_path, "video/mp4".to_string()),
                    Err(_) => (raw_path, raw_mime),
                }
            } else {
                (raw_path, raw_mime)
            };
            let range_hdr = headers.get("range").map(|s| s.as_str());
            serve_file_with_range(&mut stream, &serve_path, &serve_mime, range_hdr)?;
        }
        ("GET", "/api/localsend/v2/wallpull/preview-video") => {
            touch_peer_by_ip(&hub.state, &remote_addr.ip().to_string());
            let Some(id) = query.get("id") else {
                write_json_error(&mut stream, 400, "Missing id")?;
                return Ok(());
            };
            let entry_opt = hub.state.read().ok().and_then(|g| g.catalog_by_id.get(id).cloned());
            let Some(entry) = entry_opt else {
                write_json_error(&mut stream, 404, "Not found")?;
                return Ok(());
            };
            let range_hdr = headers.get("range").map(|s| s.as_str());
            match ensure_lan_preview_video(&entry) {
                Ok(clip_path) => serve_file_with_range(&mut stream, &clip_path, "video/mp4", range_hdr)?,
                Err(_) => write_json_error(&mut stream, 404, "Preview video unavailable")?,
            }
        }
        ("GET", "/api/localsend/v2/wallpull/audio") => {
            touch_peer_by_ip(&hub.state, &remote_addr.ip().to_string());
            let Some(id) = query.get("id") else {
                write_json_error(&mut stream, 400, "Missing id")?;
                return Ok(());
            };
            let track_idx = query.get("track").and_then(|s| s.parse::<usize>().ok()).unwrap_or(0);
            let entry_opt = hub.state.read().ok().and_then(|g| g.catalog_by_id.get(id).cloned());
            let Some(entry) = entry_opt else {
                write_json_error(&mut stream, 404, "Not found")?;
                return Ok(());
            };
            let Some(track) = entry.audio_tracks.get(track_idx) else {
                write_json_error(&mut stream, 404, "Audio track not found")?;
                return Ok(());
            };
            let src_path = Path::new(&track.source_path);
            let is_ogg = src_path
                .extension()
                .and_then(|e| e.to_str())
                .map(|e| e.eq_ignore_ascii_case("ogg"))
                .unwrap_or(false);
            let range_hdr = headers.get("range").map(|s| s.as_str());
            if is_ogg {
                match ensure_wav_from_ogg(&entry.id, track_idx, src_path) {
                    Ok(wav_path) => serve_file_with_range(&mut stream, &wav_path, "audio/wav", range_hdr)?,
                    Err(e) => write_json_error(&mut stream, 500, &format!("Audio decode failed: {e}"))?,
                }
            } else {
                serve_file_with_range(&mut stream, src_path, &track.mime_type, range_hdr)?;
            }
        }
        ("GET", "/api/localsend/v2/wallpull/studio/manifest") => {
            touch_peer_by_ip(&hub.state, &remote_addr.ip().to_string());
            let Some(id) = query.get("id") else {
                write_json_error(&mut stream, 400, "Missing id")?;
                return Ok(());
            };
            match get_or_open_lan_studio_session(hub, id) {
                Ok(session) => write_json_response(&mut stream, 200, &session.manifest)?,
                Err(msg) => write_json_error(&mut stream, 404, &msg)?,
            }
        }
        ("POST", "/api/localsend/v2/wallpull/studio/render") => {
            touch_peer_by_ip(&hub.state, &remote_addr.ip().to_string());
            let body = read_small_body(&mut stream, leftover, content_len, is_chunked, 2 * 1024 * 1024)?;
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct LanStudioRenderReq {
                id: String,
                visible_layers: Vec<usize>,
                max_dimension: Option<i32>,
                preserve_transparency: Option<bool>,
                trim_bounds: Option<bool>,
            }
            let Ok(req) = serde_json::from_slice::<LanStudioRenderReq>(&body) else {
                write_json_error(&mut stream, 400, "Invalid render payload")?;
                return Ok(());
            };
            let session = match get_or_open_lan_studio_session(hub, &req.id) {
                Ok(s) => s,
                Err(msg) => {
                    write_json_error(&mut stream, 404, &msg)?;
                    return Ok(());
                }
            };
            let vis_set: HashSet<usize> = req.visible_layers.into_iter().collect();
            let max_dim = req.max_dimension.unwrap_or(2048);
            let preserve_transparency = req.preserve_transparency.unwrap_or(true);
            let trim_bounds = req.trim_bounds.unwrap_or(false);
            match session.render_subset_to_png_bytes(&vis_set, max_dim, preserve_transparency, trim_bounds) {
                Ok((bytes, _)) => write_binary_response(&mut stream, "image/png", &bytes)?,
                Err(msg) => write_json_error(&mut stream, 500, &msg)?,
            }
        }
        ("GET", "/api/localsend/v2/wallpull/studio/offline-bundle") => {
            touch_peer_by_ip(&hub.state, &remote_addr.ip().to_string());
            let Some(id) = query.get("id") else {
                write_json_error(&mut stream, 400, "Missing id")?;
                return Ok(());
            };
            let session = match get_or_open_lan_studio_session(hub, id) {
                Ok(s) => s,
                Err(msg) => {
                    write_json_error(&mut stream, 404, &msg)?;
                    return Ok(());
                }
            };
            let rendered_groups = render_studio_offline_groups(&session);
            #[derive(Serialize)]
            #[serde(rename_all = "camelCase")]
            struct OfflineBundleResp<'a> {
                manifest: &'a SceneLayerManifest,
                groups: Vec<OfflineGroupPayload>,
            }
            write_json_response(
                &mut stream,
                200,
                &OfflineBundleResp {
                    manifest: &session.manifest,
                    groups: rendered_groups,
                },
            )?;
        }
        _ => {
            write_json_error(&mut stream, 404, "Not Found")?;
        }
    }
    Ok(())
}

fn run_udp_multicast_loop(hub: Arc<LocalSendHub>) {
    let Ok(sock) = create_reuseaddr_udp_socket(LOCALSEND_DEFAULT_PORT) else {
        return;
    };
    let _ = sock.set_read_timeout(Some(Duration::from_millis(500)));
    let _ = sock.set_multicast_loop_v4(false);

    let mut last_join_check = Instant::now() - Duration::from_secs(30);
    let mut buf = [0u8; 8192];

    while !hub.stop.load(Ordering::SeqCst) {
        if last_join_check.elapsed() >= Duration::from_secs(15) {
            let ips = list_lan_ipv4s();
            for ip in &ips {
                let _ = sock.join_multicast_v4(&LOCALSEND_MULTICAST_IP, ip);
            }
            if ips.is_empty() {
                let _ = sock.join_multicast_v4(&LOCALSEND_MULTICAST_IP, &Ipv4Addr::UNSPECIFIED);
            }
            last_join_check = Instant::now();
        }

        let (n, src_addr) = match sock.recv_from(&mut buf) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let enabled = hub.state.read().map(|g| g.enabled).unwrap_or(false);
        if !enabled {
            continue;
        }
        let Ok(peer_info) = serde_json::from_slice::<LocalSendDeviceInfo>(&buf[..n]) else {
            continue;
        };
        let my_fp = hub.state.read().map(|g| g.fingerprint.clone()).unwrap_or_default();
        if peer_info.fingerprint == my_fp || !is_wallpull_device_info(&peer_info) {
            continue;
        }
        let peer_ip = src_addr.ip().to_string();
        let should_reply = peer_info.announce.unwrap_or(false);
        let peer_port = peer_info.port.unwrap_or(LOCALSEND_DEFAULT_PORT);
        let peer_proto = peer_info.protocol.clone().unwrap_or_else(|| "https".to_string());
        let changed = upsert_peer(&hub.state, peer_info, peer_ip.clone(), None, None);
        if changed {
            emit_event(&hub.event_cb, LocalSendEvent::PeersChanged);
        }

        if should_reply {
            let reply_info = hub.device_info(None);
            let udp_reply_info = hub.device_info(Some(false));
            std::thread::spawn(move || {
                let sent_ok = if peer_proto.eq_ignore_ascii_case("http") {
                    peer_ip
                        .parse::<Ipv4Addr>()
                        .ok()
                        .and_then(|ip| {
                            let body = serde_json::to_vec(&reply_info).ok()?;
                            lan_http_post_json(ip, peer_port, "/api/localsend/v2/register", &body, Duration::from_millis(800)).ok()
                        })
                        .is_some()
                } else {
                    let agent = build_lan_https_agent(Duration::from_millis(800));
                    let url = format!("{peer_proto}://{peer_ip}:{peer_port}/api/localsend/v2/register");
                    serde_json::to_value(&reply_info)
                        .ok()
                        .map(|val| agent.post(&url).send_json(val).is_ok())
                        .unwrap_or(false)
                };
                if !sent_ok {
                    if let Ok(payload) = serde_json::to_vec(&udp_reply_info) {
                        if let Ok(s) = UdpSocket::bind("0.0.0.0:0") {
                            let _ = s.send_to(
                                &payload,
                                SocketAddrV4::new(LOCALSEND_MULTICAST_IP, LOCALSEND_DEFAULT_PORT),
                            );
                        }
                    }
                }
            });
        }
    }
}

fn create_reuseaddr_udp_socket(port: u16) -> Result<UdpSocket, String> {
    unsafe {
        let mut wsa = WSADATA::default();
        let rc = WSAStartup(0x0202, &mut wsa);
        if rc != 0 {
            return Err(format!("WSAStartup failed: {rc}"));
        }
        let sock = socket(AF_INET.0 as i32, SOCK_DGRAM, IPPROTO_UDP.0)
            .map_err(|e| format!("socket failed: {e}"))?;
        if sock == INVALID_SOCKET {
            return Err("INVALID_SOCKET".to_string());
        }
        let opt_val: i32 = 1;
        let opt_bytes = opt_val.to_ne_bytes();
        let _ = setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, Some(&opt_bytes));

        let addr = SOCKADDR_IN {
            sin_family: AF_INET,
            sin_port: port.to_be(),
            sin_addr: IN_ADDR::default(),
            sin_zero: [0; 8],
        };
        if bind(
            sock,
            &addr as *const SOCKADDR_IN as *const SOCKADDR,
            size_of::<SOCKADDR_IN>() as i32,
        ) != 0
        {
            return Err("UDP bind failed".to_string());
        }
        Ok(UdpSocket::from_raw_socket(sock.0 as std::os::windows::io::RawSocket))
    }
}

pub fn list_lan_ipv4s() -> Vec<Ipv4Addr> {
    let mut set: HashSet<Ipv4Addr> = HashSet::new();
    let mut wsa = WSADATA::default();
    unsafe {
        let _ = WSAStartup(0x0202, &mut wsa);
    }
    let mut host_buf = [0u8; 256];
    let rc = unsafe { gethostname(&mut host_buf) };
    if rc == 0 {
        let nul = host_buf.iter().position(|&b| b == 0).unwrap_or(host_buf.len());
        if let Ok(hostname) = std::str::from_utf8(&host_buf[..nul]) {
            if let Ok(addrs) = (hostname, 0u16).to_socket_addrs() {
                for sa in addrs {
                    if let SocketAddr::V4(v4) = sa {
                        let ip = *v4.ip();
                        if is_usable_lan_ipv4(ip) {
                            set.insert(ip);
                        }
                    }
                }
            }
        }
    }
    if let Ok(probe) = UdpSocket::bind("0.0.0.0:0") {
        if probe.connect(("239.255.77.88", LOCALSEND_DEFAULT_PORT)).is_ok() {
            if let Ok(SocketAddr::V4(v4)) = probe.local_addr() {
                let ip = *v4.ip();
                if is_usable_lan_ipv4(ip) {
                    set.insert(ip);
                }
            }
        }
    }
    let mut list: Vec<Ipv4Addr> = set.into_iter().collect();
    list.sort_by_key(|ip| {
        let o = ip.octets();
        let rank = if o[0] == 192 && o[1] == 168 {
            0
        } else if o[0] == 10 {
            1
        } else if o[0] == 172 && (16..=31).contains(&o[1]) {
            2
        } else {
            3
        };
        (rank, u32::from(*ip))
    });
    list
}

fn is_usable_lan_ipv4(ip: Ipv4Addr) -> bool {
    let o = ip.octets();
    if ip.is_loopback() || ip.is_unspecified() || ip.is_multicast() || ip.is_link_local() {
        return false;
    }
    // Filter out Clash/TUN Fake-IP 198.18.0.0/15
    if o[0] == 198 && (o[1] == 18 || o[1] == 19) {
        return false;
    }
    true
}

fn is_wallpull_device_info(info: &LocalSendDeviceInfo) -> bool {
    if info.wallpull_channel.as_deref() == Some(WALLPULL_LAN_CHANNEL) {
        return true;
    }
    info.device_model
        .as_deref()
        .map(|m| m.to_ascii_lowercase().contains("wallpull"))
        .unwrap_or(false)
}

fn is_peer_expired(peer: &LocalSendPeer, now_ms: u64) -> bool {
    let age = now_ms.saturating_sub(peer.last_seen_ms);
    if age > PEER_TTL_MS {
        return true;
    }
    peer.missed_probes >= PEER_MAX_MISSED_PROBES && age > PEER_HEARTBEAT_STALE_MS
}

fn touch_peer_by_ip(state: &Arc<RwLock<HubRuntimeState>>, ip: &str) {
    let now = now_ms();
    if let Ok(mut guard) = state.write() {
        for peer in guard.peers.values_mut() {
            if peer.ip == ip {
                peer.last_seen_ms = now;
                peer.missed_probes = 0;
            }
        }
    }
}

fn complete_session_file(state: &Arc<RwLock<HubRuntimeState>>, session_id: &str, file_id: &str) {
    if let Ok(mut guard) = state.write() {
        let should_remove = if let Some(sess) = guard.sessions.get_mut(session_id) {
            sess.files.remove(file_id);
            sess.files.is_empty()
        } else {
            false
        };
        if should_remove {
            guard.sessions.remove(session_id);
        }
    }
}

fn cleanup_expired_sessions(state: &Arc<RwLock<HubRuntimeState>>, now_ms: u64) {
    let stale_paths: Vec<PathBuf> = if let Ok(mut guard) = state.write() {
        let mut expired_ids = Vec::new();
        for (sid, sess) in &guard.sessions {
            if now_ms.saturating_sub(sess.created_at_ms) > SESSION_TTL_MS {
                expired_ids.push(sid.clone());
            }
        }
        let mut paths = Vec::new();
        for sid in expired_ids {
            if let Some(sess) = guard.sessions.remove(&sid) {
                paths.extend(sess.temp_paths);
            }
        }
        paths
    } else {
        Vec::new()
    };
    for p in stale_paths {
        let _ = fs::remove_file(p);
    }
}

fn upsert_peer(
    state: &Arc<RwLock<HubRuntimeState>>,
    info: LocalSendDeviceInfo,
    ip: String,
    port_override: Option<u16>,
    proto_override: Option<&str>,
) -> bool {
    if !is_wallpull_device_info(&info) {
        return false;
    }
    let port = port_override
        .or(info.port)
        .filter(|&p| p > 0)
        .unwrap_or(LOCALSEND_DEFAULT_PORT);
    let protocol = proto_override
        .or(info.protocol.as_deref())
        .map(|s| if s.eq_ignore_ascii_case("https") { "https" } else { "http" })
        .unwrap_or("http")
        .to_string();
    let model_lower = info
        .device_model
        .as_deref()
        .map(|m| m.to_ascii_lowercase())
        .unwrap_or_default();
    let type_lower = info
        .device_type
        .as_deref()
        .map(|t| t.to_ascii_lowercase())
        .unwrap_or_default();
    let is_wallpull_ipad = model_lower.contains("ipad")
        || type_lower == "mobile"
        || (!model_lower.contains("windows") && !model_lower.contains("pc") && type_lower != "desktop" && model_lower.contains("wallpull"));
    // Never register this same PC as an external peer
    if !cfg!(test)
        && (ip == "127.0.0.1" || list_lan_ipv4s().iter().any(|local| local.to_string() == ip))
    {
        return false;
    }
    let peer = LocalSendPeer {
        fingerprint: info.fingerprint.clone(),
        alias: info.alias,
        device_model: info.device_model,
        device_type: info.device_type,
        ip: ip.clone(),
        port,
        protocol,
        download: info.download,
        is_wallpull_ipad,
        last_seen_ms: now_ms(),
        missed_probes: 0,
    };
    let mut guard = state.write().unwrap_or_else(|e| e.into_inner());
    if let Ok(parsed_ip) = ip.parse::<Ipv4Addr>() {
        if guard.known_endpoints.len() >= 16 {
            guard.known_endpoints.clear();
        }
        guard.known_endpoints.insert((parsed_ip, port));
    }
    let changed = guard
        .peers
        .get(&peer.fingerprint)
        .map(|prev| {
            prev.alias != peer.alias
                || prev.ip != peer.ip
                || prev.port != peer.port
                || prev.protocol != peer.protocol
        })
        .unwrap_or(true);
    guard.peers.insert(peer.fingerprint.clone(), peer);
    changed
}

fn emit_event(
    cb: &Arc<Mutex<Option<Box<dyn Fn(LocalSendEvent) + Send + Sync>>>>,
    event: LocalSendEvent,
) {
    if let Ok(guard) = cb.lock() {
        if let Some(f) = guard.as_ref() {
            f(event);
        }
    }
}

fn get_or_build_lan_thumb(entry: &CatalogEntry) -> Result<Vec<u8>, String> {
    let cache_dir = cache_root().join("lan-thumbs-v2");
    let _ = fs::create_dir_all(&cache_dir);
    let safe_id = get_safe_file_name(&entry.id, "thumb");
    let cache_path = cache_dir.join(format!("{safe_id}.jpg"));
    if cache_path.is_file() {
        if let Ok(bytes) = fs::read(&cache_path) {
            if !bytes.is_empty() {
                return Ok(bytes);
            }
        }
    }

    let candidate_path = if entry.media_type == "image" && Path::new(&entry.source_path).is_file() {
        Path::new(&entry.source_path)
    } else if !entry.preview_path.is_empty() && Path::new(&entry.preview_path).is_file() {
        Path::new(&entry.preview_path)
    } else {
        return Err("No preview image".to_string());
    };

    let img = image::open(candidate_path).map_err(|e| e.to_string())?;
    let (w, h) = img.dimensions();
    let resized = if w > 1280 || h > 1280 {
        img.resize(1280, 1280, FilterType::Triangle)
    } else {
        img
    };
    let rgb = resized.to_rgb8();
    let mut out = Vec::new();
    let mut enc = JpegEncoder::new_with_quality(&mut out, 90);
    enc.encode_image(&rgb).map_err(|e| e.to_string())?;
    let _ = fs::write(&cache_path, &out);
    Ok(out)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OfflineGroupPayload {
    key: String,
    title: String,
    role: String,
    default_visible: bool,
    png_base64: String,
}

fn get_or_open_lan_studio_session(
    hub: &LocalSendHub,
    item_id: &str,
) -> Result<Arc<SceneStudioSession>, String> {
    {
        let guard = hub.state.read().map_err(|e| e.to_string())?;
        if let Some((cached_id, session)) = &guard.studio_cache {
            if cached_id == item_id {
                return Ok(session.clone());
            }
        }
    }
    let workshop_dir = {
        let guard = hub.state.read().map_err(|e| e.to_string())?;
        guard
            .catalog_by_id
            .get(item_id)
            .map(|e| e.workshop_directory.clone())
            .unwrap_or_default()
    };
    if workshop_dir.is_empty() {
        return Err("未找到对应的 2D 图层包目录".to_string());
    }
    let scene_pkg = Path::new(&workshop_dir).join("scene.pkg");
    let session = Arc::new(
        open_studio_session(&scene_pkg).ok_or_else(|| "当前壁纸不支持 2D 透视拆解".to_string())?,
    );
    if let Ok(mut guard) = hub.state.write() {
        guard.studio_cache = Some((item_id.to_string(), session.clone()));
    }
    Ok(session)
}

fn render_studio_offline_groups(session: &SceneStudioSession) -> Vec<OfflineGroupPayload> {
    session
        .manifest
        .groups
        .par_iter()
        .filter_map(|group| {
            let vis: HashSet<usize> = group.layer_indices.iter().copied().collect();
            let (bytes, r) = session
                .render_subset_to_png_bytes(&vis, 1920, true, false)
                .ok()?;
            if !r.has_pixels || bytes.is_empty() {
                return None;
            }
            Some(OfflineGroupPayload {
                key: group.key.clone(),
                title: group.title.clone(),
                role: group.role.clone(),
                default_visible: group.default_visible,
                png_base64: encode_base64(&bytes),
            })
        })
        .collect()
}

fn encode_base64(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(((input.len() + 2) / 3) * 4);
    for chunk in input.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = if chunk.len() > 1 { chunk[1] as u32 } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as u32 } else { 0 };
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(TABLE[((n >> 18) & 0x3F) as usize] as char);
        out.push(TABLE[((n >> 12) & 0x3F) as usize] as char);
        out.push(if chunk.len() > 1 { TABLE[((n >> 6) & 0x3F) as usize] as char } else { '=' });
        out.push(if chunk.len() > 2 { TABLE[(n & 0x3F) as usize] as char } else { '=' });
    }
    out
}

fn write_wav_pcm16_from_samples(
    dest: &Path,
    channels: u16,
    sample_rate: u32,
    samples_iter: impl Iterator<Item = i16>,
) -> Result<(), String> {
    let tmp = dest.with_extension("wav.part");
    let mut f = std::io::BufWriter::new(File::create(&tmp).map_err(|e| e.to_string())?);
    let ch = channels.max(1);
    let sr = sample_rate.max(8000);
    let byte_rate = sr * (ch as u32) * 2;
    let block_align = ch * 2;
    let mut hdr = [0u8; 44];
    hdr[0..4].copy_from_slice(b"RIFF");
    hdr[8..12].copy_from_slice(b"WAVE");
    hdr[12..16].copy_from_slice(b"fmt ");
    hdr[16..20].copy_from_slice(&16u32.to_le_bytes());
    hdr[20..22].copy_from_slice(&1u16.to_le_bytes());
    hdr[22..24].copy_from_slice(&ch.to_le_bytes());
    hdr[24..28].copy_from_slice(&sr.to_le_bytes());
    hdr[28..32].copy_from_slice(&byte_rate.to_le_bytes());
    hdr[32..34].copy_from_slice(&block_align.to_le_bytes());
    hdr[34..36].copy_from_slice(&16u16.to_le_bytes());
    hdr[36..40].copy_from_slice(b"data");
    f.write_all(&hdr).map_err(|e| e.to_string())?;

    let mut data_bytes: u32 = 0;
    for s in samples_iter {
        f.write_all(&s.to_le_bytes()).map_err(|e| e.to_string())?;
        data_bytes = data_bytes.saturating_add(2);
    }
    f.flush().map_err(|e| e.to_string())?;
    drop(f);

    let mut raw = fs::OpenOptions::new().write(true).open(&tmp).map_err(|e| e.to_string())?;
    raw.seek(SeekFrom::Start(4)).map_err(|e| e.to_string())?;
    raw.write_all(&data_bytes.saturating_add(36).to_le_bytes()).map_err(|e| e.to_string())?;
    raw.seek(SeekFrom::Start(40)).map_err(|e| e.to_string())?;
    raw.write_all(&data_bytes.to_le_bytes()).map_err(|e| e.to_string())?;
    drop(raw);

    if fs::rename(&tmp, dest).is_err() {
        fs::copy(&tmp, dest).map_err(|e| e.to_string())?;
        let _ = fs::remove_file(&tmp);
    }
    Ok(())
}

fn ensure_wav_from_ogg(item_id: &str, track_idx: usize, src_ogg: &Path) -> Result<PathBuf, String> {
    if !src_ogg.is_file() {
        return Err("音频源文件不存在".to_string());
    }
    let dir = cache_root().join("lan-audio");
    let _ = fs::create_dir_all(&dir);
    let safe_id = get_safe_file_name(item_id, "audio");
    let dest = dir.join(format!("{safe_id}_{track_idx}.wav"));
    if dest.is_file() && fs::metadata(&dest).map(|m| m.len() > 44).unwrap_or(false) {
        return Ok(dest);
    }
    let file = File::open(src_ogg).map_err(|e| e.to_string())?;
    let mut srr = lewton::inside_ogg::OggStreamReader::new(file)
        .map_err(|e| format!("解析 OGG 音频失败：{e:?}"))?;
    let channels = srr.ident_hdr.audio_channels as u16;
    let sample_rate = srr.ident_hdr.audio_sample_rate;
    let mut samples: Vec<i16> = Vec::new();
    while let Some(pkt) = srr
        .read_dec_packet_itl()
        .map_err(|e| format!("解码 OGG 音频帧失败：{e:?}"))?
    {
        samples.extend_from_slice(&pkt);
    }
    write_wav_pcm16_from_samples(&dest, channels, sample_rate, samples.into_iter())?;
    Ok(dest)
}

fn parse_ffprobe_fps(raw: &str) -> f64 {
    let trimmed = raw.trim();
    if let Some((num_s, den_s)) = trimmed.split_once('/') {
        let num = num_s.trim().parse::<f64>().unwrap_or(0.0);
        let den = den_s.trim().parse::<f64>().unwrap_or(1.0);
        if den > 0.0 { num / den } else { 0.0 }
    } else {
        trimmed.parse::<f64>().unwrap_or(0.0)
    }
}

enum IosMp4Action {
    Direct,
    RemuxHevcTag,
    TranscodeH264,
}

fn inspect_mp4_for_ios(src_path: &Path) -> IosMp4Action {
    let Some(ffprobe) = crate::media::find_executable("ffprobe.exe") else {
        return IosMp4Action::Direct;
    };
    let args = crate::process_runner::os_args([
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=codec_name,codec_tag_string,pix_fmt,r_frame_rate",
        "-of",
        "csv=p=0",
        src_path.to_str().unwrap_or_default(),
    ]);
    let Ok(out) = crate::process_runner::run_output(&ffprobe, &args, None, Duration::from_secs(10), None) else {
        return IosMp4Action::Direct;
    };
    let stdout = String::from_utf8_lossy(&out.stdout);
    let line = stdout.lines().next().unwrap_or("").trim();
    if line.is_empty() {
        return IosMp4Action::Direct;
    }
    let parts: Vec<&str> = line.split(',').map(str::trim).collect();
    if parts.len() < 4 {
        return IosMp4Action::Direct;
    }
    let codec = parts[0].to_ascii_lowercase();
    let tag = parts[1];
    let pix_fmt = parts[2].to_ascii_lowercase();
    let fps = parse_ffprobe_fps(parts[3]);
    let fps_ok = fps <= 62.0;

    if codec == "h264" && matches!(pix_fmt.as_str(), "yuv420p" | "yuvj420p") && fps_ok {
        return IosMp4Action::Direct;
    }
    if codec == "hevc" && fps_ok {
        if tag.eq_ignore_ascii_case("hvc1") {
            return IosMp4Action::Direct;
        }
        return IosMp4Action::RemuxHevcTag;
    }
    IosMp4Action::TranscodeH264
}

pub fn ensure_ios_compatible_mp4(
    item_id: &str,
    src_path: &Path,
    fallback_preview: Option<&str>,
) -> Result<PathBuf, String> {
    if !src_path.is_file() {
        return Err("视频源文件不存在".to_string());
    }
    let ext = src_path
        .extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default();
    let action = if matches!(ext.as_str(), "mp4" | "mov" | "m4v") {
        inspect_mp4_for_ios(src_path)
    } else {
        IosMp4Action::TranscodeH264
    };
    if matches!(action, IosMp4Action::Direct) {
        return Ok(src_path.to_path_buf());
    }

    let dir = cache_root().join("lan_ios_mp4_v2");
    let _ = fs::create_dir_all(&dir);
    let safe_id = get_safe_file_name(item_id, "video");
    let dest = dir.join(format!("{safe_id}.mp4"));
    if dest.is_file() && fs::metadata(&dest).map(|m| m.len() > 1024).unwrap_or(false) {
        return Ok(dest);
    }

    if let Some(ffmpeg) = crate::media::find_executable("ffmpeg.exe") {
        let tmp = dir.join(format!("{safe_id}_{}.part.mp4", generate_token()));
        let args = if matches!(action, IosMp4Action::RemuxHevcTag) {
            crate::process_runner::os_args([
                "-y",
                "-i",
                src_path.to_str().unwrap_or_default(),
                "-c",
                "copy",
                "-tag:v",
                "hvc1",
                "-movflags",
                "+faststart",
                tmp.to_str().unwrap_or_default(),
            ])
        } else {
            crate::process_runner::os_args([
                "-y",
                "-i",
                src_path.to_str().unwrap_or_default(),
                "-c:v",
                "libx264",
                "-preset",
                "veryfast",
                "-crf",
                "19",
                "-r",
                "60",
                "-pix_fmt",
                "yuv420p",
                "-movflags",
                "+faststart",
                "-c:a",
                "aac",
                "-b:a",
                "192k",
                tmp.to_str().unwrap_or_default(),
            ])
        };
        if matches!(
            crate::process_runner::run_status(&ffmpeg, &args, None, Duration::from_secs(90), None),
            Ok(true)
        ) {
            if tmp.is_file() && fs::metadata(&tmp).map(|m| m.len() > 1024).unwrap_or(false) {
                if fs::rename(&tmp, &dest).is_err() {
                    let _ = fs::copy(&tmp, &dest);
                    let _ = fs::remove_file(&tmp);
                }
                if dest.is_file() {
                    return Ok(dest);
                }
            }
        }
        let _ = fs::remove_file(&tmp);
    }

    if let Some(prev) = fallback_preview.map(Path::new).filter(|p| p.is_file()) {
        return Ok(prev.to_path_buf());
    }
    if matches!(ext.as_str(), "mp4" | "mov" | "m4v") {
        return Ok(src_path.to_path_buf());
    }
    Err("缺少 ffmpeg.exe，无法将该非 MP4 视频转为 iPad 兼容格式".to_string())
}

fn ensure_lan_preview_video(entry: &CatalogEntry) -> Result<PathBuf, String> {
    if entry.media_type != "video" {
        return Err("Not a video".to_string());
    }
    let has_ffmpeg = crate::media::find_executable("ffmpeg.exe");
    let existing_prev = entry.preview_video_path.as_deref().map(Path::new).filter(|p| p.is_file());
    if let Some(p) = existing_prev {
        let is_legacy_square = p
            .file_name()
            .and_then(|n| n.to_str())
            .map(|s| s.contains("-square-") || s.contains("-480p-"))
            .unwrap_or(false);
        if !is_legacy_square || has_ffmpeg.is_none() {
            return Ok(p.to_path_buf());
        }
    }
    let src = Path::new(&entry.source_path);
    if !src.is_file() {
        if let Some(p) = existing_prev {
            return Ok(p.to_path_buf());
        }
        return Err("Source video missing".to_string());
    }
    let dir = cache_root().join("lan_preview_mp4_v3");
    let _ = fs::create_dir_all(&dir);
    let safe_id = get_safe_file_name(&entry.id, "prev");
    let dest = dir.join(format!("{safe_id}.mp4"));
    if dest.is_file() && fs::metadata(&dest).map(|m| m.len() > 1024).unwrap_or(false) {
        return Ok(dest);
    }
    if let Some(ffmpeg) = has_ffmpeg {
        let tmp = dir.join(format!("{safe_id}_{}.part.mp4", generate_token()));
        let args = crate::process_runner::os_args([
            "-y",
            "-t",
            "12",
            "-i",
            src.to_str().unwrap_or_default(),
            "-an",
            "-vf",
            "scale='min(1280,iw)':-2",
            "-r",
            "30",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-crf",
            "21",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            tmp.to_str().unwrap_or_default(),
        ]);
        if matches!(
            crate::process_runner::run_status(&ffmpeg, &args, None, Duration::from_secs(45), None),
            Ok(true)
        ) {
            if tmp.is_file() && fs::metadata(&tmp).map(|m| m.len() > 1024).unwrap_or(false) {
                if fs::rename(&tmp, &dest).is_err() {
                    let _ = fs::copy(&tmp, &dest);
                    let _ = fs::remove_file(&tmp);
                }
                if dest.is_file() {
                    return Ok(dest);
                }
            }
        }
        let _ = fs::remove_file(&tmp);
    }
    if let Some(p) = existing_prev {
        return Ok(p.to_path_buf());
    }
    ensure_ios_compatible_mp4(&entry.id, src, None)
}

fn audio_mime_for_ext(ext: &str) -> &'static str {
    match ext {
        "mp3" => "audio/mpeg",
        "wav" => "audio/wav",
        "m4a" | "aac" => "audio/mp4",
        "flac" => "audio/flac",
        "ogg" => "audio/ogg",
        _ => "application/octet-stream",
    }
}

fn serve_file_with_range(
    stream: &mut TcpStream,
    path: &Path,
    mime_type: &str,
    range_header: Option<&str>,
) -> Result<(), String> {
    if !path.is_file() {
        write_json_error(stream, 404, "File not found")?;
        return Ok(());
    }
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    let total_len = file.metadata().map(|m| m.len()).map_err(|e| e.to_string())?;
    let (start, end, is_partial) = if let Some(rh) = range_header {
        if let Some((s, e)) = parse_byte_range(rh, total_len) {
            (s, e, true)
        } else {
            let hdr = format!(
                "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{total_len}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            );
            stream.write_all(hdr.as_bytes()).map_err(|e| e.to_string())?;
            return Ok(());
        }
    } else {
        (0, total_len.saturating_sub(1), false)
    };

    let content_len = if total_len == 0 { 0 } else { end - start + 1 };
    let status_line = if is_partial {
        "HTTP/1.1 206 Partial Content"
    } else {
        "HTTP/1.1 200 OK"
    };
    let mut hdr = format!(
        "{status_line}\r\nContent-Type: {mime_type}\r\nAccept-Ranges: bytes\r\nContent-Length: {content_len}\r\nCache-Control: no-store\r\nConnection: close\r\n"
    );
    if is_partial {
        hdr.push_str(&format!("Content-Range: bytes {start}-{end}/{total_len}\r\n"));
    }
    hdr.push_str("\r\n");
    stream.write_all(hdr.as_bytes()).map_err(|e| e.to_string())?;

    if content_len > 0 {
        file.seek(SeekFrom::Start(start)).map_err(|e| e.to_string())?;
        let mut remaining = content_len;
        let mut buf = [0u8; 64 * 1024];
        while remaining > 0 {
            let to_read = (remaining as usize).min(buf.len());
            let n = file.read(&mut buf[..to_read]).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            stream.write_all(&buf[..n]).map_err(|e| e.to_string())?;
            remaining -= n as u64;
        }
    }
    stream.flush().map_err(|e| e.to_string())
}

fn parse_byte_range(header: &str, total_len: u64) -> Option<(u64, u64)> {
    if total_len == 0 {
        return None;
    }
    let spec = header.trim().strip_prefix("bytes=")?;
    let first = spec.split(',').next()?.trim();
    let (start_str, end_str) = first.split_once('-')?;
    if start_str.is_empty() {
        let suffix: u64 = end_str.trim().parse().ok()?;
        if suffix == 0 {
            return None;
        }
        let start = total_len.saturating_sub(suffix);
        return Some((start, total_len - 1));
    }
    let start: u64 = start_str.trim().parse().ok()?;
    if start >= total_len {
        return None;
    }
    let end = if end_str.trim().is_empty() {
        total_len - 1
    } else {
        end_str.trim().parse::<u64>().ok()?.min(total_len - 1)
    };
    if end < start {
        return None;
    }
    Some((start, end))
}

fn stream_body_to_file(
    stream: &mut TcpStream,
    leftover: &[u8],
    content_len: Option<u64>,
    is_chunked: bool,
    dest: &Path,
) -> Result<String, String> {
    let mut out = File::create(dest).map_err(|e| e.to_string())?;
    let mut hasher = Sha256::new();
    let mut reader = std::io::Read::chain(std::io::Cursor::new(leftover), stream);

    if is_chunked {
        let mut buf_reader = BufReader::new(reader);
        loop {
            let mut size_line = String::new();
            std::io::BufRead::read_line(&mut buf_reader, &mut size_line).map_err(|e| e.to_string())?;
            let hex_part = size_line.trim().split(';').next().unwrap_or("").trim();
            let chunk_size = usize::from_str_radix(hex_part, 16)
                .map_err(|_| "Invalid chunk size".to_string())?;
            if chunk_size == 0 {
                break;
            }
            let mut rem = chunk_size;
            let mut buf = [0u8; 64 * 1024];
            while rem > 0 {
                let to_read = rem.min(buf.len());
                buf_reader
                    .read_exact(&mut buf[..to_read])
                    .map_err(|e| e.to_string())?;
                hasher.update(&buf[..to_read]);
                out.write_all(&buf[..to_read]).map_err(|e| e.to_string())?;
                rem -= to_read;
            }
            let mut crlf = [0u8; 2];
            buf_reader.read_exact(&mut crlf).map_err(|e| e.to_string())?;
        }
    } else if let Some(mut remaining) = content_len {
        let mut buf = [0u8; 64 * 1024];
        while remaining > 0 {
            let to_read = (remaining as usize).min(buf.len());
            let n = reader.read(&mut buf[..to_read]).map_err(|e| e.to_string())?;
            if n == 0 {
                return Err("Unexpected EOF before Content-Length completed".to_string());
            }
            hasher.update(&buf[..n]);
            out.write_all(&buf[..n]).map_err(|e| e.to_string())?;
            remaining -= n as u64;
        }
    } else {
        let mut buf = [0u8; 64 * 1024];
        loop {
            let n = reader.read(&mut buf).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
            out.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        }
    }
    out.flush().map_err(|e| e.to_string())?;
    Ok(hex::encode(hasher.finalize()))
}

fn read_small_body(
    stream: &mut TcpStream,
    leftover: &[u8],
    content_len: Option<u64>,
    is_chunked: bool,
    max_bytes: usize,
) -> Result<Vec<u8>, String> {
    let mut reader = std::io::Read::chain(std::io::Cursor::new(leftover), stream);
    let mut data = Vec::new();
    if is_chunked {
        let mut buf_reader = BufReader::new(reader);
        loop {
            let mut size_line = String::new();
            std::io::BufRead::read_line(&mut buf_reader, &mut size_line).map_err(|e| e.to_string())?;
            let hex_part = size_line.trim().split(';').next().unwrap_or("").trim();
            let chunk_size = usize::from_str_radix(hex_part, 16).map_err(|_| "Invalid chunk".to_string())?;
            if chunk_size == 0 {
                break;
            }
            if data.len() + chunk_size > max_bytes {
                return Err("Payload too large".to_string());
            }
            let start = data.len();
            data.resize(start + chunk_size, 0);
            buf_reader.read_exact(&mut data[start..]).map_err(|e| e.to_string())?;
            let mut crlf = [0u8; 2];
            buf_reader.read_exact(&mut crlf).map_err(|e| e.to_string())?;
        }
    } else if let Some(len) = content_len {
        let len_usize = usize::try_from(len).map_err(|_| "Payload too large".to_string())?;
        if len_usize > max_bytes {
            return Err("Payload too large".to_string());
        }
        data.resize(len_usize, 0);
        reader.read_exact(&mut data).map_err(|e| e.to_string())?;
    }
    Ok(data)
}

fn compute_source_metrics(source: &TransferSource) -> Result<(u64, String), String> {
    let mut hasher = Sha256::new();
    match source {
        TransferSource::Memory(bytes) => {
            hasher.update(bytes.as_slice());
            Ok((bytes.len() as u64, hex::encode(hasher.finalize())))
        }
        TransferSource::File(path) => {
            if !path.is_file() {
                return Err(format!("源文件不存在：{}", path.display()));
            }
            let mut f = File::open(path).map_err(|e| e.to_string())?;
            let len = f.metadata().map(|m| m.len()).map_err(|e| e.to_string())?;
            let mut buf = [0u8; 64 * 1024];
            loop {
                let n = f.read(&mut buf).map_err(|e| e.to_string())?;
                if n == 0 {
                    break;
                }
                hasher.update(&buf[..n]);
            }
            Ok((len, hex::encode(hasher.finalize())))
        }
    }
}

#[derive(Debug)]
struct AcceptLanSelfSignedCert;

impl ServerCertVerifier for AcceptLanSelfSignedCert {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

fn lan_tls_config() -> Option<&'static Arc<rustls::ClientConfig>> {
    static TLS_CFG: OnceLock<Option<Arc<rustls::ClientConfig>>> = OnceLock::new();
    TLS_CFG
        .get_or_init(|| {
            let provider = Arc::new(rustls::crypto::ring::default_provider());
            let cfg = rustls::ClientConfig::builder_with_provider(provider)
                .with_safe_default_protocol_versions()
                .ok()?
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(AcceptLanSelfSignedCert))
                .with_no_client_auth();
            Some(Arc::new(cfg))
        })
        .as_ref()
}

fn build_lan_https_agent(timeout: Duration) -> ureq::Agent {
    let mut builder = ureq::AgentBuilder::new()
        .timeout(timeout)
        .try_proxy_from_env(false);
    if let Some(tls) = lan_tls_config() {
        builder = builder.tls_config(tls.clone());
    }
    builder.build()
}

fn lan_http_post_json(
    ip: Ipv4Addr,
    port: u16,
    path: &str,
    json_body: &[u8],
    timeout: Duration,
) -> Result<(u16, Vec<u8>), String> {
    let addr = SocketAddr::V4(SocketAddrV4::new(ip, port));
    let mut stream = TcpStream::connect_timeout(&addr, timeout).map_err(|e| e.to_string())?;
    let _ = stream.set_nodelay(true);
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));
    let hdr = format!(
        "POST {path} HTTP/1.1\r\nHost: {ip}:{port}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        json_body.len()
    );
    stream.write_all(hdr.as_bytes()).map_err(|e| e.to_string())?;
    if !json_body.is_empty() {
        stream.write_all(json_body).map_err(|e| e.to_string())?;
    }
    stream.flush().map_err(|e| e.to_string())?;
    read_http_response(&mut stream)
}

fn lan_http_upload_bytes(
    ip: Ipv4Addr,
    port: u16,
    path: &str,
    bytes: &[u8],
    timeout: Duration,
) -> Result<(), String> {
    let addr = SocketAddr::V4(SocketAddrV4::new(ip, port));
    let mut stream = TcpStream::connect_timeout(&addr, timeout).map_err(|e| e.to_string())?;
    let _ = stream.set_nodelay(true);
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));
    let hdr = format!(
        "POST {path} HTTP/1.1\r\nHost: {ip}:{port}\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        bytes.len()
    );
    stream.write_all(hdr.as_bytes()).map_err(|e| e.to_string())?;
    for chunk in bytes.chunks(64 * 1024) {
        stream.write_all(chunk).map_err(|e| e.to_string())?;
    }
    stream.flush().map_err(|e| e.to_string())?;
    let (status, _) = read_http_response(&mut stream)?;
    if !(200..300).contains(&status) {
        return Err(format!("对端返回 HTTP {status}"));
    }
    Ok(())
}

fn lan_http_upload_file(
    ip: Ipv4Addr,
    port: u16,
    path: &str,
    file_path: &Path,
    size: u64,
    timeout: Duration,
) -> Result<(), String> {
    let mut f = File::open(file_path).map_err(|e| format!("打开待发文件失败：{e}"))?;
    let addr = SocketAddr::V4(SocketAddrV4::new(ip, port));
    let mut stream = TcpStream::connect_timeout(&addr, timeout).map_err(|e| e.to_string())?;
    let _ = stream.set_nodelay(true);
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));
    let hdr = format!(
        "POST {path} HTTP/1.1\r\nHost: {ip}:{port}\r\nContent-Type: application/octet-stream\r\nContent-Length: {size}\r\nConnection: close\r\n\r\n"
    );
    stream.write_all(hdr.as_bytes()).map_err(|e| e.to_string())?;
    let mut buf = [0u8; 64 * 1024];
    loop {
        let n = f.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        stream.write_all(&buf[..n]).map_err(|e| e.to_string())?;
    }
    stream.flush().map_err(|e| e.to_string())?;
    let (status, _) = read_http_response(&mut stream)?;
    if !(200..300).contains(&status) {
        return Err(format!("对端返回 HTTP {status}"));
    }
    Ok(())
}

fn read_http_response(stream: &mut TcpStream) -> Result<(u16, Vec<u8>), String> {
    let mut raw = Vec::with_capacity(4096);
    let mut buf = [0u8; 4096];
    let mut header_end: Option<usize> = None;
    let mut expected_content_len: Option<usize> = None;
    loop {
        if let Some(end) = header_end {
            if let Some(cl) = expected_content_len {
                if raw.len() >= end + cl {
                    break;
                }
            }
        }
        let n = stream.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        raw.extend_from_slice(&buf[..n]);
        if header_end.is_none() {
            if let Some(pos) = find_subsequence(&raw, b"\r\n\r\n") {
                let end = pos + 4;
                header_end = Some(end);
                let hdr_text = String::from_utf8_lossy(&raw[..pos]);
                for line in hdr_text.lines().skip(1) {
                    if let Some((k, v)) = line.split_once(':') {
                        if k.trim().eq_ignore_ascii_case("content-length") {
                            expected_content_len = v.trim().parse::<usize>().ok();
                        }
                    }
                }
                if let Some(cl) = expected_content_len {
                    if raw.len() >= end + cl {
                        break;
                    }
                }
            }
        }
        if raw.len() > 8 * 1024 * 1024 {
            return Err("Response too large".to_string());
        }
    }
    let split = header_end.ok_or_else(|| "Malformed HTTP response".to_string())?;
    let hdr_text = String::from_utf8_lossy(&raw[..split - 4]);
    let status = hdr_text
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|s| s.parse::<u16>().ok())
        .ok_or_else(|| "Missing HTTP status".to_string())?;
    let body_end = expected_content_len
        .map(|cl| (split + cl).min(raw.len()))
        .unwrap_or(raw.len());
    Ok((status, raw[split..body_end].to_vec()))
}

fn write_json_response<T: Serialize>(stream: &mut TcpStream, status: u16, value: &T) -> Result<(), String> {
    let body = serde_json::to_vec(value).map_err(|e| e.to_string())?;
    let reason = if status == 200 { "OK" } else { "Error" };
    let hdr = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(hdr.as_bytes()).map_err(|e| e.to_string())?;
    stream.write_all(&body).map_err(|e| e.to_string())?;
    stream.flush().map_err(|e| e.to_string())
}

fn write_binary_response(stream: &mut TcpStream, mime_type: &str, bytes: &[u8]) -> Result<(), String> {
    let hdr = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: {mime_type}\r\nContent-Length: {}\r\nCache-Control: max-age=3600\r\nConnection: close\r\n\r\n",
        bytes.len()
    );
    stream.write_all(hdr.as_bytes()).map_err(|e| e.to_string())?;
    stream.write_all(bytes).map_err(|e| e.to_string())?;
    stream.flush().map_err(|e| e.to_string())
}

fn write_json_error(stream: &mut TcpStream, status: u16, message: &str) -> Result<(), String> {
    let body = serde_json::to_vec(&serde_json::json!({ "message": message })).map_err(|e| e.to_string())?;
    let hdr = format!(
        "HTTP/1.1 {status} Error\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(hdr.as_bytes()).map_err(|e| e.to_string())?;
    stream.write_all(&body).map_err(|e| e.to_string())?;
    stream.flush().map_err(|e| e.to_string())
}

fn write_status_empty(stream: &mut TcpStream, status: u16, reason: &str) -> Result<(), String> {
    let hdr = format!("HTTP/1.1 {status} {reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    stream.write_all(hdr.as_bytes()).map_err(|e| e.to_string())?;
    stream.flush().map_err(|e| e.to_string())
}

fn parse_query_params(raw: &str) -> HashMap<String, String> {
    let mut map = HashMap::new();
    for pair in raw.split('&') {
        if pair.is_empty() {
            continue;
        }
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        let dk = urlencoding::decode(k).map(|s| s.into_owned()).unwrap_or_else(|_| k.to_string());
        let dv = urlencoding::decode(v).map(|s| s.into_owned()).unwrap_or_else(|_| v.to_string());
        map.insert(dk, dv);
    }
    map
}

fn find_subsequence(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn sanitize_incoming_filename(raw: &str) -> String {
    let base = Path::new(raw)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("wallpull_item.bin");
    let cleaned: String = base
        .chars()
        .map(|c| match c {
            '\\' | '/' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            c if c.is_control() => '_',
            c => c,
        })
        .collect();
    if cleaned.trim().is_empty() {
        "wallpull_item.bin".to_string()
    } else {
        cleaned
    }
}

pub fn mime_for_path(path: &Path, media_type: &str) -> String {
    match path
        .extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_ascii_lowercase())
        .as_deref()
    {
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("webp") => "image/webp",
        Some("gif") => "image/gif",
        Some("bmp") => "image/bmp",
        Some("mp4" | "m4v") => "video/mp4",
        Some("webm") => "video/webm",
        Some("mov") => "video/quicktime",
        _ if media_type == "video" => "video/mp4",
        _ => "application/octet-stream",
    }
    .to_string()
}

fn clean_alias(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        "WallPull PC".to_string()
    } else {
        trimmed.chars().take(48).collect()
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn generate_token() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{nanos:x}-{}", std::process::id())
}

fn generate_fingerprint() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut h = Sha256::new();
    h.update(format!("wallpull-pc-{nanos}-{}", std::process::id()).as_bytes());
    hex::encode(h.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn byte_range_parser_handles_bounds() {
        assert_eq!(parse_byte_range("bytes=0-99", 500), Some((0, 99)));
        assert_eq!(parse_byte_range("bytes=100-", 500), Some((100, 499)));
        assert_eq!(parse_byte_range("bytes=-50", 500), Some((450, 499)));
        assert_eq!(parse_byte_range("bytes=500-600", 500), None);
    }

    #[test]
    fn localsend_v2_handshake_and_upload_roundtrip_with_sha256() {
        let tmp_dir = std::env::temp_dir().join(format!("wp_ls_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp_dir);
        fs::create_dir_all(&tmp_dir).unwrap();

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();

        let hub = LocalSendHub::start(
            true,
            "TestReceiver",
            tmp_dir.to_str().unwrap(),
            false,
            |_| {},
        );
        {
            let mut g = hub.state.write().unwrap();
            g.port = port;
        }
        let hub_srv = hub.clone();
        std::thread::spawn(move || {
            run_http_accept_loop(hub_srv, listener);
        });

        let payload = vec![0x5Au8; 640 * 1024];
        let peer = LocalSendPeer {
            fingerprint: "receiver-fp".into(),
            alias: "TestReceiver".into(),
            device_model: Some("WallPull iPad".into()),
            device_type: Some("mobile".into()),
            ip: "127.0.0.1".into(),
            port,
            protocol: "http".into(),
            download: true,
            is_wallpull_ipad: true,
            last_seen_ms: now_ms(),
            missed_probes: 0,
        };
        let files = vec![OutgoingTransferFile {
            id: "f1".into(),
            file_name: "hero.png".into(),
            mime_type: "image/png".into(),
            source: TransferSource::Memory(Arc::new(payload.clone())),
            wallpull_target: "vault".into(),
            wallpull_kind: "wallpaper".into(),
            wallpull_title: "Hero".into(),
            wallpull_resolution: Some("3840 × 2160".into()),
            wallpull_item_id: Some("item-hero".into()),
            wallpull_has_scene_layers: false,
            wallpull_content_rating: Some("Everyone".into()),
        }];

        let sender = LocalSendHub::start(true, "TestSender", tmp_dir.to_str().unwrap(), false, |_| {});
        let msg = sender.send_files_to_peer(&peer, &files).unwrap();
        assert!(msg.contains("WallPull"));

        let received = fs::read(tmp_dir.join("LocalSend接收").join("hero.png")).unwrap();
        assert_eq!(received.len(), payload.len());
        assert_eq!(received, payload);

        hub.stop();
        sender.stop();
        let _ = fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    fn wallpull_asset_serves_large_206_range_without_truncation() {
        let tmp_dir = std::env::temp_dir().join(format!("wp_ls_range_{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp_dir);
        fs::create_dir_all(&tmp_dir).unwrap();
        let asset_path = tmp_dir.join("clip.mp4");
        let raw: Vec<u8> = (0..(720 * 1024)).map(|i| (i % 251) as u8).collect();
        fs::write(&asset_path, &raw).unwrap();
        let preview_path = tmp_dir.join("clip-480p.mp4");
        let prev_raw: Vec<u8> = (0..8192).map(|i| ((i * 3) % 251) as u8).collect();
        fs::write(&preview_path, &prev_raw).unwrap();

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let hub = LocalSendHub::start(true, "Host", tmp_dir.to_str().unwrap(), false, |_| {});
        {
            let mut g = hub.state.write().unwrap();
            g.port = port;
            let entry = CatalogEntry {
                id: "item-1".into(),
                workshop_id: "1".into(),
                title: "Clip".into(),
                media_type: "video".into(),
                resolution: Some("1920 × 1080".into()),
                duration: Some("0:10".into()),
                file_size: raw.len() as i64,
                color_bucket: None,
                file_name: "clip.mp4".into(),
                mime_type: "video/mp4".into(),
                content_rating: "Questionable".into(),
                has_preview_video: true,
                has_scene_layers: false,
                asset_count: 1,
                audio_tracks: Vec::new(),
                source_path: asset_path.to_string_lossy().into_owned(),
                asset_paths: vec![asset_path.to_string_lossy().into_owned()],
                preview_path: String::new(),
                preview_video_path: Some(preview_path.to_string_lossy().into_owned()),
                workshop_directory: String::new(),
            };
            g.catalog_by_id.insert("item-1".into(), entry.clone());
            g.catalog.push(entry);
        }
        let hub_srv = hub.clone();
        std::thread::spawn(move || {
            run_http_accept_loop(hub_srv, listener);
        });

        let resp = ureq::get(&format!("http://127.0.0.1:{port}/api/localsend/v2/wallpull/asset?id=item-1"))
            .set("Range", "bytes=100000-499999")
            .call()
            .unwrap();
        assert_eq!(resp.status(), 206);
        let mut got = Vec::new();
        resp.into_reader().read_to_end(&mut got).unwrap();
        assert_eq!(got.len(), 400_000);
        assert_eq!(got, raw[100_000..500_000]);

        let prev_resp = ureq::get(&format!("http://127.0.0.1:{port}/api/localsend/v2/wallpull/preview-video?id=item-1"))
            .call()
            .unwrap();
        assert_eq!(prev_resp.status(), 200);
        let mut prev_got = Vec::new();
        prev_resp.into_reader().read_to_end(&mut prev_got).unwrap();
        assert_eq!(prev_got, prev_raw);

        hub.stop();
        let _ = fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    fn wav_pcm16_writer_writes_valid_riff_header_and_base64() {
        let tmp_dir = std::env::temp_dir().join(format!("wp_wav_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp_dir);
        fs::create_dir_all(&tmp_dir).unwrap();
        let wav = tmp_dir.join("bgm.wav");
        write_wav_pcm16_from_samples(&wav, 2, 44100, [100i16, -200, 300, -400].into_iter()).unwrap();
        let bytes = fs::read(&wav).unwrap();
        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(&bytes[8..12], b"WAVE");
        assert_eq!(&bytes[36..40], b"data");
        assert_eq!(u32::from_le_bytes(bytes[40..44].try_into().unwrap()), 8);
        assert_eq!(encode_base64(b"WallPull"), "V2FsbFB1bGw=");
        let _ = fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    fn rejects_non_wallpull_localsend_peers_on_channel() {
        let tmp_dir = std::env::temp_dir().join(format!("wp_ch_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp_dir);
        fs::create_dir_all(&tmp_dir).unwrap();
        let hub = LocalSendHub::start(true, "Host", tmp_dir.to_str().unwrap(), false, |_| {});

        let generic_loca = LocalSendDeviceInfo {
            alias: "Desktop-LOCA".into(),
            version: "2.1".into(),
            device_model: Some("Windows".into()),
            device_type: Some("desktop".into()),
            fingerprint: "loca-generic-fp".into(),
            port: Some(53317),
            protocol: Some("https".into()),
            download: false,
            announce: None,
            wallpull_channel: None,
        };
        assert!(!upsert_peer(&hub.state, generic_loca, "192.168.1.55".into(), None, None));
        assert!(hub.peers_snapshot().is_empty());

        let wallpull_ipad = LocalSendDeviceInfo {
            alias: "My iPad".into(),
            version: "2.1".into(),
            device_model: Some("WallPull iPad".into()),
            device_type: Some("mobile".into()),
            fingerprint: "wp-ipad-fp".into(),
            port: Some(LOCALSEND_DEFAULT_PORT),
            protocol: Some("http".into()),
            download: false,
            announce: None,
            wallpull_channel: Some(WALLPULL_LAN_CHANNEL.into()),
        };
        assert!(upsert_peer(&hub.state, wallpull_ipad, "192.168.1.88".into(), None, None));
        let peers = hub.peers_snapshot();
        assert_eq!(peers.len(), 1);
        assert!(peers[0].is_wallpull_ipad);

        // Another WallPull Windows PC must NOT be flagged as is_wallpull_ipad
        let other_pc = LocalSendDeviceInfo {
            alias: "Other PC".into(),
            version: "2.1".into(),
            device_model: Some("WallPull Windows".into()),
            device_type: Some("desktop".into()),
            fingerprint: "wp-pc2-fp".into(),
            port: Some(LOCALSEND_DEFAULT_PORT),
            protocol: Some("http".into()),
            download: true,
            announce: None,
            wallpull_channel: Some(WALLPULL_LAN_CHANNEL.into()),
        };
        assert!(upsert_peer(&hub.state, other_pc, "192.168.1.99".into(), None, None));
        let pc_peer = hub.state.read().unwrap().peers.get("wp-pc2-fp").cloned().unwrap();
        assert!(!pc_peer.is_wallpull_ipad);

        // Missed probes only evict after >= 3 misses AND stale window; touch_peer_by_ip resets misses
        {
            let mut g = hub.state.write().unwrap();
            let p = g.peers.get_mut("wp-ipad-fp").unwrap();
            p.missed_probes = 3;
            p.last_seen_ms = now_ms().saturating_sub(PEER_HEARTBEAT_STALE_MS + 1000);
        }
        assert!(hub.peers_snapshot().len() == 1); // wp-ipad-fp evicted, wp-pc2-fp kept
        {
            let mut g = hub.state.write().unwrap();
            let p = g.peers.get_mut("wp-pc2-fp").unwrap();
            p.missed_probes = 2;
        }
        touch_peer_by_ip(&hub.state, "192.168.1.99");
        let touched = hub.state.read().unwrap().peers.get("wp-pc2-fp").cloned().unwrap();
        assert_eq!(touched.missed_probes, 0);

        // Session cleanup helper drops completed session once last file finishes
        {
            let mut g = hub.state.write().unwrap();
            let mut files = HashMap::new();
            files.insert(
                "f1".to_string(),
                PendingUploadFile {
                    dto: IncomingFileDto {
                        id: "f1".into(),
                        file_name: "a.png".into(),
                        size: 10,
                        file_type: "image/png".into(),
                        sha256: None,
                        preview: None,
                        metadata: None,
                    },
                    token: "tok".into(),
                },
            );
            g.sessions.insert(
                "sess-1".into(),
                UploadSession {
                    sender_alias: "Test".into(),
                    files,
                    temp_paths: Vec::new(),
                    created_at_ms: now_ms(),
                },
            );
        }
        complete_session_file(&hub.state, "sess-1", "f1");
        assert!(!hub.state.read().unwrap().sessions.contains_key("sess-1"));

        hub.stop();
        let _ = fs::remove_dir_all(&tmp_dir);
    }
}
