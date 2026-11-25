import AVFoundation
import CryptoKit
import Darwin
import Foundation
import UIKit

final class LocalSendInsecureLanDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

final class LocalSendRuntimeState: @unchecked Sendable {
    struct SessionItem {
        let fileName: String
        let fileType: String
        let expectedSha256: String?
        let token: String
        let target: String
        let kind: String
        let title: String?
        let remoteID: String?
        let hasSceneLayers: Bool
        let contentRating: String?
    }

    struct UploadSession {
        let senderAlias: String
        var files: [String: SessionItem]
        let createdAt: Date
    }

    private let lock = NSLock()
    let fingerprint: String
    private var stopFlag = false
    private var httpFD: Int32 = -1
    private var udpFD: Int32 = -1
    private var alias: String
    private var port: Int = LocalSendService.wallpullDefaultPort
    private var sessions: [String: UploadSession] = [:]

    init(fingerprint: String, alias: String) {
        self.fingerprint = fingerprint
        self.alias = alias
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopFlag
    }

    var isHTTPBound: Bool {
        lock.lock()
        let fd = httpFD
        lock.unlock()
        return fd >= 0 && Darwin.fcntl(fd, F_GETFD) != -1
    }

    var isUDPBound: Bool {
        lock.lock()
        let fd = udpFD
        lock.unlock()
        return fd >= 0 && Darwin.fcntl(fd, F_GETFD) != -1
    }

    func setUDPFD(_ fd: Int32) {
        lock.lock()
        if udpFD >= 0 && udpFD != fd {
            Darwin.close(udpFD)
        }
        udpFD = fd
        lock.unlock()
    }

    func clearUDPFDIfMatches(_ fd: Int32) {
        lock.lock()
        if udpFD == fd { udpFD = -1 }
        lock.unlock()
    }

    func setHTTP(_ fd: Int32, port: Int) {
        lock.lock()
        if httpFD >= 0 && httpFD != fd {
            Darwin.close(httpFD)
        }
        httpFD = fd
        self.port = port
        lock.unlock()
    }

    func clearHTTPFDIfMatches(_ fd: Int32) {
        lock.lock()
        if httpFD == fd { httpFD = -1 }
        lock.unlock()
    }

    func updateAlias(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        alias = trimmed.isEmpty ? "WallPull iPad" : trimmed
        lock.unlock()
    }

    func deviceInfo(announce: Bool? = nil) -> LocalSendDeviceInfo {
        lock.lock()
        let a = alias
        let p = port
        lock.unlock()
        return LocalSendDeviceInfo(
            alias: a,
            version: "2.1",
            deviceModel: "WallPull iPad",
            deviceType: "mobile",
            fingerprint: fingerprint,
            port: p,
            protocolName: "http",
            download: false,
            announce: announce,
            wallpullChannel: LocalSendService.wallpullChannelID
        )
    }

    func createSession(id: String, session: UploadSession) {
        lock.lock()
        sessions[id] = session
        lock.unlock()
    }

    func session(for id: String) -> UploadSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[id]
    }

    func completeSessionFile(id: String, fileId: String) {
        lock.lock()
        if var sess = sessions[id] {
            sess.files.removeValue(forKey: fileId)
            if sess.files.isEmpty {
                sessions.removeValue(forKey: id)
            } else {
                sessions[id] = sess
            }
        }
        lock.unlock()
    }

    func pruneExpiredSessions(maxAge: TimeInterval = 1800) {
        let cutoff = Date().addingTimeInterval(-maxAge)
        lock.lock()
        sessions = sessions.filter { $0.value.createdAt >= cutoff }
        lock.unlock()
    }

    func removeSession(id: String) {
        lock.lock()
        sessions.removeValue(forKey: id)
        lock.unlock()
    }
}

@MainActor
final class LocalSendService: ObservableObject {
    nonisolated static let wallpullMulticastIP = "239.255.77.88"
    nonisolated static let wallpullDefaultPort = 53417
    nonisolated static let wallpullChannelID = "wallpull-lan-v2"

    @Published var peers: [LocalSendPeer] = []
    @Published var localIP: String = "未连接 Wi-Fi"
    @Published var listeningPort: Int = LocalSendService.wallpullDefaultPort
    @Published var transferProgress: TransferProgressState? = nil
    @Published var canCancelTransfer: Bool = false
    @Published var pcCatalog: [PCCatalogItem] = []
    @Published var isScanning: Bool = false
    @Published var isLoadingCatalog: Bool = false

    let fingerprint: String
    nonisolated let runtime: LocalSendRuntimeState
    private weak var vault: LocalVaultStore?
    private var beaconTask: Task<Void, Never>? = nil
    private var selectedPeerFingerprint: String? = nil
    private var transferCancelled: Bool = false
    private var isStartingHTTP: Bool = false
    private var isStartingUDP: Bool = false
    private let lastEndpointsKey = "wp_last_peer_endpoints"
    private var lastKnownEndpoints: [String] = []
    private let thumbMemCache = NSCache<NSString, UIImage>()

    func cancelActiveTransfer() {
        transferCancelled = true
        vault?.showToast("正在安全停止当前传输…")
    }

