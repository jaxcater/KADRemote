import Foundation
import SwiftUI
import CryptoKit
import Darwin

@MainActor
final class ConnectionStore: ObservableObject {
    @Published var savedPCs: [SavedPC] = []
    @Published var activePC: SavedPC?
    @Published var isConnected: Bool = false
    @Published var isConnecting: Bool = false
    @Published var errorMessage: String?
    @Published var relayMachineIds: Set<String> = []
    @Published var tunnelActiveIds: Set<UUID> = []
    @Published var remoteOnlineIds: Set<UUID> = []
    @Published var isRefreshingStatuses: Bool = false
    @Published var isDiscovering: Bool = false
    @Published var discoveryStatus: String?

    private let pcsKey = "kad_saved_pcs_v1"
    private let activeIdKey = "kad_active_pc_id_v1"

    weak var hub: AgentHubServer?
    weak var backgroundManager: BackgroundManager?

    var client: APIClient? {
        guard let pc = activePC else { return nil }
        let useRelay = pc.machineId.map { relayMachineIds.contains($0) } ?? false
        let useTunnel = tunnelActiveIds.contains(pc.id)
        return APIClient(pc: pc, hub: hub, preferRelay: useRelay, preferTunnel: useTunnel)
    }

    init() {
        load()
    }

