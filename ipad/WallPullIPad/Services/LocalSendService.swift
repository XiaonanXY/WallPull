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

final class StreamingDownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private final class CancelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var cancelled = false
        private var finished = false

        func markStarted() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { return false }
            started = true
            return true
        }

        func cancelAndShouldCancelTask() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finished || cancelled { return false }
            cancelled = true
            return started
        }

        func markFinished() {
            lock.lock()
            finished = true
            lock.unlock()
        }
    }

    private struct TaskRecord {
        var onBytes: (Int64, Int64) -> Void
        var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>
        var cancelBox: CancelBox
        var movedTempURL: URL? = nil
        var moveError: Error? = nil
        var lastProgressUptime: TimeInterval = 0
    }

    private let lock = NSLock()
    private var records: [ObjectIdentifier: TaskRecord] = [:]
    private var tasksByID: [ObjectIdentifier: URLSessionDownloadTask] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 210
        cfg.timeoutIntervalForResource = 0
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

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

    func download(
        request: URLRequest,
        onBytes: @escaping (Int64, Int64) -> Void
    ) async throws -> (URL, HTTPURLResponse) {
        try Task.checkCancellation()
        let task = session.downloadTask(with: request)
        let key = ObjectIdentifier(task)
        let box = CancelBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                if !box.markStarted() {
                    lock.unlock()
                    task.cancel()
                    cont.resume(throwing: CancellationError())
                    return
                }
                records[key] = TaskRecord(onBytes: onBytes, continuation: cont, cancelBox: box)
                tasksByID[key] = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            if box.cancelAndShouldCancelTask() {
                lock.lock()
                let existing = tasksByID[key]
                lock.unlock()
                existing?.cancel()
            } else {
                task.cancel()
            }
        }
    }

    func cancelAll() {
        lock.lock()
        let active = Array(tasksByID.values)
        lock.unlock()
        for t in active {
            t.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let key = ObjectIdentifier(downloadTask)
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        var cb: ((Int64, Int64) -> Void)? = nil
        if var rec = records[key] {
            let isDone = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
            if isDone || (now - rec.lastProgressUptime >= 0.12) {
                rec.lastProgressUptime = now
                records[key] = rec
                cb = rec.onBytes
            }
        }
        lock.unlock()
        cb?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let key = ObjectIdentifier(downloadTask)
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("ls_dl_\(UUID().uuidString).part")
        var moved: URL? = nil
        var moveErr: Error? = nil
        do {
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: location, to: dst)
            moved = dst
        } catch {
            moveErr = error
        }
        lock.lock()
        if records[key] != nil {
            records[key]?.movedTempURL = moved
            records[key]?.moveError = moveErr
            lock.unlock()
        } else {
            lock.unlock()
            if let moved { try? FileManager.default.removeItem(at: moved) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = ObjectIdentifier(task)
        lock.lock()
        let rec = records.removeValue(forKey: key)
        tasksByID.removeValue(forKey: key)
        lock.unlock()
        guard let rec else { return }
        rec.cancelBox.markFinished()

        if let error {
            if let m = rec.movedTempURL { try? FileManager.default.removeItem(at: m) }
            rec.continuation.resume(throwing: error)
            return
        }
        if let moveErr = rec.moveError {
            if let m = rec.movedTempURL { try? FileManager.default.removeItem(at: m) }
            rec.continuation.resume(throwing: moveErr)
            return
        }
        guard let http = task.response as? HTTPURLResponse, let fileURL = rec.movedTempURL else {
            if let m = rec.movedTempURL { try? FileManager.default.removeItem(at: m) }
            rec.continuation.resume(throwing: URLError(.badServerResponse))
            return
        }
        rec.continuation.resume(returning: (fileURL, http))
    }
}

final class LocalSendRuntimeState: @unchecked Sendable {
    enum PairPinCheckResult {
        case ok
        case invalidPin
        case rateLimited
    }

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
    private var pairPin: String
    private var trustedPeers: [String: TrustedLanPeerRecord] = [:]
    private var fingerprintAliases: [String: String] = [:]
    private var pairFailuresByIP: [String: [Date]] = [:]

    init(fingerprint: String, alias: String, pairPin: String, trustedPeers: [TrustedLanPeerRecord]) {
        self.fingerprint = fingerprint
        self.alias = alias
        self.pairPin = pairPin
        for rec in trustedPeers {
            self.trustedPeers[rec.fingerprint] = rec
        }
    }

    nonisolated private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }

    func updatePairPin(_ nextPin: String) {
        lock.lock()
        pairPin = nextPin
        lock.unlock()
    }

    func verifyPairPin(remoteIP: String, pin: String) -> PairPinCheckResult {
        let now = Date()
        let cutoff = now.addingTimeInterval(-60)
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        var history = (pairFailuresByIP[remoteIP] ?? []).filter { $0 >= cutoff }
        if history.count >= 8 {
            pairFailuresByIP[remoteIP] = history
            return .rateLimited
        }
        if !pairPin.isEmpty && Self.constantTimeEqual(trimmed, pairPin) {
            pairFailuresByIP.removeValue(forKey: remoteIP)
            return .ok
        }
        history.append(now)
        pairFailuresByIP[remoteIP] = history
        return .invalidPin
    }

    func upsertTrustedPeer(_ record: TrustedLanPeerRecord, alternateFingerprint: String? = nil) -> [TrustedLanPeerRecord] {
        lock.lock()
        trustedPeers[record.fingerprint] = record
        if let alt = alternateFingerprint, !alt.isEmpty, alt != record.fingerprint {
            fingerprintAliases[alt] = record.fingerprint
        }
        let all = Array(trustedPeers.values).sorted { $0.alias < $1.alias }
        lock.unlock()
        return all
    }

    func clearTrustedPeers() {
        lock.lock()
        trustedPeers.removeAll()
        fingerprintAliases.removeAll()
        lock.unlock()
    }

    func isAuthorizedRequest(headers: [String: String], query: [String: String]) -> Bool {
        let raw = (headers["x-wallpull-token"] ?? query["authToken"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }
        lock.lock()
        let records = Array(trustedPeers.values)
        lock.unlock()
        return records.contains { Self.constantTimeEqual($0.incomingToken, raw) }
    }

    func isTrustedFingerprint(_ fingerprint: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let target = fingerprintAliases[fingerprint] ?? fingerprint
        return trustedPeers[target]?.outgoingToken != nil
    }

    func clearOutgoingToken(for fingerprint: String) -> [TrustedLanPeerRecord] {
        lock.lock()
        let target = fingerprintAliases[fingerprint] ?? fingerprint
        trustedPeers.removeValue(forKey: target)
        fingerprintAliases = fingerprintAliases.filter { $0.key != fingerprint && $0.value != target }
        let all = Array(trustedPeers.values).sorted { $0.alias < $1.alias }
        lock.unlock()
        return all
    }

    func outgoingToken(for fingerprint: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let direct = trustedPeers[fingerprint]?.outgoingToken {
            return direct
        }
        if let mapped = fingerprintAliases[fingerprint] {
            return trustedPeers[mapped]?.outgoingToken
        }
        return nil
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
    nonisolated static let wallpullPorts = [53417, 53418, 53419, 53420, 53421, 53422]
    nonisolated static let maxLanUploadBytes: Int64 = 4 * 1024 * 1024 * 1024

    @Published var peers: [LocalSendPeer] = []
    @Published var localIP: String = "未连接 Wi-Fi"
    @Published var listeningPort: Int = LocalSendService.wallpullDefaultPort
    @Published var transferProgress: TransferProgressState? = nil
    @Published var canCancelTransfer: Bool = false
    @Published var pcCatalog: [PCCatalogItem] = []
    @Published var isScanning: Bool = false
    @Published var isLoadingCatalog: Bool = false
    @Published var pairPin: String
    @Published var trustedPeers: [TrustedLanPeerRecord] = []
    @Published var pairingRequiredPeer: LocalSendPeer? = nil
    @Published var catalogErrorMessage: String? = nil
    @Published var activePullIDs: Set<String> = []

    let fingerprint: String
    nonisolated let runtime: LocalSendRuntimeState
    private weak var vault: LocalVaultStore?
    private var beaconTask: Task<Void, Never>? = nil
    private var reconcileTask: Task<Void, Never>? = nil
    private var enrichmentTask: Task<Void, Never>? = nil
    private var activePullTask: Task<Void, Never>? = nil
    private var enrichmentQueue: [EnrichmentJob] = []
    private var selectedPeerFingerprint: String? = nil
    private var transferCancelled: Bool = false
    private var isStartingHTTP: Bool = false
    private var isStartingUDP: Bool = false
    private let lastEndpointsKey = "wp_last_peer_endpoints"
    private let deviceFingerprintKey = "wp_device_fingerprint"
    private let pairPinKey = "wp_lan_pair_pin"
    private let trustedPeersKey = "wp_lan_trusted_peers"
    private var lastKnownEndpoints: [String] = []
    private let transferCoordinator = StreamingDownloadCoordinator()

    private struct EnrichmentJob {
        let pcItem: PCCatalogItem
        let localItemID: String
        let peer: LocalSendPeer
        let prefetchStudio: Bool
    }

    func cancelActiveTransfer() {
        transferCancelled = true
        transferCoordinator.cancelAll()
        activePullTask?.cancel()
        vault?.showToast("正在安全停止当前传输…")
    }

    lazy var lanURLSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 180
        return URLSession(configuration: cfg, delegate: LocalSendInsecureLanDelegate(), delegateQueue: nil)
    }()

    lazy var uploadURLSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600
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
        let ud = UserDefaults.standard
        let savedFP = ud.string(forKey: "wp_device_fingerprint")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fp: String
        if let savedFP, !savedFP.isEmpty {
            fp = savedFP
        } else {
            fp = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            ud.set(fp, forKey: "wp_device_fingerprint")
        }
        self.fingerprint = fp

        let savedPin = ud.string(forKey: "wp_lan_pair_pin")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pin: String
        if let savedPin, savedPin.count == 4, savedPin.allSatisfy(\.isNumber) {
            pin = savedPin
        } else {
            pin = String(format: "%04d", Int.random(in: 0...9999))
            ud.set(pin, forKey: "wp_lan_pair_pin")
        }
        self.pairPin = pin

        var loadedTrusted: [TrustedLanPeerRecord] = []
        if let rawData = ud.data(forKey: "wp_lan_trusted_peers"),
           let decoded = try? JSONDecoder().decode([TrustedLanPeerRecord].self, from: rawData) {
            loadedTrusted = decoded
        }
        self.trustedPeers = loadedTrusted

        let initialAlias = vault.deviceAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        self.runtime = LocalSendRuntimeState(
            fingerprint: fp,
            alias: initialAlias.isEmpty ? UIDevice.current.name : initialAlias,
            pairPin: pin,
            trustedPeers: loadedTrusted
        )
        self.lastKnownEndpoints = ud.stringArray(forKey: "wp_last_peer_endpoints") ?? []
        let rt = self.runtime
        vault.onAliasChanged = { newAlias in
            rt.updateAlias(newAlias)
        }
    }

    private func persistTrustedPeers(_ list: [TrustedLanPeerRecord]) {
        trustedPeers = list
        if let encoded = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(encoded, forKey: trustedPeersKey)
        }
    }

    func rotatePairPin() {
        let nextPin = String(format: "%04d", Int.random(in: 0...9999))
        pairPin = nextPin
        UserDefaults.standard.set(nextPin, forKey: pairPinKey)
        runtime.updatePairPin(nextPin)
        vault?.showToast("已刷新配对码：\(nextPin)")
    }

    func clearTrustedPeers() {
        runtime.clearTrustedPeers()
        persistTrustedPeers([])
        pcCatalog = []
        vault?.showToast("已解除所有设备配对")
    }

    private func handleUnauthorizedPeer(_ peer: LocalSendPeer) {
        let updated = runtime.clearOutgoingToken(for: peer.fingerprint)
        persistTrustedPeers(updated)
        pairingRequiredPeer = peer
    }

    func isPeerTrusted(_ peer: LocalSendPeer) -> Bool {
        runtime.outgoingToken(for: peer.fingerprint) != nil
    }

    nonisolated func authToken(for peer: LocalSendPeer) -> String? {
        runtime.outgoingToken(for: peer.fingerprint)
    }

    nonisolated func applyAuthHeader(_ req: inout URLRequest, for peer: LocalSendPeer) {
        if let tok = runtime.outgoingToken(for: peer.fingerprint) {
            req.setValue(tok, forHTTPHeaderField: "X-WallPull-Token")
        }
    }

    func pair(with peer: LocalSendPeer, pin: String) async -> (ok: Bool, message: String) {
        let cleanPin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanPin.count == 4, cleanPin.allSatisfy(\.isNumber) else {
            return (false, "请输入 4 位数字配对码")
        }
        let clientToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let info = deviceInfo(announce: nil)
        guard let infoData = try? JSONEncoder().encode(info),
              let infoObj = try? JSONSerialization.jsonObject(with: infoData),
              let url = URL(string: "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/wallpull/pair"),
              let body = try? JSONSerialization.data(withJSONObject: [
                  "info": infoObj,
                  "pin": cleanPin,
                  "clientToken": clientToken,
              ]) else {
            return (false, "构造配对请求失败")
        }

        var req = URLRequest(url: url, timeoutInterval: 8.0)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        do {
            let (data, resp) = try await lanURLSession.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return (false, "对方设备响应无效")
            }
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if http.statusCode == 200, let serverToken = obj["token"] as? String, !serverToken.isEmpty {
                let remoteFP = (obj["fingerprint"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? peer.fingerprint
                let remoteAlias = (obj["alias"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? peer.alias
                let rec = TrustedLanPeerRecord(
                    fingerprint: remoteFP,
                    alias: remoteAlias,
                    incomingToken: clientToken,
                    outgoingToken: serverToken
                )
                let updated = runtime.upsertTrustedPeer(rec, alternateFingerprint: peer.fingerprint)
                persistTrustedPeers(updated)
                pairingRequiredPeer = nil
                upsertPeer(peer, authVerified: true)
                touchPeerAlive(fingerprint: peer.fingerprint)
                vault?.showToast("已与「\(remoteAlias)」完成配对")
                return (true, "已与「\(remoteAlias)」完成配对")
            }
            let msg = (obj["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (http.statusCode == 429 ? "配对尝试过于频繁，请稍后再试" : "配对码错误")
            return (false, msg)
        } catch {
            return (false, "无法连接到「\(peer.alias)」：\(error.localizedDescription)")
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
                    for port in Self.wallpullPorts {
                        let scheme = "http"
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
        let ports = customPort.map { [$0] } ?? Self.wallpullPorts
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
        catalogErrorMessage = nil
        defer { isLoadingCatalog = false }
        var req = URLRequest(url: url, timeoutInterval: 8.0)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        applyAuthHeader(&req, for: peer)
        do {
            let (data, resp) = try await lanURLSession.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                catalogErrorMessage = "无法连接到「\(peer.alias)」，请检查网络后重试"
                return
            }
            if http.statusCode == 401 {
                handleUnauthorizedPeer(peer)
                catalogErrorMessage = nil
                return
            }
            guard http.statusCode == 200,
                  let items = try? JSONDecoder().decode([PCCatalogItem].self, from: data) else {
                catalogErrorMessage = "获取「\(peer.alias)」壁纸目录失败，请重试"
                return
            }
            touchPeerAlive(fingerprint: peer.fingerprint)
            pairingRequiredPeer = nil
            catalogErrorMessage = nil
            pcCatalog = items
            reconcileTask?.cancel()
            reconcileTask = Task { [weak self] in
                await self?.reconcileVaultWithCatalog(items, peer: peer)
            }
        } catch {
            if (error as? CancellationError) == nil {
                catalogErrorMessage = "无法连接到「\(peer.alias)」，请检查网络后重试"
            }
        }
    }

    func pcThumbURL(for item: PCCatalogItem, peer: LocalSendPeer) -> URL? {
        let encoded = item.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item.id
        var raw = "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/wallpull/thumb?id=\(encoded)"
        if let tok = authToken(for: peer)?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            raw += "&authToken=\(tok)"
        }
        return URL(string: raw)
    }

    func pcAssetURL(for item: PCCatalogItem, peer: LocalSendPeer, variantIndex: Int = 0) -> URL? {
        let encoded = item.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item.id
        var raw = "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/wallpull/asset?id=\(encoded)&index=\(variantIndex)"
        if let tok = authToken(for: peer)?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            raw += "&authToken=\(tok)"
        }
        return URL(string: raw)
    }

    func pcPreviewVideoURL(for item: PCCatalogItem, peer: LocalSendPeer) -> URL? {
        let encoded = item.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item.id
        var raw = "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/wallpull/preview-video?id=\(encoded)"
        if let tok = authToken(for: peer)?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            raw += "&authToken=\(tok)"
        }
        return URL(string: raw)
    }

    func cachedThumbImage(for item: PCCatalogItem, peer: LocalSendPeer) -> UIImage? {
        PCThumbnailCache.shared.image(forKey: "\(peer.ip):\(item.id)")
    }

    func makePCThumbRequest(for item: PCCatalogItem, peer: LocalSendPeer) -> URLRequest? {
        guard let url = pcThumbURL(for: item, peer: peer) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.cachePolicy = .returnCacheDataElseLoad
        applyAuthHeader(&req, for: peer)
        return req
    }

    func loadCachedPCThumb(for item: PCCatalogItem, peer: LocalSendPeer) async -> UIImage? {
        let key = "\(peer.ip):\(item.id)"
        if let cached = PCThumbnailCache.shared.image(forKey: key) {
            return cached
        }
        guard let req = makePCThumbRequest(for: item, peer: peer) else { return nil }
        let res = await PCThumbnailCache.shared.loadOrFetch(cacheKey: key, request: req, session: lanURLSession)
        if res.unauthorized {
            handleUnauthorizedPeer(peer)
        }
        return res.image
    }

    private func reconcileVaultWithCatalog(_ catalog: [PCCatalogItem], peer: LocalSendPeer) async {
        guard let vault else { return }
        let byRemote = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        let byTitle = Dictionary(catalog.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        let session = lanURLSession

        for existing in vault.items {
            if Task.isCancelled { return }
            while !activePullIDs.isEmpty && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if Task.isCancelled { return }
            if enrichmentQueue.contains(where: { $0.localItemID == existing.id }) {
                continue
            }
            guard vault.items.contains(where: { $0.id == existing.id }) else {
                continue
            }
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
                if let prevName = await Self.downloadPreviewVideo(for: pcItem, localItemID: existing.id, peer: peer, previewsDir: vault.previewsDir, session: session, token: authToken(for: peer)) {
                    vault.updateItemMetadata(id: existing.id) { $0.previewVideoFileName = prevName }
                }
            }
            if !pcItem.isVideo, (pcItem.assetCount ?? 1) > 1, (existing.additionalFiles ?? []).isEmpty {
                let extras = await Self.downloadAdditionalVariants(for: pcItem, localItemID: existing.id, peer: peer, mediaDir: vault.mediaDir, session: session, token: authToken(for: peer))
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
        session: URLSession,
        token: String?
    ) async -> String? {
        guard pcItem.isVideo else { return nil }
        let encodedId = pcItem.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? pcItem.id
        guard let url = URL(string: "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/wallpull/preview-video?id=\(encodedId)") else {
            return nil
        }
        var req = URLRequest(url: url, timeoutInterval: 45)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let token, !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "X-WallPull-Token")
        }
        if let (tmpURL, resp) = try? await session.download(for: req) {
            defer { try? FileManager.default.removeItem(at: tmpURL) }
            if let http = resp as? HTTPURLResponse,
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
            }
        }
        return nil
    }

    nonisolated private static func downloadAdditionalVariants(
        for pcItem: PCCatalogItem,
        localItemID: String,
        peer: LocalSendPeer,
        mediaDir: URL,
        session: URLSession,
        token: String?
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
            if let token, !token.isEmpty {
                req.setValue(token, forHTTPHeaderField: "X-WallPull-Token")
            }
            if let (tmpURL, resp) = try? await session.download(for: req) {
                defer { try? FileManager.default.removeItem(at: tmpURL) }
                if let http = resp as? HTTPURLResponse,
                   http.statusCode == 200 || http.statusCode == 206 {
                    let suggestedExt = (resp.suggestedFilename.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }) ?? ""
                    let ext = suggestedExt.isEmpty ? safeExt : suggestedExt
                    let localName = "\(localItemID)_v\(idx).\(ext)"
                    let dst = mediaDir.appendingPathComponent(localName)
                    try? FileManager.default.removeItem(at: dst)
                    if (try? FileManager.default.moveItem(at: tmpURL, to: dst)) != nil {
                        out.append(localName)
                    }
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
            if dto.isEmbedded == true && pcItem.isVideo {
                continue
            }
            guard let url = URL(string: "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/wallpull/audio?id=\(encodedId)&track=\(dto.index)") else {
                continue
            }
            var req = URLRequest(url: url, timeoutInterval: 45)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            applyAuthHeader(&req, for: peer)
            if let (tmpURL, resp) = try? await lanURLSession.download(for: req) {
                defer { try? FileManager.default.removeItem(at: tmpURL) }
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 {
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
                    }
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
        applyAuthHeader(&req, for: peer)
        guard let (data, resp) = try? await lanURLSession.data(for: req),
              let http = resp as? HTTPURLResponse else {
            return nil
        }
        if http.statusCode == 401 {
            handleUnauthorizedPeer(peer)
            return nil
        }
        guard http.statusCode == 200 else {
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
        applyAuthHeader(&req, for: peer)
        req.httpBody = body
        guard let (data, resp) = try? await lanURLSession.data(for: req),
              let http = resp as? HTTPURLResponse else {
            return nil
        }
        if http.statusCode == 401 {
            handleUnauthorizedPeer(peer)
            return nil
        }
        guard http.statusCode == 200 else {
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
        applyAuthHeader(&req, for: peer)
        guard let (data, resp) = try? await lanURLSession.data(for: req),
              let http = resp as? HTTPURLResponse else {
            return nil
        }
        if http.statusCode == 401 {
            handleUnauthorizedPeer(peer)
            return nil
        }
        guard http.statusCode == 200,
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

    private enum MainAssetDownloadOutcome {
        case success(VaultItem)
        case pairingRequired
        case failed
        case cancelled
    }

    nonisolated private static func downloadMainAssetAndBuildVaultItem(
        item: PCCatalogItem,
        peer: LocalSendPeer,
        token: String?,
        coordinator: StreamingDownloadCoordinator,
        mediaDir: URL,
        thumbsDir: URL,
        onBytes: @escaping @Sendable (Int64, Int64) -> Void
    ) async -> MainAssetDownloadOutcome {
        let encoded = item.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item.id
        guard let url = URL(string: "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/wallpull/asset?id=\(encoded)") else {
            return .failed
        }
        var req = URLRequest(url: url, timeoutInterval: 210)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let token, !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "X-WallPull-Token")
        }

        let localTempURL: URL
        let httpResp: HTTPURLResponse
        do {
            (localTempURL, httpResp) = try await coordinator.download(request: req, onBytes: onBytes)
        } catch {
            let nsErr = error as NSError
            if error is CancellationError || (nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled) {
                return .cancelled
            }
            return .failed
        }
        defer { try? FileManager.default.removeItem(at: localTempURL) }

        if httpResp.statusCode == 401 {
            return .pairingRequired
        }
        guard httpResp.statusCode == 200 || httpResp.statusCode == 206 else {
            return .failed
        }
        if Task.isCancelled {
            return .cancelled
        }

        let newID = UUID().uuidString
        let ext = URL(fileURLWithPath: item.fileName).pathExtension.lowercased()
        let contentType = (httpResp.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let safeExt: String
        if item.isVideo && contentType.contains("video/mp4") {
            safeExt = "mp4"
        } else {
            safeExt = ext.isEmpty ? (item.isVideo ? "mp4" : "png") : ext
        }
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
            return .failed
        }

        let built = VaultItem(
            id: newID,
            title: item.title,
            mediaType: analyzed.mediaType,
            fileName: storedFileName,
            thumbFileName: analyzed.thumbFileName,
            previewVideoFileName: nil,
            width: analyzed.width,
            height: analyzed.height,
            durationSeconds: analyzed.durationSeconds,
            fileSize: analyzed.fileSize,
            isTransparentCutout: analyzed.isTransparentCutout,
            colorBucket: analyzed.colorBucket,
            contentRating: item.contentRating,
            isFavorite: item.isPCFavorite,
            addedAt: Date(),
            sourceDevice: peer.alias,
            sha256: nil,
            remoteID: item.id,
            audioTracks: nil,
            additionalFiles: nil,
            hasSceneLayers: item.supportsStudio,
            hasOfflineStudioBundle: false,
            hasEmbeddedAudio: analyzed.mediaType == .video ? analyzed.hasEmbeddedAudio : nil,
            visualFingerprint: nil
        )
        return .success(built)
    }

    private func enqueueBackgroundEnrichment(_ job: EnrichmentJob) {
        enrichmentQueue.append(job)
        if activePullIDs.isEmpty {
            startEnrichmentWorkerIfNeeded()
        }
    }

    private func startEnrichmentWorkerIfNeeded() {
        guard enrichmentTask == nil, !enrichmentQueue.isEmpty else { return }
        enrichmentTask = Task { [weak self] in
            guard let self else { return }
            defer { self.enrichmentTask = nil }
            while !self.enrichmentQueue.isEmpty {
                while !self.activePullIDs.isEmpty {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                guard let job = self.enrichmentQueue.first else { break }
                self.enrichmentQueue.removeFirst()
                guard let vault = self.vault,
                      vault.items.contains(where: { $0.id == job.localItemID }) else { continue }

                let pcItem = job.pcItem
                let itemID = job.localItemID
                let peer = job.peer
                let session = self.lanURLSession
                let token = self.authToken(for: peer)

                if pcItem.isVideo {
                    var prevName = await Self.downloadPreviewVideo(
                        for: pcItem,
                        localItemID: itemID,
                        peer: peer,
                        previewsDir: vault.previewsDir,
                        session: session,
                        token: token
                    )
                    if prevName == nil,
                       let liveItem = vault.items.first(where: { $0.id == itemID }) {
                        let storedURL = vault.mediaURL(for: liveItem)
                        prevName = await LocalVaultStore.generateLightweightVideoPreview(
                            srcURL: storedURL,
                            id: itemID,
                            previewsDir: vault.previewsDir
                        )
                    }
                    if let prevName, vault.items.contains(where: { $0.id == itemID }) {
                        vault.updateItemMetadata(id: itemID) { $0.previewVideoFileName = prevName }
                    }
                }

                if !pcItem.isVideo && (pcItem.assetCount ?? 1) > 1 {
                    let extras = await Self.downloadAdditionalVariants(
                        for: pcItem,
                        localItemID: itemID,
                        peer: peer,
                        mediaDir: vault.mediaDir,
                        session: session,
                        token: token
                    )
                    if !extras.isEmpty && vault.items.contains(where: { $0.id == itemID }) {
                        vault.updateItemMetadata(id: itemID) { $0.additionalFiles = extras }
                    }
                }

                if pcItem.hasMusic {
                    let tracks = await self.downloadAudioTracks(
                        for: pcItem,
                        localItemID: itemID,
                        peer: peer,
                        audioDir: vault.audioDir
                    )
                    if !tracks.isEmpty && vault.items.contains(where: { $0.id == itemID }) {
                        vault.updateItemMetadata(id: itemID) { $0.audioTracks = tracks }
                    }
                }

                if job.prefetchStudio && pcItem.supportsStudio,
                   vault.items.contains(where: { $0.id == itemID }) {
                    _ = await self.fetchAndCacheOfflineBundle(remoteID: pcItem.id, localItemID: itemID, peer: peer)
                }
            }
            self.vault?.flushCatalogSaveNow()
        }
    }

    func pullCatalogItemsToVault(_ selected: [PCCatalogItem], from peer: LocalSendPeer) async {
        guard !selected.isEmpty, let vault else { return }
        if !activePullIDs.isEmpty {
            vault.showToast("已有传输任务进行中，请等待或先停止")
            return
        }
        guard isPeerTrusted(peer) else {
            pairingRequiredPeer = peer
            return
        }

        let pendingRaw = selected.filter { !vault.hasImportedCatalogItem($0) }
        if pendingRaw.isEmpty {
            vault.showToast("所选壁纸已全部在离线库中，无需重复下载")
            return
        }

        // Small-to-large scheduling: light images first (ascending), then small videos (<40MB), then large videos (>=40MB)
        let imageItems = pendingRaw.filter { !$0.isVideo }.sorted { $0.fileSize < $1.fileSize }
        let smallVideos = pendingRaw.filter { $0.isVideo && $0.fileSize < 40_000_000 }.sorted { $0.fileSize < $1.fileSize }
        let largeVideos = pendingRaw.filter { $0.isVideo && $0.fileSize >= 40_000_000 }.sorted { $0.fileSize < $1.fileSize }

        let total = pendingRaw.count
        let totalEstimatedBytes = max(Int64(1), pendingRaw.reduce(0) { $0 + max(Int64(1), $1.fileSize) })

        activePullIDs = Set(pendingRaw.map(\.id))
        transferCancelled = false
        canCancelTransfer = true
        transferProgress = TransferProgressState(
            title: "准备接收 \(total) 项壁纸…",
            currentFileIndex: 0,
            totalFiles: total,
            fraction: 0.02,
            bytesTransferred: 0,
            totalBytes: totalEstimatedBytes
        )

        let runner = Task<Void, Never> { @MainActor [weak self] in
            guard let self, let vault = self.vault else { return }

            let coordinator = self.transferCoordinator
            let mDir = vault.mediaDir
            let tDir = vault.thumbsDir
            let authTok = self.authToken(for: peer)
            let shouldPrefetchStudio = total <= 12

            var completedBytes: Int64 = 0
            var importedCount = 0
            var processedCount = 0
            var failedCount = 0
            var hitPairingRequired = false

            var inFlight: [String: (item: PCCatalogItem, written: Int64, expected: Int64, startedAt: Date)] = [:]
            var lastBytesSample: Int64 = 0
            var lastSampleTime = Date()
            var lastPublishTime = Date.distantPast
            var smoothedBps: Double = 0

            let publishLiveProgress: @MainActor (Bool) -> Void = { [weak self] force in
                guard let self else { return }
                let now = Date()
                if !force && now.timeIntervalSince(lastPublishTime) < 0.14 {
                    return
                }
                let inflightSum = inFlight.values.reduce(Int64(0)) { $0 + $1.written }
                let liveBytes = min(max(totalEstimatedBytes, completedBytes + inflightSum), completedBytes + inflightSum)
                let dt = now.timeIntervalSince(lastSampleTime)
                if dt >= 0.25 {
                    let delta = max(Int64(0), liveBytes - lastBytesSample)
                    if delta == 0 && dt >= 0.45 {
                        smoothedBps = smoothedBps < 51_200 ? 0 : smoothedBps * 0.45
                    } else {
                        let instant = Double(delta) / dt
                        smoothedBps = smoothedBps > 0 ? (smoothedBps * 0.65 + instant * 0.35) : instant
                    }
                    lastBytesSample = liveBytes
                    lastSampleTime = now
                }
                lastPublishTime = now

                let activeEntry = inFlight.values.max(by: { $0.item.fileSize < $1.item.fileSize })
                let titleText: String
                let stageHint: String?
                if let activeEntry {
                    if activeEntry.item.isVideo && activeEntry.written == 0 && now.timeIntervalSince(activeEntry.startedAt) > 1.2 {
                        titleText = "转码准备 · \(activeEntry.item.title)"
                        stageHint = "电脑端视频适配中…"
                    } else {
                        titleText = "下载 · \(activeEntry.item.title)"
                        stageHint = nil
                    }
                } else {
                    titleText = "正在收入壁纸 (\(processedCount)/\(total))"
                    stageHint = nil
                }
                let denom = max(totalEstimatedBytes, liveBytes)
                let frac = min(0.99, max(0.02, Double(liveBytes) / Double(denom)))
                self.transferProgress = TransferProgressState(
                    title: titleText,
                    currentFileIndex: min(total, max(1, processedCount + (inFlight.isEmpty ? 0 : 1))),
                    totalFiles: total,
                    fraction: frac,
                    bytesTransferred: liveBytes,
                    totalBytes: totalEstimatedBytes,
                    bytesPerSecond: smoothedBps,
                    stageHint: stageHint
                )
            }

            let heartbeatTask = Task<Void, Never> { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if !Task.isCancelled {
                        publishLiveProgress(false)
                    }
                }
            }
            defer {
                heartbeatTask.cancel()
                self.activePullIDs.removeAll()
                self.canCancelTransfer = false
                self.transferProgress = nil
                vault.flushCatalogSaveNow()
                self.startEnrichmentWorkerIfNeeded()
            }

            for (stageItems, maxConcurrent) in [(imageItems, 3), (smallVideos, 2), (largeVideos, 1)] {
                guard !stageItems.isEmpty, !self.transferCancelled, !hitPairingRequired, !Task.isCancelled else { continue }
                var nextIdx = 0
                await withTaskGroup(of: (PCCatalogItem, MainAssetDownloadOutcome).self) { group in
                    while nextIdx < stageItems.count && nextIdx < maxConcurrent {
                        let target = stageItems[nextIdx]
                        nextIdx += 1
                        inFlight[target.id] = (target, 0, max(Int64(1), target.fileSize), Date())
                        publishLiveProgress(true)
                        let targetID = target.id
                        group.addTask {
                            let outcome = await Self.downloadMainAssetAndBuildVaultItem(
                                item: target,
                                peer: peer,
                                token: authTok,
                                coordinator: coordinator,
                                mediaDir: mDir,
                                thumbsDir: tDir,
                                onBytes: { written, expected in
                                    Task { @MainActor in
                                        guard inFlight[targetID] != nil else { return }
                                        inFlight[targetID]?.written = written
                                        if expected > 0 {
                                            inFlight[targetID]?.expected = expected
                                        }
                                        publishLiveProgress(false)
                                    }
                                }
                            )
                            return (target, outcome)
                        }
                    }

                    while let (finishedItem, outcome) = await group.next() {
                        let prevWritten = inFlight.removeValue(forKey: finishedItem.id)?.written ?? 0
                        processedCount += 1

                        switch outcome {
                        case .success(let built):
                            completedBytes += max(prevWritten, built.fileSize)
                            let inserted = vault.insertStreamedItem(built)
                            if inserted {
                                importedCount += 1
                                self.touchPeerAlive(fingerprint: peer.fingerprint)
                                self.enqueueBackgroundEnrichment(EnrichmentJob(
                                    pcItem: finishedItem,
                                    localItemID: built.id,
                                    peer: peer,
                                    prefetchStudio: shouldPrefetchStudio
                                ))
                            }
                        case .pairingRequired:
                            hitPairingRequired = true
                            self.transferCancelled = true
                            coordinator.cancelAll()
                            group.cancelAll()
                        case .cancelled:
                            completedBytes += prevWritten
                        case .failed:
                            failedCount += 1
                        }

                        publishLiveProgress(true)

                        if !self.transferCancelled && !hitPairingRequired && !Task.isCancelled && nextIdx < stageItems.count {
                            let target = stageItems[nextIdx]
                            nextIdx += 1
                            inFlight[target.id] = (target, 0, max(Int64(1), target.fileSize), Date())
                            publishLiveProgress(true)
                            let targetID = target.id
                            group.addTask {
                                let outcome = await Self.downloadMainAssetAndBuildVaultItem(
                                    item: target,
                                    peer: peer,
                                    token: authTok,
                                    coordinator: coordinator,
                                    mediaDir: mDir,
                                    thumbsDir: tDir,
                                    onBytes: { written, expected in
                                        Task { @MainActor in
                                            guard inFlight[targetID] != nil else { return }
                                            inFlight[targetID]?.written = written
                                            if expected > 0 {
                                                inFlight[targetID]?.expected = expected
                                            }
                                            publishLiveProgress(false)
                                        }
                                    }
                                )
                                return (target, outcome)
                            }
                        } else if self.transferCancelled || hitPairingRequired || Task.isCancelled {
                            group.cancelAll()
                        }
                    }
                }
            }

            if hitPairingRequired {
                self.handleUnauthorizedPeer(peer)
                vault.showToast("连接需验证配对码", isError: true)
            } else if self.transferCancelled || Task.isCancelled {
                vault.showToast("已停止传输（已完成 \(importedCount) 项）")
            } else if failedCount > 0 && importedCount > 0 {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                vault.showToast("已收入 \(importedCount) 项，\(failedCount) 项失败")
            } else if importedCount > 0 {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                vault.showToast("已无损收入 \(importedCount) 项到离线库")
            } else {
                vault.showToast("收入失败，请检查网络连接", isError: true)
            }
        }

        self.activePullTask = runner
        await runner.value
        self.activePullTask = nil
    }

    func sendVaultItems(
        _ items: [VaultItem],
        to peer: LocalSendPeer,
        targetMode: String = "vault",
        overrideMediaURLs: [String: URL] = [:]
    ) async {
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
            let fileURL = overrideMediaURLs[item.id] ?? vault.mediaURL(for: item)
            return FileManager.default.fileExists(atPath: fileURL.path) ? (item, fileURL) : nil
        }
        guard !itemURLs.isEmpty else {
            vault.showToast("没有找到可发送的本地文件", isError: true)
            return
        }

        let preparedData = await Task.detached(priority: .userInitiated) { () -> ([String: [String: Any]], [(id: String, url: URL, size: Int64)], [URL]) in
            var fileDTOs: [String: [String: Any]] = [:]
            var prepared: [(id: String, url: URL, size: Int64)] = []
            var tempFiles: [URL] = []
            for (item, origURL) in itemURLs {
                var effectiveURL = origURL
                var ext = origURL.pathExtension.lowercased()
                if item.mediaType == .image && (ext == "heic" || ext == "heif") {
                    if let uiImg = UIImage(contentsOfFile: origURL.path),
                       let jpgData = uiImg.jpegData(compressionQuality: 0.94) {
                        let tmpJpg = FileManager.default.temporaryDirectory
                            .appendingPathComponent("ls_tx_\(UUID().uuidString).jpg")
                        if (try? jpgData.write(to: tmpJpg, options: [.atomic])) != nil {
                            effectiveURL = tmpJpg
                            ext = "jpg"
                            tempFiles.append(tmpJpg)
                        }
                    }
                }
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: effectiveURL.path),
                      let actualSize = (attrs[.size] as? NSNumber)?.int64Value,
                      actualSize > 0,
                      let digest = LocalVaultStore.streamedFullSHA256(effectiveURL) else {
                    continue
                }
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
                    "size": actualSize,
                    "fileType": mime,
                    "sha256": digest,
                    "metadata": meta,
                ]
                prepared.append((fid, effectiveURL, actualSize))
            }
            return (fileDTOs, prepared, tempFiles)
        }.value

        let fileDTOs = preparedData.0
        let prepared = preparedData.1
        let tempConvertedFiles = preparedData.2
        defer {
            for tmp in tempConvertedFiles {
                try? FileManager.default.removeItem(at: tmp)
            }
        }
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
        applyAuthHeader(&prepReq, for: peer)
        prepReq.httpBody = prepBody

        var activeSessionId: String? = nil
        do {
            let (respData, resp) = try await lanURLSession.data(for: prepReq)
            guard let http = resp as? HTTPURLResponse else { return }
            if http.statusCode == 401 {
                handleUnauthorizedPeer(peer)
                vault.showToast("发送给「\(peer.alias)」需要配对验证", isError: true)
                return
            }
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
            activeSessionId = sessionId

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
                var upReq = URLRequest(url: upURL, timeoutInterval: 600)
                upReq.httpMethod = "POST"
                upReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                applyAuthHeader(&upReq, for: peer)
                let (_, upResp) = try await uploadURLSession.upload(for: upReq, fromFile: entry.url)
                if let h = upResp as? HTTPURLResponse, h.statusCode == 401 {
                    if let sid = activeSessionId {
                        await cancelRemoteUploadSession(sid, on: peer)
                    }
                    handleUnauthorizedPeer(peer)
                    vault.showToast("发送给「\(peer.alias)」需要配对验证", isError: true)
                    return
                }
                if let h = upResp as? HTTPURLResponse, h.statusCode != 200 {
                    throw URLError(.cannotWriteToFile)
                }
            }
            activeSessionId = nil
            touchPeerAlive(fingerprint: peer.fingerprint)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            vault.showToast(targetMode == "clipboard" ? "已隔空推送到「\(peer.alias)」剪贴板" : "已无损发送 \(prepared.count) 项给「\(peer.alias)」")
        } catch {
            if let sid = activeSessionId {
                await cancelRemoteUploadSession(sid, on: peer)
            }
            vault.showToast("发送失败：\(error.localizedDescription)", isError: true)
        }
    }

    private func cancelRemoteUploadSession(_ sessionId: String, on peer: LocalSendPeer) async {
        let encSid = sessionId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sessionId
        guard let url = URL(string: "\(peer.scheme)://\(peer.ip):\(peer.port)/api/localsend/v2/cancel?sessionId=\(encSid)") else {
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        applyAuthHeader(&req, for: peer)
        _ = try? await lanURLSession.data(for: req)
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

    func touchPeerAlive(fingerprint: String) {
        let now = Date()
        if let idx = peers.firstIndex(where: { $0.fingerprint == fingerprint }),
           now.timeIntervalSince(peers[idx].lastSeen) >= 8.0 || peers[idx].missedHeartbeats > 0 {
            peers[idx].lastSeen = now
            peers[idx].missedHeartbeats = 0
        }
    }

    private func touchPeerAliveByIP(_ ip: String) {
        let now = Date()
        for idx in peers.indices where peers[idx].ip == ip && (now.timeIntervalSince(peers[idx].lastSeen) >= 8.0 || peers[idx].missedHeartbeats > 0) {
            peers[idx].lastSeen = now
            peers[idx].missedHeartbeats = 0
        }
    }

    private func upsertPeer(_ peer: LocalSendPeer, authVerified: Bool = false) {
        var normalized = peer
        normalized.lastSeen = Date()
        normalized.missedHeartbeats = 0
        if !authVerified,
           runtime.isTrustedFingerprint(normalized.fingerprint),
           let existing = peers.first(where: { $0.fingerprint == normalized.fingerprint }),
           existing.ip != normalized.ip || existing.port != normalized.port {
            return
        }
        rememberEndpoint(scheme: normalized.scheme, ip: normalized.ip, port: normalized.port)
        peers.removeAll { existing in
            existing.ip == normalized.ip && existing.port == normalized.port && existing.fingerprint != normalized.fingerprint
        }
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
                if n < 0 {
                    let err = Darwin.errno
                    if err == EINTR || err == EAGAIN || err == EWOULDBLOCK { continue }
                    break
                }
                if n == 0 { continue }
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
            for port in Self.wallpullPorts {
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
        var fatalErrors = 0
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
                if err == EINTR || err == EAGAIN || err == EWOULDBLOCK { continue }
                if err == EBADF || err == EINVAL { break }
                fatalErrors += 1
                if fatalErrors > 16 { break }
                continue
            }
            fatalErrors = 0
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

        case ("POST", "/api/localsend/v2/wallpull/pair"):
            guard let body = Self.readRequestBody(fd: fd, leftover: leftover, contentLength: Int(contentLen ?? 0), isChunked: isChunked, maxBytes: 256 * 1024),
                  let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let infoObj = root["info"],
                  let infoBytes = try? JSONSerialization.data(withJSONObject: infoObj),
                  let peerInfo = try? JSONDecoder().decode(LocalSendDeviceInfo.self, from: infoBytes),
                  peerInfo.isWallPullDevice,
                  peerInfo.fingerprint != runtime.fingerprint else {
                Self.sendHTTP(fd: fd, status: 400, reason: "Bad Request", contentType: "application/json", body: Data("{\"message\":\"Invalid pairing request\",\"code\":\"INVALID_REQUEST\"}".utf8))
                return
            }
            let pin = (root["pin"] as? String) ?? ""
            let clientToken = ((root["clientToken"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard clientToken.count >= 16 else {
                Self.sendHTTP(fd: fd, status: 400, reason: "Bad Request", contentType: "application/json", body: Data("{\"message\":\"Invalid client token\",\"code\":\"INVALID_TOKEN\"}".utf8))
                return
            }
            switch runtime.verifyPairPin(remoteIP: remoteIP, pin: pin) {
            case .rateLimited:
                Self.sendHTTP(fd: fd, status: 429, reason: "Too Many Requests", contentType: "application/json", body: Data("{\"message\":\"配对尝试过于频繁，请稍后再试\",\"code\":\"RATE_LIMITED\"}".utf8))
                return
            case .invalidPin:
                Self.sendHTTP(fd: fd, status: 401, reason: "Unauthorized", contentType: "application/json", body: Data("{\"message\":\"配对码错误\",\"code\":\"INVALID_PIN\"}".utf8))
                return
            case .ok:
                break
            }
            let serverToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let rec = TrustedLanPeerRecord(
                fingerprint: peerInfo.fingerprint,
                alias: peerInfo.alias,
                incomingToken: serverToken,
                outgoingToken: clientToken
            )
            let updatedList = runtime.upsertTrustedPeer(rec)
            let discovered = LocalSendPeer(
                fingerprint: peerInfo.fingerprint,
                alias: peerInfo.alias,
                deviceModel: peerInfo.deviceModel,
                deviceType: peerInfo.deviceType,
                ip: remoteIP,
                port: peerInfo.port ?? Self.wallpullDefaultPort,
                scheme: (peerInfo.protocolName ?? "http").lowercased() == "https" ? "https" : "http",
                supportsWallPullCatalog: peerInfo.download ?? false,
                lastSeen: Date()
            )
            Task { @MainActor [weak self] in
                self?.persistTrustedPeers(updatedList)
                self?.upsertPeer(discovered, authVerified: true)
            }
            let replyInfo = snapshotDeviceInfo(announce: nil)
            let pairResp: [String: Any] = [
                "ok": true,
                "token": serverToken,
                "fingerprint": replyInfo.fingerprint,
                "alias": replyInfo.alias,
            ]
            if let respData = try? JSONSerialization.data(withJSONObject: pairResp) {
                Self.sendHTTP(fd: fd, status: 200, reason: "OK", contentType: "application/json", body: respData)
            }

        case ("POST", "/api/localsend/v2/prepare-upload"):
            guard runtime.isAuthorizedRequest(headers: headers, query: query) else {
                Self.sendHTTP(fd: fd, status: 401, reason: "Unauthorized", contentType: "application/json", body: Data("{\"message\":\"设备尚未配对，请先输入配对码\",\"code\":\"PAIRING_REQUIRED\"}".utf8))
                return
            }
            guard let body = Self.readRequestBody(fd: fd, leftover: leftover, contentLength: Int(contentLen ?? 0), isChunked: isChunked, maxBytes: 4 * 1024 * 1024),
                  let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let infoDict = root["info"] as? [String: Any],
                  let infoBytes = try? JSONSerialization.data(withJSONObject: infoDict),
                  let senderInfo = try? JSONDecoder().decode(LocalSendDeviceInfo.self, from: infoBytes),
                  senderInfo.isWallPullDevice,
                  let filesDict = root["files"] as? [String: [String: Any]] else {
                Self.sendHTTP(fd: fd, status: 400, reason: "Bad Request", contentType: "application/json", body: Data("{\"message\":\"Invalid body\"}".utf8))
                return
            }
            if filesDict.isEmpty {
                Self.sendHTTP(fd: fd, status: 204, reason: "No Content", contentType: "text/plain", body: Data())
                return
            }
            for (_, fobj) in filesDict {
                if let declaredSize = (fobj["size"] as? NSNumber)?.int64Value,
                   declaredSize > Self.maxLanUploadBytes {
                    Self.sendHTTP(fd: fd, status: 413, reason: "Payload Too Large", contentType: "application/json", body: Data("{\"message\":\"File exceeds 4 GB limit\"}".utf8))
                    return
                }
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
            guard runtime.isAuthorizedRequest(headers: headers, query: query) else {
                Self.sendHTTP(fd: fd, status: 401, reason: "Unauthorized", contentType: "application/json", body: Data("{\"message\":\"设备尚未配对，请先输入配对码\",\"code\":\"PAIRING_REQUIRED\"}".utf8))
                return
            }
            if let contentLen, contentLen > Self.maxLanUploadBytes {
                Self.sendHTTP(fd: fd, status: 413, reason: "Payload Too Large", contentType: "application/json", body: Data("{\"message\":\"Payload exceeds 4 GB limit\"}".utf8))
                return
            }
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
            guard let actualSha = Self.streamSocketToFile(fd: fd, leftover: leftover, contentLength: contentLen, isChunked: isChunked, destURL: tempURL, maxBytes: Self.maxLanUploadBytes) else {
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

            let rawExt = URL(fileURLWithPath: item.fileName).pathExtension.lowercased()
            let cleanExt = String(rawExt.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(8))
            let safeExt = cleanExt.isEmpty ? "bin" : cleanExt
            let copyForImport = FileManager.default.temporaryDirectory.appendingPathComponent("ls_imp_\(UUID().uuidString).\(safeExt)")
            try? FileManager.default.removeItem(at: copyForImport)
            guard (try? FileManager.default.moveItem(at: tempURL, to: copyForImport)) != nil else {
                Self.sendHTTP(fd: fd, status: 500, reason: "Internal Error", contentType: "application/json", body: Data("{\"message\":\"Move failed\"}".utf8))
                return
            }
            runtime.completeSessionFile(id: sid, fileId: fid)
            final class AtomicBoolBox: @unchecked Sendable {
                private let lock = NSLock()
                private var flag = false
                func setTrue() {
                    lock.lock()
                    flag = true
                    lock.unlock()
                }
                var value: Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    return flag
                }
            }
            let sem = DispatchSemaphore(value: 0)
            let importBox = AtomicBoolBox()
            Task { @MainActor [weak self] in
                defer {
                    try? FileManager.default.removeItem(at: copyForImport)
                    sem.signal()
                }
                self?.touchPeerAliveByIP(remoteIP)
                guard let self, let vault = self.vault else { return }
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
                if let imported {
                    importBox.setTrue()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    vault.showToast("已无损接收来自「\(sess.senderAlias)」：\(imported.title)")
                }
            }
            sem.wait()
            if importBox.value {
                Self.sendHTTP(fd: fd, status: 200, reason: "OK", contentType: "text/plain", body: Data())
            } else {
                Self.sendHTTP(fd: fd, status: 500, reason: "Internal Error", contentType: "application/json", body: Data("{\"message\":\"Import failed\"}".utf8))
            }

        case ("POST", "/api/localsend/v2/cancel"):
            guard runtime.isAuthorizedRequest(headers: headers, query: query) else {
                Self.sendHTTP(fd: fd, status: 401, reason: "Unauthorized", contentType: "application/json", body: Data("{\"message\":\"设备尚未配对，请先输入配对码\",\"code\":\"PAIRING_REQUIRED\"}".utf8))
                return
            }
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
        maxBytes: Int64?,
        onChunk: (Data) -> Bool
    ) -> Bool {
        var buffer = leftover
        var total: Int64 = 0
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
            if let maxBytes, total + Int64(chunkSize) > maxBytes {
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
                total += Int64(take)
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
            let ok = consumeChunkedStream(fd: fd, leftover: leftover, maxBytes: Int64(maxBytes)) { chunk in
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

    nonisolated private static func streamSocketToFile(fd: Int32, leftover: Data, contentLength: Int64?, isChunked: Bool, destURL: URL, maxBytes: Int64) -> String? {
        FileManager.default.createFile(atPath: destURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destURL) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()

        if isChunked {
            let ok = consumeChunkedStream(fd: fd, leftover: leftover, maxBytes: maxBytes) { slice in
                do {
                    try handle.write(contentsOf: slice)
                } catch {
                    return false
                }
                hasher.update(data: slice)
                return true
            }
            guard ok else { return nil }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        var written: Int64 = 0
        if !leftover.isEmpty {
            let toWrite = contentLength.map { min(Int64(leftover.count), $0) } ?? Int64(leftover.count)
            guard toWrite <= maxBytes else { return nil }
            let slice = Data(leftover.prefix(Int(toWrite)))
            do {
                try handle.write(contentsOf: slice)
            } catch {
                return nil
            }
            hasher.update(data: slice)
            written += toWrite
        }

        var buf = [UInt8](repeating: 0, count: 65536)
        if let expectedLen = contentLength {
            guard expectedLen <= maxBytes else { return nil }
            while written < expectedLen {
                let need = min(buf.count, Int(expectedLen - written))
                let n = Darwin.recv(fd, &buf, need, 0)
                if n <= 0 { return nil }
                let d = Data(bytes: buf, count: n)
                do {
                    try handle.write(contentsOf: d)
                } catch {
                    return nil
                }
                hasher.update(data: d)
                written += Int64(n)
            }
        } else {
            while true {
                let n = Darwin.recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                written += Int64(n)
                guard written <= maxBytes else { return nil }
                let d = Data(bytes: buf, count: n)
                do {
                    try handle.write(contentsOf: d)
                } catch {
                    return nil
                }
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