    lazy var lanURLSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 180
        return URLSession(configuration: cfg, delegate: LocalSendInsecureLanDelegate(), delegateQueue: nil)
    }()

    var primaryPCPeer: LocalSendPeer? {
        if let sel = selectedPeerFingerprint, let found = peers.first(where: { $0.fingerprint == sel }) {
            return found
        }
        return peers.first(where: { $0.isWallPullPC }) ?? peers.first
    }

    init(vault: LocalVaultStore) {
        self.vault = vault
        let fp = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        self.fingerprint = fp
        let initialAlias = vault.deviceAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        self.runtime = LocalSendRuntimeState(
            fingerprint: fp,
            alias: initialAlias.isEmpty ? UIDevice.current.name : initialAlias
        )
        self.lastKnownEndpoints = UserDefaults.standard.stringArray(forKey: "wp_last_peer_endpoints") ?? []
        let rt = self.runtime
        vault.onAliasChanged = { newAlias in
            rt.updateAlias(newAlias)
        }
    }

    nonisolated private func snapshotDeviceInfo(announce: Bool? = nil) -> LocalSendDeviceInfo {
        runtime.deviceInfo(announce: announce)
    }

    func selectPeer(_ peer: LocalSendPeer) {
        selectedPeerFingerprint = peer.fingerprint
        objectWillChange.send()
    }

    func start() {
        refreshLocalIP()
        if !runtime.isHTTPBound && !isStartingHTTP {
            startHTTPServer()
        }
        if !runtime.isUDPBound && !isStartingUDP {
            startUDPMulticast()
        }
        beaconTask?.cancel()
        beaconTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            await heartbeatPeersAndEndpoints()
            await scanNetwork()
            while !Task.isCancelled {
                sendMulticastAnnouncement(announce: true)
                await heartbeatPeersAndEndpoints()
                try? await Task.sleep(nanoseconds: 6_000_000_000)
            }
        }
    }

    func handleAppDidBecomeActive() {
        refreshLocalIP()
        if !runtime.isHTTPBound && !isStartingHTTP {
            startHTTPServer()
        }
        if !runtime.isUDPBound && !isStartingUDP {
            startUDPMulticast()
        }
        sendMulticastAnnouncement(announce: true)
        Task { [weak self] in
            guard let self else { return }
            await self.heartbeatPeersAndEndpoints()
            if self.peers.isEmpty {
                await self.scanNetwork()
            }
        }
    }

    func refreshLocalIP() {
        localIP = Self.detectPhysicalWiFiIPv4() ?? "未连接 Wi-Fi"
    }

    func deviceInfo(announce: Bool? = nil) -> LocalSendDeviceInfo {
        snapshotDeviceInfo(announce: announce)
    }

    func scanNetwork() async {
        refreshLocalIP()
        sendMulticastAnnouncement(announce: true)
        guard let myIP = Self.detectPhysicalWiFiIPv4() else { return }
        let parts = myIP.split(separator: ".")
        guard parts.count == 4 else { return }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
        isScanning = true
        defer { isScanning = false }

        let infoPayload = deviceInfo(announce: nil)
        let infoData = (try? JSONEncoder().encode(infoPayload)) ?? Data()
        let myFP = fingerprint

        await withTaskGroup(of: LocalSendPeer?.self) { group in
            for host in 1...254 {
                let targetIP = "\(prefix).\(host)"
                if targetIP == myIP { continue }
                group.addTask { [lanURLSession] in
                    for port in [53417, 53418] {
                        for scheme in ["http", "https"] {
                            guard let url = URL(string: "\(scheme)://\(targetIP):\(port)/api/localsend/v2/register") else { continue }
                            var req = URLRequest(url: url, timeoutInterval: 0.45)
                            req.httpMethod = "POST"
                            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                            req.httpBody = infoData
                            if let (data, resp) = try? await lanURLSession.data(for: req),
                               let httpResp = resp as? HTTPURLResponse,
                               httpResp.statusCode == 200,
                               let peerInfo = try? JSONDecoder().decode(LocalSendDeviceInfo.self, from: data),
                               peerInfo.fingerprint != myFP,
                               peerInfo.isWallPullDevice {
                                return LocalSendPeer(
                                    fingerprint: peerInfo.fingerprint,
                                    alias: peerInfo.alias,
                                    deviceModel: peerInfo.deviceModel,
                                    deviceType: peerInfo.deviceType,
                                    ip: targetIP,
                                    port: port,
                                    scheme: scheme,
                                    supportsWallPullCatalog: peerInfo.download ?? false,
                                    lastSeen: Date()
                                )
                            }
                        }
                    }
                    return nil
                }
            }
            for await found in group {
                if let p = found {
                    upsertPeer(p)
                }
            }
        }
    }

    func connectManualIP(_ rawInput: String) async -> Bool {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let hostPort = trimmed.split(separator: ":")
        let ip = String(hostPort[0])
        let customPort = hostPort.count > 1 ? Int(hostPort[1]) : nil
        let ports = customPort.map { [$0] } ?? [53417, 53418]
        let infoData = (try? JSONEncoder().encode(deviceInfo(announce: nil))) ?? Data()

        for port in ports {
            for scheme in ["http", "https"] {
                guard let url = URL(string: "\(scheme)://\(ip):\(port)/api/localsend/v2/register") else { continue }
                var req = URLRequest(url: url, timeoutInterval: 2.0)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = infoData
                if let (data, resp) = try? await lanURLSession.data(for: req),
                   let http = resp as? HTTPURLResponse, http.statusCode == 200,
                   let info = try? JSONDecoder().decode(LocalSendDeviceInfo.self, from: data),
                   info.isWallPullDevice {
                    let peer = LocalSendPeer(
                        fingerprint: info.fingerprint,
                        alias: info.alias,
                        deviceModel: info.deviceModel,
                        deviceType: info.deviceType,
                        ip: ip,
                        port: port,
                        scheme: scheme,
                        supportsWallPullCatalog: info.download ?? false,
                        lastSeen: Date()
                    )
                    upsertPeer(peer)
                    selectPeer(peer)
                    vault?.showToast("已连接：\(peer.alias)")
                    return true
                }
            }
        }
        vault?.showToast("未能在 \(trimmed) 检测到 WallPull 服务（请确认端口为 53417）", isError: true)
        return false
    }

    func fetchPCCatalog(from peer: LocalSendPeer) async {
        guard let url = URL(string: "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/wallpull/catalog") else { return }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        var req = URLRequest(url: url, timeoutInterval: 8.0)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let (data, resp) = try? await lanURLSession.data(for: req),
           let http = resp as? HTTPURLResponse, http.statusCode == 200,
           let items = try? JSONDecoder().decode([PCCatalogItem].self, from: data) {
            touchPeerAlive(fingerprint: peer.fingerprint)
            pcCatalog = items
            await reconcileVaultWithCatalog(items, peer: peer)
        } else {
            pcCatalog = []
        }
    }

    func pcThumbURL(for item: PCCatalogItem, peer: LocalSendPeer) -> URL? {
        let encoded = item.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item.id
        return URL(string: "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/wallpull/thumb?id=\(encoded)")
    }

    func loadCachedPCThumb(for item: PCCatalogItem, peer: LocalSendPeer) async -> UIImage? {
        let key = "\(peer.ip):\(item.id)" as NSString
        if let cached = thumbMemCache.object(forKey: key) {
            return cached
        }
        guard let url = pcThumbURL(for: item, peer: peer) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.cachePolicy = .returnCacheDataElseLoad
        if let (data, resp) = try? await lanURLSession.data(for: req),
           let http = resp as? HTTPURLResponse, http.statusCode == 200,
           let ui = UIImage(data: data) {
            touchPeerAlive(fingerprint: peer.fingerprint)
            thumbMemCache.setObject(ui, forKey: key)
            return ui
        }
        return nil
    }

    private func reconcileVaultWithCatalog(_ catalog: [PCCatalogItem], peer: LocalSendPeer) async {
        guard let vault else { return }
        let byRemote = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        let byTitle = Dictionary(catalog.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        let session = lanURLSession

        for existing in vault.items {
            let matchedPC: PCCatalogItem?
            if let rid = existing.remoteID, !rid.isEmpty {
                matchedPC = byRemote[rid]
            } else {
                matchedPC = byTitle[existing.title].flatMap {
                    ($0.mediaType == existing.mediaType.rawValue && $0.fileSize == existing.fileSize) ? $0 : nil
                }
            }
            guard let pcItem = matchedPC else {
                continue
            }
            if existing.remoteID == nil {
                vault.updateItemMetadata(id: existing.id) { $0.remoteID = pcItem.id }
            }
            if existing.contentRating == nil, let cr = pcItem.contentRating, !cr.isEmpty {
                vault.updateItemMetadata(id: existing.id) { $0.contentRating = cr }
            }
            if pcItem.supportsStudio && existing.hasSceneLayers != true {
                vault.updateItemMetadata(id: existing.id) { $0.hasSceneLayers = true }
            }
            if pcItem.isVideo && existing.previewVideoFileName == nil {
                if let prevName = await Self.downloadPreviewVideo(for: pcItem, localItemID: existing.id, peer: peer, previewsDir: vault.previewsDir, session: session) {
                    vault.updateItemMetadata(id: existing.id) { $0.previewVideoFileName = prevName }
                }
            }
            if !pcItem.isVideo, (pcItem.assetCount ?? 1) > 1, (existing.additionalFiles ?? []).isEmpty {
                let extras = await Self.downloadAdditionalVariants(for: pcItem, localItemID: existing.id, peer: peer, mediaDir: vault.mediaDir, session: session)
                if !extras.isEmpty {
                    vault.updateItemMetadata(id: existing.id) { $0.additionalFiles = extras }
                }
            }
            if pcItem.hasMusic && (existing.audioTracks ?? []).isEmpty {
                let tracks = await downloadAudioTracks(for: pcItem, localItemID: existing.id, peer: peer, audioDir: vault.audioDir)
                if !tracks.isEmpty {
                    vault.updateItemMetadata(id: existing.id) { $0.audioTracks = tracks }
                }
            }
        }
        vault.flushCatalogSaveNow()
    }

    nonisolated private static func parseResolutionDimensions(_ raw: String?) -> (CGFloat, CGFloat)? {
        guard let raw else { return nil }
        let nums = raw.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }
            .compactMap { Double($0) }
        guard nums.count >= 2, nums[0] > 0, nums[1] > 0 else { return nil }
        return (CGFloat(nums[0]), CGFloat(nums[1]))
    }

    nonisolated private static func downloadPreviewVideo(
        for pcItem: PCCatalogItem,
        localItemID: String,
        peer: LocalSendPeer,
        previewsDir: URL,
        session: URLSession
    ) async -> String? {
        guard pcItem.isVideo else { return nil }
        let encodedId = pcItem.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? pcItem.id
        guard let url = URL(string: "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/wallpull/preview-video?id=\(encodedId)") else {
            return nil
        }
        var req = URLRequest(url: url, timeoutInterval: 45)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let (tmpURL, resp) = try? await session.download(for: req),
           let http = resp as? HTTPURLResponse,
           http.statusCode == 200 || http.statusCode == 206 {
            let localName = "\(localItemID)_prev_hd.mp4"
            let dst = previewsDir.appendingPathComponent(localName)
            try? FileManager.default.removeItem(at: dst)
            if (try? FileManager.default.moveItem(at: tmpURL, to: dst)) != nil {
                let asset = AVURLAsset(url: dst)
                if let track = asset.tracks(withMediaType: .video).first {
                    let transformed = track.naturalSize.applying(track.preferredTransform)
                    let pw = abs(transformed.width)
                    let ph = abs(transformed.height)
                    let minResOk = max(pw, ph) >= 900
                    var aspectOk = pw > 1 && ph > 1
                    if aspectOk, let (sw, sh) = parseResolutionDimensions(pcItem.resolution) {
                        let srcRatio = sw / max(1, sh)
                        let prevRatio = pw / max(1, ph)
                        aspectOk = abs(prevRatio - srcRatio) <= 0.16
                    }
                    if minResOk && aspectOk {
                        return localName
                    }
                }
                try? FileManager.default.removeItem(at: dst)
                return nil
            }
            try? FileManager.default.removeItem(at: tmpURL)
        }
        return nil
    }

    nonisolated private static func downloadAdditionalVariants(
        for pcItem: PCCatalogItem,
        localItemID: String,
        peer: LocalSendPeer,
        mediaDir: URL,
        session: URLSession
    ) async -> [String] {
        let count = pcItem.assetCount ?? 1
        guard count > 1 else { return [] }
        let encodedId = pcItem.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? pcItem.id
        let fallbackExt = URL(fileURLWithPath: pcItem.fileName).pathExtension.lowercased()
        let safeExt = fallbackExt.isEmpty ? "png" : fallbackExt
        var out: [String] = []
        for idx in 1..<count {
            guard let url = URL(string: "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/wallpull/asset?id=\(encodedId)&index=\(idx)") else {
                continue
            }
            var req = URLRequest(url: url, timeoutInterval: 90)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            if let (tmpURL, resp) = try? await session.download(for: req),
               let http = resp as? HTTPURLResponse,
               http.statusCode == 200 || http.statusCode == 206 {
                let suggestedExt = (resp.suggestedFilename.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }) ?? ""
                let ext = suggestedExt.isEmpty ? safeExt : suggestedExt
                let localName = "\(localItemID)_v\(idx).\(ext)"
                let dst = mediaDir.appendingPathComponent(localName)
                try? FileManager.default.removeItem(at: dst)
                if (try? FileManager.default.moveItem(at: tmpURL, to: dst)) != nil {
                    out.append(localName)
                } else {
                    try? FileManager.default.removeItem(at: tmpURL)
                }
            }
        }
        return out
    }

    private func downloadAudioTracks(
        for pcItem: PCCatalogItem,
        localItemID: String,
        peer: LocalSendPeer,
        audioDir: URL
    ) async -> [VaultAudioTrack] {
        guard let dtos = pcItem.audioTracks, !dtos.isEmpty else { return [] }
        var out: [VaultAudioTrack] = []
        let encodedId = pcItem.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? pcItem.id
        for dto in dtos {
            guard let url = URL(string: "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/wallpull/audio?id=\(encodedId)&track=\(dto.index)") else {
                continue
            }
            var req = URLRequest(url: url, timeoutInterval: 45)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            if let (tmpURL, resp) = try? await lanURLSession.download(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 {
                let ext = URL(fileURLWithPath: dto.fileName).pathExtension.lowercased()
                let safeExt = ext.isEmpty ? "mp3" : ext
                let localName = "\(localItemID)_\(dto.index).\(safeExt)"
                let dst = audioDir.appendingPathComponent(localName)
                try? FileManager.default.removeItem(at: dst)
                if (try? FileManager.default.moveItem(at: tmpURL, to: dst)) != nil {
                    out.append(VaultAudioTrack(
                        id: "\(localItemID)_\(dto.index)",
                        title: dto.name,
                        fileName: localName,
                        durationSeconds: nil
                    ))
                } else {
                    try? FileManager.default.removeItem(at: tmpURL)
                }
            }
        }
        return out
    }

    func fetchStudioManifest(remoteID: String, peer: LocalSendPeer) async -> StudioManifestDTO? {
        let enc = remoteID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? remoteID
        guard let url = URL(string: "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/wallpull/studio/manifest?id=\(enc)") else {
            return nil
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await lanURLSession.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        touchPeerAlive(fingerprint: peer.fingerprint)
        return try? JSONDecoder().decode(StudioManifestDTO.self, from: data)
    }

    func renderStudioFrame(
        remoteID: String,
        visibleLayers: [Int],
        maxDimension: Int = 2048,
        preserveTransparency: Bool = true,
        trimBounds: Bool = false,
        peer: LocalSendPeer
    ) async -> UIImage? {
        guard let url = URL(string: "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/wallpull/studio/render") else {
            return nil
        }
        let bodyObj: [String: Any] = [
            "id": remoteID,
            "visibleLayers": visibleLayers,
            "maxDimension": maxDimension,
            "preserveTransparency": preserveTransparency,
            "trimBounds": trimBounds,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: bodyObj) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (data, resp) = try? await lanURLSession.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        touchPeerAlive(fingerprint: peer.fingerprint)
        return UIImage(data: data)
    }

    func fetchAndCacheOfflineBundle(remoteID: String, localItemID: String, peer: LocalSendPeer) async -> OfflineStudioBundle? {
        guard let vault else { return nil }
        let enc = remoteID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? remoteID
        guard let url = URL(string: "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/wallpull/studio/offline-bundle?id=\(enc)") else {
            return nil
        }
        var req = URLRequest(url: url, timeoutInterval: 45)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await lanURLSession.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let dto = try? JSONDecoder().decode(OfflineBundleResponseDTO.self, from: data) else {
            return nil
        }
        touchPeerAlive(fingerprint: peer.fingerprint)
        var layers: [OfflineStudioGroupLayer] = []
        var pngMap: [String: Data] = [:]
        for (idx, g) in dto.groups.enumerated() {
            guard let png = Data(base64Encoded: g.pngBase64) else { continue }
            let fileName = "grp_\(idx).png"
            pngMap[fileName] = png
            layers.append(OfflineStudioGroupLayer(
                key: g.key,
                title: g.title,
                role: g.role,
                defaultVisible: g.defaultVisible,
                pngFileName: fileName
            ))
        }
        guard !layers.isEmpty else { return nil }
        let bundle = OfflineStudioBundle(
            canvasWidth: dto.manifest.canvasWidth,
            canvasHeight: dto.manifest.canvasHeight,
            groups: layers
        )
        vault.saveOfflineStudioBundle(bundle, groupImages: pngMap, for: localItemID)
        return bundle
    }

    nonisolated private static func downloadAndBuildVaultItem(
        item: PCCatalogItem,
        peer: LocalSendPeer,
        session: URLSession,
        mediaDir: URL,
        thumbsDir: URL,
        previewsDir: URL,
        audioDir: URL
    ) async -> VaultItem? {
        let encoded = item.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item.id
        guard let url = URL(string: "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/wallpull/asset?id=\(encoded)") else {
            return nil
        }
        var req = URLRequest(url: url, timeoutInterval: 180)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (localTempURL, resp) = try? await session.download(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 200 || http.statusCode == 206 else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: localTempURL) }

        let newID = UUID().uuidString
        let ext = URL(fileURLWithPath: item.fileName).pathExtension.lowercased()
        let safeExt = ext.isEmpty ? (item.isVideo ? "mp4" : "png") : ext
        let storedFileName = "\(newID).\(safeExt)"

        guard let analyzed = LocalVaultStore.analyzeAndWriteMedia(
            from: localTempURL,
            id: newID,
            storedFileName: storedFileName,
            safeExt: safeExt,
            mediaDir: mediaDir,
            thumbsDir: thumbsDir,
            isCutoutHint: false
        ) else {
            return nil
        }

        var previewVideoName: String? = nil
        if analyzed.mediaType == .video {
            previewVideoName = await downloadPreviewVideo(for: item, localItemID: newID, peer: peer, previewsDir: previewsDir, session: session)
            if previewVideoName == nil {
                let storedURL = mediaDir.appendingPathComponent(storedFileName)
                previewVideoName = await LocalVaultStore.generateLightweightVideoPreview(srcURL: storedURL, id: newID, previewsDir: previewsDir)
            }
        }

        var extraVariantFiles: [String] = []
        if !item.isVideo && (item.assetCount ?? 1) > 1 {
            extraVariantFiles = await downloadAdditionalVariants(for: item, localItemID: newID, peer: peer, mediaDir: mediaDir, session: session)
        }

        var localAudio: [VaultAudioTrack] = []
        if let audioDTOs = item.audioTracks, !audioDTOs.isEmpty {
            for dto in audioDTOs {
                guard let aURL = URL(string: "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/wallpull/audio?id=\(encoded)&track=\(dto.index)") else {
                    continue
                }
                var aReq = URLRequest(url: aURL, timeoutInterval: 45)
                aReq.cachePolicy = .reloadIgnoringLocalCacheData
                if let (aTmp, aResp) = try? await session.download(for: aReq),
                   let aHTTP = aResp as? HTTPURLResponse,
                   aHTTP.statusCode == 200 || aHTTP.statusCode == 206 {
                    let aExt = URL(fileURLWithPath: dto.fileName).pathExtension.lowercased()
                    let safeAExt = aExt.isEmpty ? "mp3" : aExt
                    let aLocalName = "\(newID)_\(dto.index).\(safeAExt)"
                    let aDst = audioDir.appendingPathComponent(aLocalName)
                    try? FileManager.default.removeItem(at: aDst)
                    if (try? FileManager.default.moveItem(at: aTmp, to: aDst)) != nil {
                        localAudio.append(VaultAudioTrack(
                            id: "\(newID)_\(dto.index)",
                            title: dto.name,
                            fileName: aLocalName,
                            durationSeconds: nil
                        ))
                    } else {
                        try? FileManager.default.removeItem(at: aTmp)
                    }
                }
            }
        }

        return VaultItem(
            id: newID,
            title: item.title,
            mediaType: analyzed.mediaType,
            fileName: storedFileName,
            thumbFileName: analyzed.thumbFileName,
            previewVideoFileName: previewVideoName,
            width: analyzed.width,
            height: analyzed.height,
            durationSeconds: analyzed.durationSeconds,
            fileSize: analyzed.fileSize,
            isTransparentCutout: analyzed.isTransparentCutout,
            colorBucket: analyzed.colorBucket,
            contentRating: item.contentRating,
            isFavorite: false,
            addedAt: Date(),
            sourceDevice: peer.alias,
            sha256: nil,
            remoteID: item.id,
            audioTracks: localAudio.isEmpty ? nil : localAudio,
            additionalFiles: extraVariantFiles.isEmpty ? nil : extraVariantFiles,
            hasSceneLayers: item.supportsStudio,
            hasOfflineStudioBundle: false,
            visualFingerprint: nil
        )
    }

    func pullCatalogItemsToVault(_ selected: [PCCatalogItem], from peer: LocalSendPeer) async {
        guard !selected.isEmpty, let vault else { return }
        let pending = selected.filter { !vault.hasImportedCatalogItem($0) }
        if pending.isEmpty {
            vault.showToast("所选壁纸已全部在离线库中，无需重复下载")
            return
        }

        transferCancelled = false
        canCancelTransfer = true
        transferProgress = TransferProgressState(
            title: "正在准备接收 \(pending.count) 项壁纸…",
            currentFileIndex: 0,
            totalFiles: pending.count,
            fraction: 0.02
        )
        defer {
            canCancelTransfer = false
            transferProgress = nil
            vault.flushCatalogSaveNow()
        }

        let total = pending.count
        let session = lanURLSession
        let mDir = vault.mediaDir
        let tDir = vault.thumbsDir
        let pDir = vault.previewsDir
        let aDir = vault.audioDir
        let shouldPrefetchStudio = total <= 12
        var importedCount = 0
        var processedCount = 0
        var nextIndex = 0
        let maxConcurrent = 3

        await withTaskGroup(of: (PCCatalogItem, VaultItem?).self) { group in
            while nextIndex < pending.count && nextIndex < maxConcurrent {
                let target = pending[nextIndex]
                nextIndex += 1
                group.addTask {
                    let built = await Self.downloadAndBuildVaultItem(
                        item: target,
                        peer: peer,
                        session: session,
                        mediaDir: mDir,
                        thumbsDir: tDir,
                        previewsDir: pDir,
                        audioDir: aDir
                    )
                    return (target, built)
                }
            }

            while let (finishedSource, created) = await group.next() {
                processedCount += 1
                transferProgress = TransferProgressState(
                    title: "正在收入 \(finishedSource.title)",
                    currentFileIndex: min(processedCount, total),
                    totalFiles: total,
                    fraction: Double(processedCount) / Double(total)
                )

                if let created {
                    importedCount += 1
                    touchPeerAlive(fingerprint: peer.fingerprint)
                    vault.insertStreamedItem(created)
                    if shouldPrefetchStudio && created.hasSceneLayers == true, let rid = created.remoteID {
                        Task { [weak self] in
                            _ = await self?.fetchAndCacheOfflineBundle(remoteID: rid, localItemID: created.id, peer: peer)
                        }
                    }
                    try? await Task.sleep(nanoseconds: 90_000_000)
                }

                if !transferCancelled && nextIndex < pending.count {
                    let target = pending[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        let built = await Self.downloadAndBuildVaultItem(
                            item: target,
                            peer: peer,
                            session: session,
                            mediaDir: mDir,
                            thumbsDir: tDir,
                            previewsDir: pDir,
                            audioDir: aDir
                        )
                        return (target, built)
                    }
                } else if transferCancelled {
                    group.cancelAll()
                }
            }
        }

        if transferCancelled {
            vault.showToast("已停止批量收入（已完成 \(importedCount) 项并保存）")
        } else if importedCount > 0 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            vault.showToast("已无损收入 \(importedCount) 项到 iPad 离线壁纸库")
        } else {
            vault.showToast("从电脑拉取壁纸失败，请检查网络连接", isError: true)
        }
    }

    func sendVaultItems(_ items: [VaultItem], to peer: LocalSendPeer, targetMode: String = "vault") async {
        guard !items.isEmpty, let vault else { return }
        transferCancelled = false
        canCancelTransfer = false
        transferProgress = TransferProgressState(
            title: "正在准备发送到「\(peer.alias)」…",
            currentFileIndex: 0,
            totalFiles: items.count,
            fraction: 0.05
        )
        defer {
            transferProgress = nil
        }

        let itemURLs: [(VaultItem, URL)] = items.compactMap { item in
            let fileURL = vault.mediaURL(for: item)
            return FileManager.default.fileExists(atPath: fileURL.path) ? (item, fileURL) : nil
        }
        guard !itemURLs.isEmpty else {
            vault.showToast("没有找到可发送的本地文件", isError: true)
            return
        }

        let preparedData = await Task.detached(priority: .userInitiated) { () -> ([String: [String: Any]], [(id: String, url: URL, size: Int64)]) in
            var fileDTOs: [String: [String: Any]] = [:]
            var prepared: [(id: String, url: URL, size: Int64)] = []
            for (item, fileURL) in itemURLs {
                guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else { continue }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let ext = fileURL.pathExtension.lowercased()
                let mime = item.mediaType == .video ? "video/\(ext == "mov" ? "quicktime" : "mp4")" : "image/\(ext == "jpg" ? "jpeg" : ext)"
                let fid = item.id
                var meta: [String: Any] = [
                    "wallpullTarget": targetMode,
                    "wallpullTitle": item.title,
                ]
                if let rid = item.remoteID { meta["wallpullItemId"] = rid }
                if item.supportsLayerStudio { meta["wallpullHasSceneLayers"] = true }
                if let cr = item.contentRating { meta["wallpullContentRating"] = cr }
                fileDTOs[fid] = [
                    "id": fid,
                    "fileName": "\(item.title).\(ext.isEmpty ? "png" : ext)",
                    "size": item.fileSize,
                    "fileType": mime,
                    "sha256": digest,
                    "metadata": meta,
                ]
                prepared.append((fid, fileURL, item.fileSize))
            }
            return (fileDTOs, prepared)
        }.value

        let fileDTOs = preparedData.0
        let prepared = preparedData.1
        guard !prepared.isEmpty else {
            vault.showToast("无法读取本地壁纸文件", isError: true)
            return
        }

        let info = deviceInfo(announce: nil)
        guard let infoData = try? JSONEncoder().encode(info),
              let infoObj = try? JSONSerialization.jsonObject(with: infoData) else { return }
        let preparePayload: [String: Any] = ["info": infoObj, "files": fileDTOs]
        guard let prepURL = URL(string: "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/prepare-upload"),
              let prepBody = try? JSONSerialization.data(withJSONObject: preparePayload) else { return }

        var prepReq = URLRequest(url: prepURL, timeoutInterval: 10)
        prepReq.httpMethod = "POST"
        prepReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        prepReq.httpBody = prepBody

        do {
            let (respData, resp) = try await lanURLSession.data(for: prepReq)
            guard let http = resp as? HTTPURLResponse else { return }
            if http.statusCode == 204 {
                vault.showToast("「\(peer.alias)」已确认无需重复发送")
                return
            }
            guard http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
                  let sessionId = json["sessionId"] as? String,
                  let tokenMap = json["files"] as? [String: String] else {
                vault.showToast("发送被「\(peer.alias)」拒绝", isError: true)
                return
            }

            for (idx, entry) in prepared.enumerated() {
                guard let token = tokenMap[entry.id] else { continue }
                transferProgress = TransferProgressState(
                    title: "正在发送到「\(peer.alias)」",
                    currentFileIndex: idx + 1,
                    totalFiles: prepared.count,
                    fraction: Double(idx + 1) / Double(prepared.count)
                )
                let encSid = sessionId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sessionId
                let encFid = entry.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? entry.id
                let encTok = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
                guard let upURL = URL(string: "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/upload?sessionId=\(encSid)&fileId=\(encFid)&token=\(encTok)") else { continue }
                var upReq = URLRequest(url: upURL, timeoutInterval: 180)
                upReq.httpMethod = "POST"
                upReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let (_, upResp) = try await lanURLSession.upload(for: upReq, fromFile: entry.url)
                if let h = upResp as? HTTPURLResponse, h.statusCode != 200 {
                    throw URLError(.cannotWriteToFile)
                }
            }
            touchPeerAlive(fingerprint: peer.fingerprint)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            vault.showToast(targetMode == "clipboard" ? "已隔空推送到「\(peer.alias)」剪贴板" : "已无损发送 \(prepared.count) 项给「\(peer.alias)」")
        } catch {
            vault.showToast("发送失败：\(error.localizedDescription)", isError: true)
        }
    }

    private func rememberEndpoint(scheme: String, ip: String, port: Int) {
        let ep = "\(scheme)://\(ip):\(port)"
        lastKnownEndpoints.removeAll { $0 == ep }
        lastKnownEndpoints.insert(ep, at: 0)
        if lastKnownEndpoints.count > 6 {
            lastKnownEndpoints = Array(lastKnownEndpoints.prefix(6))
        }
        UserDefaults.standard.set(lastKnownEndpoints, forKey: lastEndpointsKey)
    }

    private func touchPeerAlive(fingerprint: String) {
        if let idx = peers.firstIndex(where: { $0.fingerprint == fingerprint }) {
            peers[idx].lastSeen = Date()
            peers[idx].missedHeartbeats = 0
        }
    }

    private func touchPeerAliveByIP(_ ip: String) {
        let now = Date()
        for idx in peers.indices where peers[idx].ip == ip {
            peers[idx].lastSeen = now
            peers[idx].missedHeartbeats = 0
        }
    }

    private func upsertPeer(_ peer: LocalSendPeer) {
        var normalized = peer
        normalized.lastSeen = Date()
        normalized.missedHeartbeats = 0
        rememberEndpoint(scheme: normalized.scheme, ip: normalized.ip, port: normalized.port)
        if let idx = peers.firstIndex(where: { $0.fingerprint == normalized.fingerprint }) {
            peers[idx] = normalized
        } else {
            peers.append(normalized)
        }
        peers.sort {
            if $0.isWallPullPC != $1.isWallPullPC { return $0.isWallPullPC }
            return $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending
        }
    }

    private func heartbeatPeersAndEndpoints() async {
        runtime.pruneExpiredSessions()
        var targets: [(scheme: String, ip: String, port: Int)] = []
        var seenKeys: Set<String> = []
        for peer in peers {
            let key = "\(peer.scheme)://\(peer.ip):\(peer.port)"
            if seenKeys.insert(key).inserted {
                targets.append((peer.scheme, peer.ip, peer.port))
            }
        }
        for ep in lastKnownEndpoints where seenKeys.insert(ep).inserted {
            if let u = URL(string: ep), let host = u.host {
                let sch = u.scheme ?? "http"
                let port = u.port ?? Self.wallpullDefaultPort
                targets.append((sch, host, port))
            }
        }

        if targets.isEmpty {
            pruneStalePeers()
            return
        }

        let infoData = (try? JSONEncoder().encode(deviceInfo(announce: nil))) ?? Data()
        let myFP = fingerprint
        var succeededKeys: Set<String> = []
        var failedKeys: Set<String> = []

        await withTaskGroup(of: (String, LocalSendPeer?).self) { group in
            for t in targets {
                let epKey = "\(t.scheme)://\(t.ip):\(t.port)"
                group.addTask { [lanURLSession] in
                    guard let url = URL(string: "\(epKey)/api/localsend/v2/register") else {
                        return (epKey, nil)
                    }
                    var req = URLRequest(url: url, timeoutInterval: 2.2)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = infoData
                    if let (data, resp) = try? await lanURLSession.data(for: req),
                       let http = resp as? HTTPURLResponse,
                       http.statusCode == 200,
                       let peerInfo = try? JSONDecoder().decode(LocalSendDeviceInfo.self, from: data),
                       peerInfo.fingerprint != myFP,
                       peerInfo.isWallPullDevice {
                        let p = LocalSendPeer(
                            fingerprint: peerInfo.fingerprint,
                            alias: peerInfo.alias,
                            deviceModel: peerInfo.deviceModel,
                            deviceType: peerInfo.deviceType,
                            ip: t.ip,
                            port: peerInfo.port ?? t.port,
                            scheme: t.scheme,
                            supportsWallPullCatalog: peerInfo.download ?? false,
                            lastSeen: Date(),
                            missedHeartbeats: 0
                        )
                        return (epKey, p)
                    }
                    return (epKey, nil)
                }
            }
            for await (epKey, foundPeer) in group {
                if let p = foundPeer {
                    succeededKeys.insert(epKey)
                    upsertPeer(p)
                } else {
                    failedKeys.insert(epKey)
                }
            }
        }

        for idx in peers.indices {
            let epKey = "\(peers[idx].scheme)://\(peers[idx].ip):\(peers[idx].port)"
            if !succeededKeys.contains(epKey) && failedKeys.contains(epKey) {
                peers[idx].missedHeartbeats += 1
            }
        }
        pruneStalePeers()
    }

    private func pruneStalePeers() {
        let now = Date()
        peers.removeAll { peer in
            let age = now.timeIntervalSince(peer.lastSeen)
            if age > 120 { return true }
            return peer.missedHeartbeats >= 3 && age > 25
        }
    }

    // MARK: - POSIX UDP Multicast (239.255.77.88:53417 dedicated WallPull channel)
    private func startUDPMulticast() {
        isStartingUDP = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in self?.isStartingUDP = false }
            }
            let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            self.runtime.setUDPFD(fd)
            defer {
                self.runtime.clearUDPFDIfMatches(fd)
                Darwin.close(fd)
            }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(Self.wallpullDefaultPort).bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindRes == 0 else {
                Darwin.close(fd)
                return
            }

            var mreq = ip_mreq()
            inet_pton(AF_INET, Self.wallpullMulticastIP, &mreq.imr_multiaddr)
            if let wifiIP = Self.detectPhysicalWiFiIPv4() {
                inet_pton(AF_INET, wifiIP, &mreq.imr_interface)
            } else {
                mreq.imr_interface = in_addr(s_addr: INADDR_ANY.bigEndian)
            }
            setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))

            var buf = [UInt8](repeating: 0, count: 8192)
            while !self.runtime.isStopped {
                var srcAddr = sockaddr_in()
                var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &srcAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(fd, &buf, buf.count, 0, $0, &srcLen)
                    }
                }
                if n <= 0 { continue }
                let data = Data(buf[0..<n])
                guard let info = try? JSONDecoder().decode(LocalSendDeviceInfo.self, from: data),
                      info.fingerprint != self.runtime.fingerprint,
                      info.isWallPullDevice else { continue }
                var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var addrCopy = srcAddr.sin_addr
                inet_ntop(AF_INET, &addrCopy, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                let peerIP = String(cString: ipBuf)
                let peer = LocalSendPeer(
                    fingerprint: info.fingerprint,
                    alias: info.alias,
                    deviceModel: info.deviceModel,
                    deviceType: info.deviceType,
                    ip: peerIP,
                    port: info.port ?? Self.wallpullDefaultPort,
                    scheme: (info.protocolName ?? "https").lowercased() == "http" ? "http" : "https",
                    supportsWallPullCatalog: info.download ?? false,
                    lastSeen: Date()
                )
                Task { @MainActor [weak self] in
                    self?.upsertPeer(peer)
                }
                if info.announce == true {
                    Self.dispatchMulticastPacket(info: self.runtime.deviceInfo(announce: false))
                    let replyInfo = self.runtime.deviceInfo(announce: nil)
                    if let url = URL(string: "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/register"),
                       let body = try? JSONEncoder().encode(replyInfo) {
                        Task.detached {
                            let cfg = URLSessionConfiguration.ephemeral
                            cfg.connectionProxyDictionary = [:]
                            cfg.timeoutIntervalForRequest = 4
                            cfg.timeoutIntervalForResource = 6
                            let session = URLSession(configuration: cfg, delegate: LocalSendInsecureLanDelegate(), delegateQueue: nil)
                            defer { session.finishTasksAndInvalidate() }
                            var req = URLRequest(url: url)
                            req.httpMethod = "POST"
                            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                            req.httpBody = body
                            _ = try? await session.data(for: req)
                        }
                    }
                }
            }
        }
    }

    private func sendMulticastAnnouncement(announce: Bool) {
        Self.dispatchMulticastPacket(info: runtime.deviceInfo(announce: announce))
    }

    nonisolated private static func dispatchMulticastPacket(info: LocalSendDeviceInfo) {
        guard let payload = try? JSONEncoder().encode(info) else { return }
        DispatchQueue.global(qos: .utility).async {
            let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            defer { Darwin.close(fd) }
            var ttl: Int32 = 2
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<Int32>.size))
            var dst = sockaddr_in()
            dst.sin_family = sa_family_t(AF_INET)
            dst.sin_port = UInt16(wallpullDefaultPort).bigEndian
            inet_pton(AF_INET, wallpullMulticastIP, &dst.sin_addr)
            payload.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                withUnsafePointer(to: &dst) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = Darwin.sendto(fd, base, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    // MARK: - POSIX TCP HTTP Server (WallPull LAN Receiver on 53417/53418)
    private func startHTTPServer() {
        isStartingHTTP = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for port in [53417, 53418, 53419] {
                let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { continue }
                var yes: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(port).bigEndian
                addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
                let ok = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                    }
                }
                if ok && Darwin.listen(fd, 32) == 0 {
                    self.runtime.setHTTP(fd, port: port)
                    Task { @MainActor [weak self] in
                        self?.listeningPort = port
                        self?.isStartingHTTP = false
                    }
                    self.acceptLoop(serverFD: fd)
                    self.runtime.clearHTTPFDIfMatches(fd)
                    Darwin.close(fd)
                    return
                }
                Darwin.close(fd)
            }
            Task { @MainActor [weak self] in
                self?.isStartingHTTP = false
            }
        }
    }

    nonisolated private func acceptLoop(serverFD: Int32) {
        while !runtime.isStopped {
            var clientAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(serverFD, $0, &len)
                }
            }
            if clientFD < 0 {
                let err = Darwin.errno
                if err == EINTR { continue }
                if err == EBADF || err == EINVAL { break }
                continue
            }
            var noSigPipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var ioTimeout = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &ioTimeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &ioTimeout, socklen_t(MemoryLayout<timeval>.size))
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addrCopy = clientAddr.sin_addr
            inet_ntop(AF_INET, &addrCopy, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let remoteIP = String(cString: ipBuf)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(fd: clientFD, remoteIP: remoteIP)
            }
        }
    }

    nonisolated private func handleClient(fd: Int32, remoteIP: String) {
        defer { Darwin.close(fd) }
        var headerData = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let separator = Data([13, 10, 13, 10])
        var sepRange: Range<Data.Index>? = nil
        while headerData.count < 65536 {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return }
            headerData.append(contentsOf: chunk[0..<n])
            if let r = headerData.range(of: separator) {
                sepRange = r
                break
            }
        }
        guard let sep = sepRange,
              let headerText = String(data: headerData[..<sep.lowerBound], encoding: .utf8) else { return }
        let leftover = Data(headerData[sep.upperBound...])
        let lines = headerText.components(separatedBy: "\r\n")
        let reqParts = (lines.first ?? "").split(separator: " ")
        guard reqParts.count >= 2 else { return }
        let method = String(reqParts[0]).uppercased()
        let rawTarget = String(reqParts[1])
        let splitTarget = rawTarget.split(separator: "?", maxSplits: 1)
        let path = String(splitTarget[0])
        let queryStr = splitTarget.count > 1 ? String(splitTarget[1]) : ""
        let query = Self.parseQuery(queryStr)

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                let k = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        let contentLen = headers["content-length"].flatMap { Int64($0) }
        let isChunked = (headers["transfer-encoding"] ?? "").lowercased().contains("chunked")

        switch (method, path) {
        case ("GET", "/api/localsend/v2/info"):
            let info = snapshotDeviceInfo(announce: nil)
            if let data = try? JSONEncoder().encode(info) {
                Self.sendHTTP(fd: fd, status: 200, reason: "OK", contentType: "application/json", body: data)
            }

        case ("POST", "/api/localsend/v2/register"):
            guard let body = Self.readRequestBody(fd: fd, leftover: leftover, contentLength: Int(contentLen ?? 0), isChunked: isChunked, maxBytes: 512 * 1024),
                  let peerInfo = try? JSONDecoder().decode(LocalSendDeviceInfo.self, from: body) else {
                Self.sendHTTP(fd: fd, status: 400, reason: "Bad Request", contentType: "application/json", body: Data("{\"message\":\"Invalid body\"}".utf8))
                return
            }
            if peerInfo.fingerprint != runtime.fingerprint && peerInfo.isWallPullDevice {
                let peer = LocalSendPeer(
                    fingerprint: peerInfo.fingerprint,
                    alias: peerInfo.alias,
                    deviceModel: peerInfo.deviceModel,
                    deviceType: peerInfo.deviceType,
                    ip: remoteIP,
                    port: peerInfo.port ?? Self.wallpullDefaultPort,
                    scheme: (peerInfo.protocolName ?? "https").lowercased() == "http" ? "http" : "https",
                    supportsWallPullCatalog: peerInfo.download ?? false,
                    lastSeen: Date()
                )
                Task { @MainActor [weak self] in
                    self?.upsertPeer(peer)
                }
            }
            let reply = snapshotDeviceInfo(announce: nil)
            if let data = try? JSONEncoder().encode(reply) {
                Self.sendHTTP(fd: fd, status: 200, reason: "OK", contentType: "application/json", body: data)
            }

        case ("POST", "/api/localsend/v2/prepare-upload"):
            guard let body = Self.readRequestBody(fd: fd, leftover: leftover, contentLength: Int(contentLen ?? 0), isChunked: isChunked, maxBytes: 4 * 1024 * 1024),
                  let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let infoDict = root["info"] as? [String: Any],
                  let filesDict = root["files"] as? [String: [String: Any]] else {
                Self.sendHTTP(fd: fd, status: 400, reason: "Bad Request", contentType: "application/json", body: Data("{\"message\":\"Invalid body\"}".utf8))
                return
            }
            if filesDict.isEmpty {
                Self.sendHTTP(fd: fd, status: 204, reason: "No Content", contentType: "text/plain", body: Data())
                return
            }
            let senderAlias = (infoDict["alias"] as? String) ?? remoteIP
            let sessionId = UUID().uuidString
            var sessionFiles: [String: LocalSendRuntimeState.SessionItem] = [:]
            var responseTokens: [String: String] = [:]
            for (fid, fobj) in filesDict {
                let tok = UUID().uuidString
                let fname = (fobj["fileName"] as? String) ?? "wallpaper.png"
                let ftype = (fobj["fileType"] as? String) ?? "application/octet-stream"
                let sha = fobj["sha256"] as? String
                let meta = fobj["metadata"] as? [String: Any]
                let target = (meta?["wallpullTarget"] as? String) ?? "vault"
                let kind = (meta?["wallpullKind"] as? String) ?? "wallpaper"
                let title = meta?["wallpullTitle"] as? String
                let rid = meta?["wallpullItemId"] as? String
                let hasLayers = (meta?["wallpullHasSceneLayers"] as? Bool) ?? false
                let contentRating = meta?["wallpullContentRating"] as? String
                sessionFiles[fid] = LocalSendRuntimeState.SessionItem(
                    fileName: fname,
                    fileType: ftype,
                    expectedSha256: sha,
                    token: tok,
                    target: target,
                    kind: kind,
                    title: title,
                    remoteID: rid,
                    hasSceneLayers: hasLayers,
                    contentRating: contentRating
                )
                responseTokens[fid] = tok
            }
            runtime.createSession(
                id: sessionId,
                session: LocalSendRuntimeState.UploadSession(senderAlias: senderAlias, files: sessionFiles, createdAt: Date())
            )
            Task { @MainActor [weak self] in
                self?.touchPeerAliveByIP(remoteIP)
            }

            let respObj: [String: Any] = ["sessionId": sessionId, "files": responseTokens]
            if let respData = try? JSONSerialization.data(withJSONObject: respObj) {
                Self.sendHTTP(fd: fd, status: 200, reason: "OK", contentType: "application/json", body: respData)
            }

        case ("POST", "/api/localsend/v2/upload"):
            guard let sid = query["sessionId"], let fid = query["fileId"], let tok = query["token"] else {
                Self.sendHTTP(fd: fd, status: 400, reason: "Bad Request", contentType: "application/json", body: Data("{\"message\":\"Missing parameters\"}".utf8))
                return
            }
            guard let sess = runtime.session(for: sid), let item = sess.files[fid], item.token == tok else {
                Self.sendHTTP(fd: fd, status: 403, reason: "Forbidden", contentType: "application/json", body: Data("{\"message\":\"Invalid token\"}".utf8))
                return
            }

            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("ls_rx_\(UUID().uuidString).part")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            guard let actualSha = Self.streamSocketToFile(fd: fd, leftover: leftover, contentLength: contentLen, isChunked: isChunked, destURL: tempURL) else {
                Self.sendHTTP(fd: fd, status: 500, reason: "Internal Error", contentType: "application/json", body: Data("{\"message\":\"Stream failed\"}".utf8))
                return
            }
            if let expected = item.expectedSha256?.trimmingCharacters(in: .whitespacesAndNewlines), !expected.isEmpty,
               expected.lowercased() != actualSha.lowercased() {
                Self.sendHTTP(fd: fd, status: 422, reason: "Unprocessable Entity", contentType: "application/json", body: Data("{\"message\":\"Checksum mismatch\"}".utf8))
                return
            }

            if item.target == "clipboard", item.fileType.hasPrefix("image/") || Self.looksLikeImage(item.fileName) {
                if let imgData = try? Data(contentsOf: tempURL) {
                    runtime.completeSessionFile(id: sid, fileId: fid)
                    Task { @MainActor [weak self] in
                        self?.touchPeerAliveByIP(remoteIP)
                        self?.vault?.copyIncomingBytesToClipboard(imgData, fileName: item.fileName, senderAlias: sess.senderAlias)
                    }
                    Self.sendHTTP(fd: fd, status: 200, reason: "OK", contentType: "text/plain", body: Data())
                    return
                }
            }

            let cleanItemName = URL(fileURLWithPath: item.fileName).lastPathComponent
            let copyForImport = FileManager.default.temporaryDirectory.appendingPathComponent("ls_imp_\(UUID().uuidString)_\(cleanItemName)")
            try? FileManager.default.copyItem(at: tempURL, to: copyForImport)
            runtime.completeSessionFile(id: sid, fileId: fid)
            Task { @MainActor [weak self] in
                self?.touchPeerAliveByIP(remoteIP)
                guard let self, let vault = self.vault else {
                    try? FileManager.default.removeItem(at: copyForImport)
                    return
                }
                let imported = await vault.importFile(
                    from: copyForImport,
                    suggestedFileName: item.fileName,
                    titleOverride: item.title,
                    sourceDevice: sess.senderAlias,
                    isCutoutHint: item.kind == "cutout",
                    sha256: actualSha,
                    remoteID: item.remoteID,
                    hasSceneLayers: item.hasSceneLayers,
                    contentRating: item.contentRating
                )
                try? FileManager.default.removeItem(at: copyForImport)
                if let imported {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    vault.showToast("已无损接收来自「\(sess.senderAlias)」：\(imported.title)")
                }
            }
            Self.sendHTTP(fd: fd, status: 200, reason: "OK", contentType: "text/plain", body: Data())

        case ("POST", "/api/localsend/v2/cancel"):
            if let sid = query["sessionId"] {
                runtime.removeSession(id: sid)
            }
            Self.sendHTTP(fd: fd, status: 200, reason: "OK", contentType: "text/plain", body: Data())

        default:
            Self.sendHTTP(fd: fd, status: 404, reason: "Not Found", contentType: "application/json", body: Data("{\"message\":\"Not Found\"}".utf8))
        }
    }

    nonisolated private static func consumeChunkedStream(
        fd: Int32,
        leftover: Data,
        maxBytes: Int?,
        onChunk: (Data) -> Bool
    ) -> Bool {
        var buffer = leftover
        var total = 0
        let crlf = Data([0x0D, 0x0A])
        var recvBuf = [UInt8](repeating: 0, count: 65536)

        func readMore() -> Bool {
            let n = Darwin.recv(fd, &recvBuf, recvBuf.count, 0)
            if n <= 0 { return false }
            buffer.append(contentsOf: recvBuf[0..<n])
            return true
        }

        while true {
            var crlfRange: Range<Data.Index>?
            while true {
                if let found = buffer.range(of: crlf) {
                    crlfRange = found
                    break
                }
                if buffer.count > 1024 || !readMore() {
                    return false
                }
            }
            guard let foundRange = crlfRange else { return false }
            let lineData = buffer[buffer.startIndex..<foundRange.lowerBound]
            buffer.removeSubrange(buffer.startIndex..<foundRange.upperBound)
            guard let lineStr = String(data: lineData, encoding: .utf8) else { return false }
            let sizeToken = (lineStr.split(separator: ";", maxSplits: 1).first.map(String.init) ?? lineStr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let chunkSize = Int(sizeToken, radix: 16), chunkSize >= 0 else { return false }
            if chunkSize == 0 {
                return true
            }
            if let maxBytes, total + chunkSize > maxBytes {
                return false
            }

            var remaining = chunkSize
            while remaining > 0 {
                if buffer.isEmpty && !readMore() { return false }
                let take = min(remaining, buffer.count)
                let endIdx = buffer.index(buffer.startIndex, offsetBy: take)
                let slice = Data(buffer[buffer.startIndex..<endIdx])
                buffer.removeSubrange(buffer.startIndex..<endIdx)
                remaining -= take
                total += take
                if !onChunk(slice) { return false }
            }

            while buffer.count < 2 {
                if !readMore() { return false }
            }
            let b0 = buffer[buffer.startIndex]
            let b1 = buffer[buffer.index(after: buffer.startIndex)]
            guard b0 == 0x0D && b1 == 0x0A else { return false }
            buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: 2))
        }
    }

    nonisolated private static func readRequestBody(fd: Int32, leftover: Data, contentLength: Int, isChunked: Bool, maxBytes: Int) -> Data? {
        if isChunked {
            var out = Data()
            let ok = consumeChunkedStream(fd: fd, leftover: leftover, maxBytes: maxBytes) { chunk in
                out.append(chunk)
                return true
            }
            return ok ? out : nil
        }
        if contentLength <= 0 { return leftover }
        guard contentLength <= maxBytes else { return nil }
        var out = Data()
        out.reserveCapacity(contentLength)
        let take = min(leftover.count, contentLength)
        out.append(leftover.prefix(take))
        var buf = [UInt8](repeating: 0, count: 16384)
        while out.count < contentLength {
            let need = min(buf.count, contentLength - out.count)
            let n = Darwin.recv(fd, &buf, need, 0)
            if n <= 0 { return nil }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    nonisolated private static func streamSocketToFile(fd: Int32, leftover: Data, contentLength: Int64?, isChunked: Bool, destURL: URL) -> String? {
        FileManager.default.createFile(atPath: destURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destURL) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()

        if isChunked {
            let ok = consumeChunkedStream(fd: fd, leftover: leftover, maxBytes: nil) { slice in
                handle.write(slice)
                hasher.update(data: slice)
                return true
            }
            guard ok else { return nil }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        var written: Int64 = 0
        if !leftover.isEmpty {
            let toWrite = contentLength.map { min(Int64(leftover.count), $0) } ?? Int64(leftover.count)
            let slice = leftover.prefix(Int(toWrite))
            handle.write(slice)
            hasher.update(data: slice)
            written += toWrite
        }

        var buf = [UInt8](repeating: 0, count: 65536)
        if let expectedLen = contentLength {
            while written < expectedLen {
                let need = min(buf.count, Int(expectedLen - written))
                let n = Darwin.recv(fd, &buf, need, 0)
                if n <= 0 { return nil }
                let d = Data(bytes: buf, count: n)
                handle.write(d)
                hasher.update(data: d)
                written += Int64(n)
            }
        } else {
            while true {
                let n = Darwin.recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                let d = Data(bytes: buf, count: n)
                handle.write(d)
                hasher.update(data: d)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func sendHTTP(fd: Int32, status: Int, reason: String, contentType: String, body: Data) {
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        payload.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var sent = 0
            while sent < payload.count {
                let n = Darwin.send(fd, base.advanced(by: sent), payload.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    nonisolated private static func parseQuery(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            out[k] = v
        }
        return out
    }

    nonisolated private static func looksLikeImage(_ fileName: String) -> Bool {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "gif", "bmp"].contains(ext)
    }

    nonisolated static func detectPhysicalWiFiIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var fallback: String? = nil
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let name = String(cString: cur.pointee.ifa_name)
            let flags = Int32(cur.pointee.ifa_flags)
            if (flags & IFF_UP) != 0,
               (flags & IFF_LOOPBACK) == 0,
               let addr = cur.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                // Skip Fake-IP 198.18.0.0/15, link-local 169.254.*, and VPN utun*
                if !name.hasPrefix("utun"),
                   !ip.hasPrefix("198.18."),
                   !ip.hasPrefix("198.19."),
                   !ip.hasPrefix("169.254."),
                   !ip.hasPrefix("127.") {
                    if name == "en0" { return ip }
                    if fallback == nil { fallback = ip }
                }
            }
            ptr = cur.pointee.ifa_next
        }
        return fallback
    }
}