    func attach(hub: AgentHubServer, backgroundManager: BackgroundManager) {
        self.hub = hub
        self.backgroundManager = backgroundManager

        hub.onAgentRegistered = { [weak self] status, token in
            Task { @MainActor [weak self] in
                self?.handleAgentRegistered(status, token: token)
            }
        }

        hub.onAgentHeartbeat = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.handleAgentHeartbeat(status)
            }
        }

        hub.onAgentDisconnected = { [weak self] machineId, name in
            Task { @MainActor [weak self] in
                self?.backgroundManager?.notifyIfInBackground(
                    title: "KAD Remote",
                    body: "\(name) đã ngắt kết nối khỏi Hub LAN."
                )
                let _ = machineId
            }
        }

        if activePC != nil && !isConnected && !isConnecting {
            Task {
                await reconnectActive()
            }
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: pcsKey),
           let decoded = try? JSONDecoder().decode([SavedPC].self, from: data) {
            savedPCs = decoded
        }
        if let idStr = UserDefaults.standard.string(forKey: activeIdKey),
           let uuid = UUID(uuidString: idStr),
           let found = savedPCs.first(where: { $0.id == uuid }) {
            activePC = found
        }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(savedPCs) {
            UserDefaults.standard.set(encoded, forKey: pcsKey)
        }
        if let activeId = activePC?.id.uuidString {
            UserDefaults.standard.set(activeId, forKey: activeIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeIdKey)
        }
    }

    func handleAgentRegistered(_ status: AgentLiveStatus, token: String) {
        let bestUrl = Self.selectBestLocalUrl(
            from: status.localUrls,
            remoteIP: status.remoteIP,
            agentPort: status.agentPort
        )
        let isNew = upsertDiscoveredServer(
            machineId: status.machineId,
            deviceName: status.deviceName,
            bestUrl: bestUrl,
            localUrls: status.localUrls,
            tunnelUrl: status.tunnelUrl,
            token: token,
            cpu: status.cpuUsagePercent,
            usedRam: status.usedMemoryBytes,
            totalRam: status.totalMemoryBytes
        )
        if isNew {
            backgroundManager?.notifyIfInBackground(
                title: "Server mới đã kết nối",
                body: "\(status.deviceName) (\(bestUrl)) đã tự động ghép nối."
            )
        }
    }

    func handleAgentHeartbeat(_ status: AgentLiveStatus) {
        guard let idx = savedPCs.firstIndex(where: { $0.machineId == status.machineId }) else { return }
        var existing = savedPCs[idx]
        var changed = false

        if let t = status.tunnelUrl, !t.isEmpty, existing.tunnelUrl != t {
            existing.tunnelUrl = t
            changed = true
        }
        if !status.localUrls.isEmpty, existing.localUrls != status.localUrls {
            existing.localUrls = status.localUrls
            changed = true
        }
        existing.lastSeenCpu = status.cpuUsagePercent
        existing.lastSeenUsedRam = status.usedMemoryBytes
        existing.lastSeenTotalRam = status.totalMemoryBytes
        savedPCs[idx] = existing

        if activePC?.id == existing.id {
            activePC = existing
        }
        if changed {
            save()
        }
    }

    func updatePCMetadata(from info: SystemInfo, for pcId: UUID) {
        guard let idx = savedPCs.firstIndex(where: { $0.id == pcId }) else { return }
        var pc = savedPCs[idx]
        var changed = false
        if let mid = info.machineId, !mid.isEmpty, pc.machineId != mid {
            pc.machineId = mid
            changed = true
        }
        if let t = info.tunnelUrl, !t.isEmpty, pc.tunnelUrl != t {
            pc.tunnelUrl = t
            changed = true
        }
        if !info.localUrls.isEmpty, pc.localUrls != info.localUrls {
            pc.localUrls = info.localUrls
            changed = true
        }
        if changed {
            savedPCs[idx] = pc
            if activePC?.id == pc.id {
                activePC = pc
            }
            save()
        }
    }

    func isAgentOnline(_ pc: SavedPC) -> Bool {
        if let mid = pc.machineId, hub?.onlineAgents[mid] != nil {
            return true
        }
        return remoteOnlineIds.contains(pc.id)
    }

    func isUsingTunnel(_ pc: SavedPC) -> Bool {
        if let mid = pc.machineId, hub?.onlineAgents[mid] != nil {
            return false
        }
        return tunnelActiveIds.contains(pc.id)
    }

    func liveStatus(for pc: SavedPC) -> AgentLiveStatus? {
        guard let mid = pc.machineId else { return nil }
        return hub?.onlineAgents[mid]
    }

    // MARK: - Active Multi-Layer Discovery (UDP Probe + Encrypted Cloud Sync + LAN Scan)

    func discoverAgents(includeSubnetScan: Bool = true) async {
        guard let hub, !isDiscovering else { return }
        isDiscovering = true
        discoveryStatus = "Đang tìm Server trong LAN & Cloud..."
        defer {
            isDiscovering = false
        }

        let token = hub.controllerToken
        let agentPort = hub.defaultAgentPort
        let peerPort = min(max(hub.hubPort + 1, 1025), 65535)

        async let udpTask = Self.probeUdpAgents(token: token, peerPort: peerPort)
        async let cloudTask = Self.fetchCloudAnnouncements(token: token)

        let (udpPeers, cloudPeers) = await (udpTask, cloudTask)

        var discoveredCount = 0

        for peer in udpPeers {
            let best = Self.selectBestLocalUrl(from: peer.localUrls, remoteIP: peer.remoteIP, agentPort: peer.agentPort)
            let isNew = upsertDiscoveredServer(
                machineId: peer.machineId,
                deviceName: peer.deviceName,
                bestUrl: best,
                localUrls: peer.localUrls,
                tunnelUrl: peer.tunnelUrl,
                token: token,
                cpu: peer.cpuUsagePercent,
                usedRam: peer.usedMemoryBytes,
                totalRam: peer.totalMemoryBytes
            )
            if isNew { discoveredCount += 1 }
        }

        for ann in cloudPeers {
            let best = Self.selectBestLocalUrl(from: ann.localUrls, remoteIP: nil, agentPort: ann.agentPort)
            let fallbackUrl = best.isEmpty ? (ann.tunnelUrl ?? "http://127.0.0.1:\(ann.agentPort)") : best
            let isNew = upsertDiscoveredServer(
                machineId: ann.machineId,
                deviceName: ann.deviceName,
                bestUrl: fallbackUrl,
                localUrls: ann.localUrls,
                tunnelUrl: ann.tunnelUrl,
                token: token,
                cpu: ann.cpuUsagePercent,
                usedRam: ann.usedMemoryBytes,
                totalRam: ann.totalMemoryBytes
            )
            if isNew { discoveredCount += 1 }
        }

        if includeSubnetScan {
            let lanFound = await scanLocalSubnet(token: token, agentPort: agentPort)
            for item in lanFound {
                let best = Self.selectBestLocalUrl(from: item.info.localUrls, remoteIP: item.ip, agentPort: agentPort)
                let isNew = upsertDiscoveredServer(
                    machineId: item.info.machineId ?? item.ip,
                    deviceName: item.info.deviceName,
                    bestUrl: best,
                    localUrls: item.info.localUrls,
                    tunnelUrl: item.info.tunnelUrl,
                    token: token,
                    cpu: item.info.cpuUsagePercent,
                    usedRam: item.info.usedMemoryBytes,
                    totalRam: item.info.totalMemoryBytes
                )
                if isNew { discoveredCount += 1 }
            }
        }

        await refreshRemoteStatuses()

        if discoveredCount > 0 {
            discoveryStatus = "Đã tìm thấy \(discoveredCount) Server mới"
        } else if !savedPCs.isEmpty {
            discoveryStatus = nil
        } else {
            discoveryStatus = "Chưa thấy Server nào. Hãy chạy Kad.exe trên Windows."
        }
    }

    func refreshRemoteStatuses() async {
        guard !savedPCs.isEmpty else { return }
        isRefreshingStatuses = true
        defer { isRefreshingStatuses = false }

        var onlineRemote: Set<UUID> = []
        var reachableGateways: [(SavedPC, Bool)] = []
        var bestWorkingUrls: [UUID: String] = [:]

        await withTaskGroup(of: (UUID, Bool, Bool, String?).self) { group in
            for pc in savedPCs {
                group.addTask {
                    let client = APIClient(pc: pc)
                    var lanCandidates: [String] = [pc.normalizedUrl]
                    for extra in (pc.localUrls ?? []) {
                        let norm = SavedPC.normalizeUrl(extra)
                        if !lanCandidates.contains(norm) {
                            lanCandidates.append(norm)
                        }
                    }

                    for lan in lanCandidates {
                        if (try? await client.pingSpecificBase(lan, timeout: 1.1)) != nil {
                            return (pc.id, true, false, lan)
                        }
                    }

                    if let tunnel = pc.normalizedTunnelUrl,
                       (try? await client.pingSpecificBase(tunnel, timeout: 3.0)) != nil {
                        return (pc.id, true, true, nil)
                    }
                    return (pc.id, false, false, nil)
                }
            }

            for await (id, ok, viaTunnel, workingLan) in group {
                if ok {
                    onlineRemote.insert(id)
                    if viaTunnel {
                        tunnelActiveIds.insert(id)
                    } else {
                        tunnelActiveIds.remove(id)
                    }
                    if let workingLan {
                        bestWorkingUrls[id] = workingLan
                    }
                    if let pc = savedPCs.first(where: { $0.id == id }) {
                        reachableGateways.append((pc, viaTunnel))
                    }
                }
            }
        }

        if !bestWorkingUrls.isEmpty {
            var changed = false
            for idx in savedPCs.indices {
                if let w = bestWorkingUrls[savedPCs[idx].id], savedPCs[idx].normalizedUrl != w {
                    savedPCs[idx].url = w
                    changed = true
                }
            }
            if changed { save() }
        }

        remoteOnlineIds = onlineRemote

        // Sync fresh Tunnel URLs & stats of any LAN peers from the first reachable PC
        if let (gateway, viaTunnel) = reachableGateways.first {
            await syncPeers(via: gateway, preferTunnel: viaTunnel)
        }
    }

    private func syncPeers(via gateway: SavedPC, preferTunnel: Bool) async {
        let client = APIClient(pc: gateway, hub: hub, preferTunnel: preferTunnel)
        guard let peers = try? await client.getPeers() else { return }

        var updatedAny = false
        for peer in peers {
            if let idx = savedPCs.firstIndex(where: { $0.machineId == peer.machineId }) {
                var pc = savedPCs[idx]
                if let t = peer.tunnelUrl, !t.isEmpty, pc.tunnelUrl != t {
                    pc.tunnelUrl = t
                    updatedAny = true
                }
                if !peer.localUrls.isEmpty && pc.localUrls != peer.localUrls {
                    pc.localUrls = peer.localUrls
                    updatedAny = true
                }
                pc.lastSeenCpu = peer.cpuUsagePercent
                pc.lastSeenUsedRam = peer.usedMemoryBytes
                pc.lastSeenTotalRam = peer.totalMemoryBytes
                savedPCs[idx] = pc
                if pc.normalizedTunnelUrl != nil {
                    remoteOnlineIds.insert(pc.id)
                    if preferTunnel {
                        tunnelActiveIds.insert(pc.id)
                    }
                }
            } else if let t = peer.tunnelUrl, !t.isEmpty {
                let best = Self.selectBestLocalUrl(from: peer.localUrls, remoteIP: nil, agentPort: peer.agentPort)
                let newPC = SavedPC(
                    name: peer.deviceName,
                    url: best.isEmpty ? t : best,
                    token: gateway.token,
                    lastConnected: Date(),
                    machineId: peer.machineId,
                    isAutoDiscovered: true,
                    lastSeenCpu: peer.cpuUsagePercent,
                    lastSeenUsedRam: peer.usedMemoryBytes,
                    lastSeenTotalRam: peer.totalMemoryBytes,
                    tunnelUrl: t,
                    localUrls: peer.localUrls
                )
                savedPCs.append(newPC)
                remoteOnlineIds.insert(newPC.id)
                if preferTunnel {
                    tunnelActiveIds.insert(newPC.id)
                }
                updatedAny = true
            }
        }
        if updatedAny {
            save()
        }
    }

    func reconnectActive() async {
        guard var pc = activePC else { return }
        isConnecting = true
        errorMessage = nil

        let probe = APIClient(pc: pc, hub: hub)
        var resolvedRoute = false

        // 1. Try all known LAN URLs first (fastest)
        var lanCandidates = [pc.normalizedUrl]
        for extra in (pc.localUrls ?? []) {
            let norm = SavedPC.normalizeUrl(extra)
            if !lanCandidates.contains(norm) { lanCandidates.append(norm) }
        }

        for lan in lanCandidates {
            if (try? await probe.pingSpecificBase(lan, timeout: 1.3)) != nil {
                if pc.normalizedUrl != lan {
                    pc.url = lan
                    upsertPC(pc)
                }
                tunnelActiveIds.remove(pc.id)
                if let mid = pc.machineId { relayMachineIds.remove(mid) }
                resolvedRoute = true
                break
            }
        }

        // 2. Try active LAN Hub Relay if firewalled
        if !resolvedRoute, let mid = pc.machineId, hub?.hasActiveSession(machineId: mid) == true {
            relayMachineIds.insert(mid)
            tunnelActiveIds.remove(pc.id)
            resolvedRoute = true
        }

        // 3. Try saved Cloudflare Tunnel URL (when away from home / 4G)
        if !resolvedRoute, let tunnel = pc.normalizedTunnelUrl,
           (try? await probe.pingSpecificBase(tunnel, timeout: 3.5)) != nil {
            tunnelActiveIds.insert(pc.id)
            if let mid = pc.machineId { relayMachineIds.remove(mid) }
            resolvedRoute = true
        }

        // 4. Refresh rotated Tunnel URL from Encrypted Cloud Rendezvous or LAN peers
        if !resolvedRoute && !pc.token.isEmpty {
            let anns = await Self.fetchCloudAnnouncements(token: pc.token)
            if let match = anns.first(where: { $0.machineId == pc.machineId }),
               let newTunnel = match.tunnelUrl, !newTunnel.isEmpty {
                pc.tunnelUrl = newTunnel
                if !match.localUrls.isEmpty { pc.localUrls = match.localUrls }
                upsertPC(pc)
                activePC = pc
                if (try? await APIClient(pc: pc).pingSpecificBase(newTunnel, timeout: 3.5)) != nil {
                    tunnelActiveIds.insert(pc.id)
                    resolvedRoute = true
                }
            }
        }

        if !resolvedRoute {
            for other in savedPCs where other.id != pc.id {
                if let otherTunnel = other.normalizedTunnelUrl,
                   (try? await APIClient(pc: other).pingSpecificBase(otherTunnel, timeout: 2.5)) != nil {
                    await syncPeers(via: other, preferTunnel: true)
                    if let refreshed = savedPCs.first(where: { $0.id == pc.id }) {
                        pc = refreshed
                        activePC = refreshed
                    }
                    if let newTunnel = pc.normalizedTunnelUrl,
                       (try? await APIClient(pc: pc).pingSpecificBase(newTunnel, timeout: 3.5)) != nil {
                        tunnelActiveIds.insert(pc.id)
                        resolvedRoute = true
                        break
                    }
                }
            }
        }

        if !resolvedRoute && pc.normalizedTunnelUrl != nil {
            tunnelActiveIds.insert(pc.id)
        }

        do {
            let useRelay = pc.machineId.map { relayMachineIds.contains($0) } ?? false
            let useTunnel = tunnelActiveIds.contains(pc.id)
            let resp = try await APIClient(pc: pc, hub: hub, preferRelay: useRelay, preferTunnel: useTunnel).ping()
            var updated = pc
            if !resp.deviceName.isEmpty {
                updated.name = resp.deviceName
            }
            updated.lastConnected = Date()
            upsertPC(updated)
            activePC = updated
            remoteOnlineIds.insert(updated.id)
            isConnected = true
        } catch {
            isConnected = false
            errorMessage = error.localizedDescription
        }
        isConnecting = false
    }

    func connectAndSave(name: String, url: String, token: String) async -> Bool {
        isConnecting = true
        errorMessage = nil

        let trimmedUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let isTunnel = trimmedUrl.lowercased().contains("trycloudflare.com") || trimmedUrl.lowercased().hasPrefix("https://")

        var candidate = SavedPC(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "My PC" : name,
            url: trimmedUrl,
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            lastConnected: Date(),
            tunnelUrl: isTunnel ? trimmedUrl : nil
        )

        do {
            let client = APIClient(pc: candidate, hub: hub, preferTunnel: isTunnel)
            let pingResp = try await client.ping()
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !pingResp.deviceName.isEmpty {
                candidate.name = pingResp.deviceName
            }
            if let sysInfo = try? await client.getSystemInfo() {
                if let mid = sysInfo.machineId, !mid.isEmpty {
                    candidate.machineId = mid
                }
                if let t = sysInfo.tunnelUrl, !t.isEmpty {
                    candidate.tunnelUrl = t
                }
                if !sysInfo.localUrls.isEmpty {
                    candidate.localUrls = sysInfo.localUrls
                    if isTunnel, let firstLan = sysInfo.localUrls.first {
                        candidate.url = firstLan
                    }
                }
            }
            upsertPC(candidate)
            if isTunnel {
                tunnelActiveIds.insert(candidate.id)
            }
            activePC = candidate
            isConnected = true
            isConnecting = false
            save()
            return true
        } catch {
            errorMessage = error.localizedDescription
            isConnecting = false
            return false
        }
    }

    func selectPC(_ pc: SavedPC) async {
        activePC = pc
        save()
        await reconnectActive()
    }

    func disconnect() {
        isConnected = false
        activePC = nil
        save()
    }

    func deletePC(_ pc: SavedPC) {
        savedPCs.removeAll { $0.id == pc.id }
        tunnelActiveIds.remove(pc.id)
        remoteOnlineIds.remove(pc.id)
        if activePC?.id == pc.id {
            activePC = nil
            isConnected = false
        }
        save()
    }

    @discardableResult
    private func upsertDiscoveredServer(
        machineId: String,
        deviceName: String,
        bestUrl: String,
        localUrls: [String],
        tunnelUrl: String?,
        token: String,
        cpu: Double,
        usedRam: Int64,
        totalRam: Int64
    ) -> Bool {
        let normBest = SavedPC.normalizeUrl(bestUrl)
        let normTunnel = tunnelUrl.flatMap { t -> String? in
            let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : SavedPC.normalizeUrl(s, defaultScheme: "https://")
        }

        if let idx = savedPCs.firstIndex(where: {
            (!machineId.isEmpty && $0.machineId == machineId)
            || $0.normalizedUrl == normBest
            || (normTunnel != nil && $0.normalizedTunnelUrl == normTunnel)
        }) {
            var existing = savedPCs[idx]
            existing.name = deviceName
            if !bestUrl.isEmpty { existing.url = bestUrl }
            if !localUrls.isEmpty { existing.localUrls = localUrls }
            if let t = tunnelUrl, !t.isEmpty { existing.tunnelUrl = t }
            existing.token = token
            if !machineId.isEmpty { existing.machineId = machineId }
            existing.isAutoDiscovered = true
            existing.lastConnected = Date()
            existing.lastSeenCpu = cpu
            existing.lastSeenUsedRam = usedRam
            existing.lastSeenTotalRam = totalRam
            savedPCs[idx] = existing
            if activePC?.id == existing.id {
                activePC = existing
            }
            save()
            return false
        } else {
            let newPC = SavedPC(
                name: deviceName,
                url: bestUrl,
                token: token,
                lastConnected: Date(),
                machineId: machineId,
                isAutoDiscovered: true,
                lastSeenCpu: cpu,
                lastSeenUsedRam: usedRam,
                lastSeenTotalRam: totalRam,
                tunnelUrl: tunnelUrl,
                localUrls: localUrls
            )
            savedPCs.insert(newPC, at: 0)
            save()
            return true
        }
    }

    private func upsertPC(_ pc: SavedPC) {
        if let idx = savedPCs.firstIndex(where: {
            ($0.machineId != nil && $0.machineId == pc.machineId)
            || $0.normalizedUrl == pc.normalizedUrl
            || ($0.normalizedTunnelUrl != nil && $0.normalizedTunnelUrl == pc.normalizedTunnelUrl)
        }) {
            var existing = pc
            existing.id = savedPCs[idx].id
            if existing.machineId == nil {
                existing.machineId = savedPCs[idx].machineId
            }
            if existing.tunnelUrl == nil {
                existing.tunnelUrl = savedPCs[idx].tunnelUrl
            }
            if existing.localUrls == nil {
                existing.localUrls = savedPCs[idx].localUrls
            }
            savedPCs[idx] = existing
            activePC = existing
        } else {
            savedPCs.insert(pc, at: 0)
        }
        save()
    }

    func parseDeepLink(_ url: URL) -> (url: String, token: String, name: String)? {
        guard url.scheme?.lowercased() == "kadremote" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        let targetUrl = items.first(where: { $0.name == "url" })?.value ?? ""
        let token = items.first(where: { $0.name == "token" })?.value ?? ""
        let name = items.first(where: { $0.name == "name" })?.value ?? "PC"
        guard !targetUrl.isEmpty, !token.isEmpty else { return nil }
        return (targetUrl, token, name)
    }

    func handleQRString(_ raw: String) -> (url: String, token: String, name: String)? {
        if let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           let parsed = parseDeepLink(url) {
            return parsed
        }
        return nil
    }

    // MARK: - Helpers (Best LAN URL, UDP Agent Probe, LAN Scan, Encrypted Cloud Rendezvous)

    private static func selectBestLocalUrl(from localUrls: [String], remoteIP: String?, agentPort: Int) -> String {
        if let remoteIP, !remoteIP.isEmpty, !remoteIP.contains(":"), remoteIP != "127.0.0.1" {
            return "http://\(remoteIP):\(agentPort)"
        }

        let phonePrefixes = NetworkUtils.getLocalIPAddresses().compactMap { iface -> String? in
            let parts = iface.ip.split(separator: ".")
            guard parts.count == 4 else { return nil }
            return "\(parts[0]).\(parts[1]).\(parts[2])."
        }

        for prefix in phonePrefixes {
            if let match = localUrls.first(where: { $0.contains("://\(prefix)") }) {
                return match
            }
        }

        return localUrls.first ?? (remoteIP.map { "http://\($0):\(agentPort)" } ?? "")
    }

    private struct UdpPeerReply {
        let machineId: String
        let deviceName: String
        let agentPort: Int
        let localUrls: [String]
        let tunnelUrl: String?
        let cpuUsagePercent: Double
        let totalMemoryBytes: Int64
        let usedMemoryBytes: Int64
        let remoteIP: String
    }

    private static func probeUdpAgents(token: String, peerPort: Int) async -> [UdpPeerReply] {
        await Task.detached(priority: .utility) {
            var results: [UdpPeerReply] = []
            let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return results }
            defer { Darwin.close(fd) }

            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

            var tv = timeval(tv_sec: 0, tv_usec: 300_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            let tokenHash = AgentHubServer.sha256Hex(token)
            let reqObj: [String: Any] = ["type": "discover_agent", "tokenHash": tokenHash]
            guard let reqData = try? JSONSerialization.data(withJSONObject: reqObj) else { return results }

            for bcastIP in NetworkUtils.getSubnetBroadcastAddresses() {
                var dest = sockaddr_in()
                dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                dest.sin_family = sa_family_t(AF_INET)
                dest.sin_port = UInt16(peerPort).bigEndian
                if inet_pton(AF_INET, bcastIP, &dest.sin_addr) == 1 {
                    reqData.withUnsafeBytes { rawBuf in
                        guard let base = rawBuf.baseAddress else { return }
                        _ = withUnsafePointer(to: &dest) { ptr in
                            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                sendto(fd, base, reqData.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                }
            }

            let deadline = Date().addingTimeInterval(1.4)
            var seenMachines = Set<String>()
            var buf = [UInt8](repeating: 0, count: 8192)

            while Date() < deadline {
                var senderAddr = sockaddr_in()
                var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &senderAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, &buf, buf.count, 0, sa, &senderLen)
                    }
                }
                if n <= 0 { continue }

                let data = Data(bytes: buf, count: n)
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = obj["type"] as? String, type == "peer_beacon",
                      let rxHash = obj["tokenHash"] as? String, rxHash.lowercased() == tokenHash,
                      let machineId = obj["machineId"] as? String, !machineId.isEmpty,
                      !seenMachines.contains(machineId) else {
                    continue
                }
                seenMachines.insert(machineId)

                var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var addrCopy = senderAddr.sin_addr
                let remoteIP = inet_ntop(AF_INET, &addrCopy, &ipBuf, socklen_t(INET_ADDRSTRLEN)) != nil
                    ? String(cString: ipBuf) : ""

                results.append(UdpPeerReply(
                    machineId: machineId,
                    deviceName: obj["deviceName"] as? String ?? "Windows Server",
                    agentPort: obj["agentPort"] as? Int ?? 7788,
                    localUrls: obj["localUrls"] as? [String] ?? [],
                    tunnelUrl: obj["tunnelUrl"] as? String,
                    cpuUsagePercent: obj["cpuUsagePercent"] as? Double ?? 0,
                    totalMemoryBytes: (obj["totalMemoryBytes"] as? NSNumber)?.int64Value ?? 0,
                    usedMemoryBytes: (obj["usedMemoryBytes"] as? NSNumber)?.int64Value ?? 0,
                    remoteIP: remoteIP
                ))
            }

            return results
        }.value
    }

    private struct CloudAnnouncementPayload: Decodable {
        let type: String?
        let machineId: String
        let deviceName: String
        let agentPort: Int
        let localUrls: [String]
        let tunnelUrl: String?
        let cpuUsagePercent: Double
        let totalMemoryBytes: Int64
        let usedMemoryBytes: Int64
        let uptimeSeconds: Int64?
    }

    private static func fetchCloudAnnouncements(token: String) async -> [CloudAnnouncementPayload] {
        guard !token.isEmpty else { return [] }
        let topicHash = AgentHubServer.sha256Hex("kad-rendezvous-topic-v1:" + token)
        let topic = "kad_" + String(topicHash.prefix(24))
        let keyDigest = SHA256.hash(data: Data(("kad-rendezvous-key-v1:" + token).utf8))
        let symKey = SymmetricKey(data: keyDigest)

        guard let url = URL(string: "https://ntfy.sh/\(topic)/json?poll=1&since=12h") else {
            return []
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("KADRemote-iOS/1.1", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let bodyStr = String(data: data, encoding: .utf8) else {
            return []
        }

        var latestByMachine: [String: CloudAnnouncementPayload] = [:]
        for line in bodyStr.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (obj["event"] as? String) == "message",
                  let msg = obj["message"] as? String,
                  msg.hasPrefix("KADENC1:") else {
                continue
            }

            let b64 = String(msg.dropFirst("KADENC1:".count))
            guard let combined = Data(base64Encoded: b64),
                  let sealedBox = try? AES.GCM.SealedBox(combined: combined),
                  let plaintext = try? AES.GCM.open(sealedBox, using: symKey),
                  let decoded = try? JSONDecoder().decode(CloudAnnouncementPayload.self, from: plaintext),
                  !decoded.machineId.isEmpty else {
                continue
            }

            latestByMachine[decoded.machineId] = decoded
        }

        return Array(latestByMachine.values)
    }

    private func scanLocalSubnet(token: String, agentPort: Int) async -> [(ip: String, info: SystemInfo)] {
        let localIfaces = NetworkUtils.getLocalIPAddresses().filter { iface in
            iface.name == "en0" || iface.ip.hasPrefix("192.168.") || iface.ip.hasPrefix("10.")
        }
        guard !localIfaces.isEmpty else { return [] }

        var targetIPs: [String] = []
        var seen = Set<String>()
        for iface in localIfaces.prefix(2) {
            let parts = iface.ip.split(separator: ".")
            guard parts.count == 4 else { continue }
            let prefix = "\(parts[0]).\(parts[1]).\(parts[2])."
            for host in 1...254 {
                let candidate = "\(prefix)\(host)"
                if candidate != iface.ip && !seen.contains(candidate) {
                    seen.insert(candidate)
                    targetIPs.append(candidate)
                }
            }
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 0.65
        cfg.timeoutIntervalForResource = 1.2
        let scanSession = URLSession(configuration: cfg)
        defer { scanSession.invalidateAndCancel() }

        var found: [(ip: String, info: SystemInfo)] = []
        let batchSize = 48
        var index = 0

        while index < targetIPs.count {
            let end = min(index + batchSize, targetIPs.count)
            let slice = targetIPs[index..<end]
            index = end

            await withTaskGroup(of: (String, SystemInfo)?.self) { group in
                for ip in slice {
                    group.addTask {
                        guard let pingUrl = URL(string: "http://\(ip):\(agentPort)/api/ping") else { return nil }
                        var pingReq = URLRequest(url: pingUrl)
                        pingReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                        guard let (_, pingResp) = try? await scanSession.data(for: pingReq),
                              let http = pingResp as? HTTPURLResponse,
                              http.statusCode == 200 else {
                            return nil
                        }

                        guard let sysUrl = URL(string: "http://\(ip):\(agentPort)/api/system/info") else { return nil }
                        var sysReq = URLRequest(url: sysUrl)
                        sysReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                        guard let (sysData, sysResp) = try? await scanSession.data(for: sysReq),
                              let sysHttp = sysResp as? HTTPURLResponse,
                              sysHttp.statusCode == 200,
                              let info = try? JSONDecoder().decode(SystemInfo.self, from: sysData) else {
                            return nil
                        }
                        return (ip, info)
                    }
                }

                for await res in group {
                    if let res {
                        found.append(res)
                    }
                }
            }
        }

        return found
    }
}
