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
    @Published var exeMissingAlerts: [UUID: ExeMissingAlert] = [:]
    @Published var latestExePopupAlert: ExeMissingAlert?

    private let pcsKey = "kad_saved_pcs_v1"
    private let activeIdKey = "kad_active_pc_id_v1"
    private let alertsKey = "kad_exe_missing_alerts_v1"
    private var consecutiveAliveWithoutKad: [UUID: Int] = [:]

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
                guard let self else { return }
                self.backgroundManager?.notifyIfInBackground(
                    title: "KAD Remote",
                    body: "\(name) đã ngắt kết nối khỏi Hub LAN."
                )
                await self.verifyDisconnectedAgentExeHealth(machineId: machineId, deviceName: name)
            }
        }

        hub.onAgentExeAlert = { [weak self] machineId, deviceName, exeMissing, message in
            Task { @MainActor [weak self] in
                self?.handleAgentExeAlert(machineId: machineId, deviceName: deviceName, exeMissing: exeMissing, message: message)
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
        if let alertData = UserDefaults.standard.data(forKey: alertsKey),
           let decodedAlerts = try? JSONDecoder().decode([UUID: ExeMissingAlert].self, from: alertData) {
            exeMissingAlerts = decodedAlerts
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
        if let encodedAlerts = try? JSONEncoder().encode(exeMissingAlerts) {
            UserDefaults.standard.set(encodedAlerts, forKey: alertsKey)
        }
        if let activeId = activePC?.id.uuidString {
            UserDefaults.standard.set(activeId, forKey: activeIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeIdKey)
        }
    }

    func dismissExeAlert(for pcId: UUID) {
        exeMissingAlerts.removeValue(forKey: pcId)
        if latestExePopupAlert?.id == pcId {
            latestExePopupAlert = nil
        }
        save()
    }

    func clearAllExeAlerts() {
        exeMissingAlerts.removeAll()
        latestExePopupAlert = nil
        save()
    }

    func handleAgentExeAlert(machineId: String, deviceName: String, exeMissing: Bool, message: String?) {
        if let pc = savedPCs.first(where: { $0.machineId == machineId || $0.name.caseInsensitiveCompare(deviceName) == .orderedSame }) {
            recordExeStatus(
                for: pc.id,
                machineId: machineId,
                serverName: pc.name,
                exeMissing: exeMissing,
                message: message
            )
        } else if exeMissing {
            let fallbackId = UUID()
            let msg = message ?? "CẢNH BÁO: File Kad.exe trên máy \(deviceName) đã bị mất hoặc bị Windows xóa!"
            let alert = ExeMissingAlert(
                id: fallbackId,
                machineId: machineId,
                serverName: deviceName,
                message: msg,
                detectedAt: Date()
            )
            exeMissingAlerts[fallbackId] = alert
            latestExePopupAlert = alert
            backgroundManager?.notifyExeMissingAlert(serverKey: machineId, serverName: deviceName, message: msg)
            save()
        }
    }

    func recordExeStatus(
        for pcId: UUID,
        machineId: String?,
        serverName: String,
        exeMissing: Bool,
        message: String?
    ) {
        let serverKey = (machineId?.isEmpty == false) ? machineId! : pcId.uuidString
        if exeMissing {
            let msg = (message?.isEmpty == false)
                ? message!
                : "CẢNH BÁO: File Kad.exe trên máy \(serverName) đã bị mất hoặc bị Windows xóa!"
            let wasAlreadyAlerted = exeMissingAlerts[pcId] != nil

            if let idx = savedPCs.firstIndex(where: { $0.id == pcId }) {
                savedPCs[idx].exeMissing = true
                savedPCs[idx].exeStatusMessage = msg
                if activePC?.id == pcId {
                    activePC = savedPCs[idx]
                }
            }

            let alert = ExeMissingAlert(
                id: pcId,
                machineId: machineId,
                serverName: serverName,
                message: msg,
                detectedAt: exeMissingAlerts[pcId]?.detectedAt ?? Date()
            )
            exeMissingAlerts[pcId] = alert
            if !wasAlreadyAlerted {
                latestExePopupAlert = alert
            }
            backgroundManager?.notifyExeMissingAlert(serverKey: serverKey, serverName: serverName, message: msg)
            save()
        } else {
            consecutiveAliveWithoutKad[pcId] = 0
            var changed = false
            if let idx = savedPCs.firstIndex(where: { $0.id == pcId }) {
                if savedPCs[idx].exeMissing == true || savedPCs[idx].exeStatusMessage != nil {
                    savedPCs[idx].exeMissing = false
                    savedPCs[idx].exeStatusMessage = nil
                    if activePC?.id == pcId {
                        activePC = savedPCs[idx]
                    }
                    changed = true
                }
            }
            if exeMissingAlerts.removeValue(forKey: pcId) != nil {
                changed = true
            }
            if latestExePopupAlert?.id == pcId {
                latestExePopupAlert = nil
            }
            backgroundManager?.clearExeAlertCooldown(serverKey: serverKey)
            if changed {
                save()
            }
        }
    }

    private func verifyDisconnectedAgentExeHealth(machineId: String, deviceName: String) async {
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        if hub?.onlineAgents[machineId] != nil {
            return
        }
        guard let pc = savedPCs.first(where: { $0.machineId == machineId }) else { return }
        let client = APIClient(pc: pc)
        var lanCandidates = [pc.normalizedUrl]
        for extra in (pc.localUrls ?? []) {
            let norm = SavedPC.normalizeUrl(extra)
            if !lanCandidates.contains(norm) { lanCandidates.append(norm) }
        }
        for lan in lanCandidates {
            if let resp = try? await client.pingSpecificBase(lan, timeout: 1.2) {
                recordExeStatus(
                    for: pc.id,
                    machineId: pc.machineId,
                    serverName: pc.name,
                    exeMissing: resp.exeMissing ?? false,
                    message: resp.exeStatusMessage
                )
                return
            }
        }
        if await Self.isWindowsHostAliveWithoutKad(lanUrls: lanCandidates) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if hub?.onlineAgents[machineId] != nil { return }
            for lan in lanCandidates {
                if (try? await client.pingSpecificBase(lan, timeout: 1.2)) != nil {
                    return
                }
            }
            recordExeStatus(
                for: pc.id,
                machineId: pc.machineId,
                serverName: pc.name,
                exeMissing: true,
                message: "CẢNH BÁO: Máy chủ \(deviceName) vẫn đang bật trên mạng nhưng tiến trình Kad.exe đã biến mất (file Kad.exe có thể đã bị mất hoặc bị Windows xóa)!"
            )
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
        if let pc = savedPCs.first(where: { $0.machineId == status.machineId }) {
            recordExeStatus(
                for: pc.id,
                machineId: status.machineId,
                serverName: status.deviceName,
                exeMissing: status.exeMissing,
                message: status.exeStatusMessage
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
        recordExeStatus(
            for: existing.id,
            machineId: status.machineId,
            serverName: existing.name,
            exeMissing: status.exeMissing,
            message: status.exeStatusMessage
        )
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
        recordExeStatus(
            for: pcId,
            machineId: info.machineId ?? pc.machineId,
            serverName: pc.name,
            exeMissing: info.exeMissing ?? false,
            message: info.exeStatusMessage
        )
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
        async let cloudTask = Self.fetchCloudAnnouncements(token: token, requestLiveReply: true)

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
            if let pc = savedPCs.first(where: { $0.machineId == peer.machineId }) {
                recordExeStatus(
                    for: pc.id,
                    machineId: peer.machineId,
                    serverName: peer.deviceName,
                    exeMissing: peer.exeMissing,
                    message: peer.exeStatusMessage
                )
            }
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
            if let pc = savedPCs.first(where: { $0.machineId == ann.machineId }) {
                if let t = ann.tunnelUrl, !t.isEmpty, ann.exeMissing != true {
                    remoteOnlineIds.insert(pc.id)
                    tunnelActiveIds.insert(pc.id)
                }
                recordExeStatus(
                    for: pc.id,
                    machineId: ann.machineId,
                    serverName: ann.deviceName,
                    exeMissing: ann.exeMissing ?? false,
                    message: ann.exeStatusMessage
                )
            }
        }

        if includeSubnetScan {
            let lanFound = await scanLocalSubnet(token: token, agentPort: agentPort)
            for item in lanFound {
                let best = Self.selectBestLocalUrl(from: item.info.localUrls, remoteIP: item.ip, agentPort: agentPort)
                let mid = item.info.machineId ?? item.ip
                let isNew = upsertDiscoveredServer(
                    machineId: mid,
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
                if let pc = savedPCs.first(where: { $0.machineId == mid }) {
                    recordExeStatus(
                        for: pc.id,
                        machineId: mid,
                        serverName: item.info.deviceName,
                        exeMissing: item.info.exeMissing ?? false,
                        message: item.info.exeStatusMessage
                    )
                }
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

    /// Lightweight continuous background check while ConnectView is visible so newly started PCs pop up automatically on 4G/LAN.
    func pollCloudAndUdpQuickly() async {
        guard let hub, !isDiscovering else { return }
        let token = hub.controllerToken
        let peerPort = min(max(hub.hubPort + 1, 1025), 65535)

        async let udpTask = Self.probeUdpAgents(token: token, peerPort: peerPort)
        async let cloudTask = Self.fetchCloudAnnouncements(token: token, requestLiveReply: false)
        let (udpPeers, cloudPeers) = await (udpTask, cloudTask)

        for peer in udpPeers {
            let best = Self.selectBestLocalUrl(from: peer.localUrls, remoteIP: peer.remoteIP, agentPort: peer.agentPort)
            upsertDiscoveredServer(
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
            if let pc = savedPCs.first(where: { $0.machineId == peer.machineId }) {
                remoteOnlineIds.insert(pc.id)
                recordExeStatus(
                    for: pc.id,
                    machineId: peer.machineId,
                    serverName: peer.deviceName,
                    exeMissing: peer.exeMissing,
                    message: peer.exeStatusMessage
                )
            }
        }

        for ann in cloudPeers {
            let best = Self.selectBestLocalUrl(from: ann.localUrls, remoteIP: nil, agentPort: ann.agentPort)
            let fallbackUrl = best.isEmpty ? (ann.tunnelUrl ?? "http://127.0.0.1:\(ann.agentPort)") : best
            upsertDiscoveredServer(
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
            if let pc = savedPCs.first(where: { $0.machineId == ann.machineId }) {
                if let t = ann.tunnelUrl, !t.isEmpty, ann.exeMissing != true {
                    remoteOnlineIds.insert(pc.id)
                    if hub.onlineAgents[ann.machineId] == nil {
                        tunnelActiveIds.insert(pc.id)
                    }
                }
                recordExeStatus(
                    for: pc.id,
                    machineId: ann.machineId,
                    serverName: ann.deviceName,
                    exeMissing: ann.exeMissing ?? false,
                    message: ann.exeStatusMessage
                )
            }
        }
    }

    func refreshRemoteStatuses() async {
        guard !savedPCs.isEmpty else { return }
        isRefreshingStatuses = true
        defer { isRefreshingStatuses = false }

        var onlineRemote: Set<UUID> = []
        var reachableGateways: [(SavedPC, Bool)] = []
        var bestWorkingUrls: [UUID: String] = [:]

        await withTaskGroup(of: (UUID, Bool, Bool, String?, PingResponse?, Bool).self) { group in
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
                        if let resp = try? await client.pingSpecificBase(lan, timeout: 1.1) {
                            return (pc.id, true, false, lan, resp, false)
                        }
                    }

                    if let tunnel = pc.normalizedTunnelUrl,
                       let resp = try? await client.pingSpecificBase(tunnel, timeout: 3.0) {
                        return (pc.id, true, true, nil, resp, false)
                    }

                    let hostAliveNoKad = await Self.isWindowsHostAliveWithoutKad(lanUrls: lanCandidates)
                    return (pc.id, false, false, nil, nil, hostAliveNoKad)
                }
            }

            for await (id, ok, viaTunnel, workingLan, pingResp, hostAliveNoKad) in group {
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
                        recordExeStatus(
                            for: pc.id,
                            machineId: pc.machineId,
                            serverName: pc.name,
                            exeMissing: pingResp?.exeMissing ?? false,
                            message: pingResp?.exeStatusMessage
                        )
                    }
                } else if hostAliveNoKad, let pc = savedPCs.first(where: { $0.id == id }) {
                    let count = (consecutiveAliveWithoutKad[id] ?? 0) + 1
                    consecutiveAliveWithoutKad[id] = count
                    if count >= 2 {
                        recordExeStatus(
                            for: pc.id,
                            machineId: pc.machineId,
                            serverName: pc.name,
                            exeMissing: true,
                            message: "CẢNH BÁO: Máy chủ \(pc.name) vẫn đang bật trên mạng nhưng không tìm thấy Kad.exe (file Kad.exe có thể đã bị mất hoặc bị Windows xóa)!"
                        )
                    }
                } else if let pc = savedPCs.first(where: { $0.id == id }),
                          pc.normalizedTunnelUrl != nil,
                          pc.exeMissing != true,
                          let lastConn = pc.lastConnected,
                          Date().timeIntervalSince(lastConn) < 90 {
                    // Keep freshly announced Cloud Tunnel PC marked ready while Cloudflare edge DNS warms up
                    onlineRemote.insert(id)
                    tunnelActiveIds.insert(id)
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
                if pc.normalizedTunnelUrl != nil && peer.exeMissing != true {
                    remoteOnlineIds.insert(pc.id)
                    if preferTunnel {
                        tunnelActiveIds.insert(pc.id)
                    }
                }
                recordExeStatus(
                    for: pc.id,
                    machineId: peer.machineId,
                    serverName: pc.name,
                    exeMissing: peer.exeMissing ?? false,
                    message: peer.exeStatusMessage
                )
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
                    localUrls: peer.localUrls,
                    exeMissing: peer.exeMissing,
                    exeStatusMessage: peer.exeStatusMessage
                )
                savedPCs.append(newPC)
                if peer.exeMissing != true {
                    remoteOnlineIds.insert(newPC.id)
                    if preferTunnel {
                        tunnelActiveIds.insert(newPC.id)
                    }
                }
                recordExeStatus(
                    for: newPC.id,
                    machineId: peer.machineId,
                    serverName: peer.deviceName,
                    exeMissing: peer.exeMissing ?? false,
                    message: peer.exeStatusMessage
                )
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

        // 3. Try saved Cloudflare Tunnel URL (when away from home / 4G), with brief retry for fresh tunnel DNS warm-up
        if !resolvedRoute, let tunnel = pc.normalizedTunnelUrl {
            for attempt in 0..<3 {
                if (try? await probe.pingSpecificBase(tunnel, timeout: 4.0)) != nil {
                    tunnelActiveIds.insert(pc.id)
                    if let mid = pc.machineId { relayMachineIds.remove(mid) }
                    resolvedRoute = true
                    break
                }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                }
            }
        }

        // 4. Refresh rotated Tunnel URL from Encrypted Cloud Rendezvous or LAN peers
        if !resolvedRoute && !pc.token.isEmpty {
            let anns = await Self.fetchCloudAnnouncements(token: pc.token, requestLiveReply: true)
            if let match = anns.first(where: { $0.machineId == pc.machineId }),
               let newTunnel = match.tunnelUrl, !newTunnel.isEmpty {
                pc.tunnelUrl = newTunnel
                if !match.localUrls.isEmpty { pc.localUrls = match.localUrls }
                upsertPC(pc)
                activePC = pc
                if (try? await APIClient(pc: pc).pingSpecificBase(newTunnel, timeout: 4.0)) != nil {
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
        let exeMissing: Bool
        let exeStatusMessage: String?
    }

    private nonisolated static func probeUdpAgents(token: String, peerPort: Int) async -> [UdpPeerReply] {
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
                    remoteIP: remoteIP,
                    exeMissing: obj["exeMissing"] as? Bool ?? false,
                    exeStatusMessage: obj["exeStatusMessage"] as? String
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
        let exeMissing: Bool?
        let exeStatusMessage: String?
    }

    /// Checks whether a Windows server at any of `lanUrls` is powered ON and responding on the LAN
    /// (either via TCP ECONNREFUSED on agentPort or TCP response on standard Windows ports 135/445/3389)
    /// while Kad.exe itself is no longer listening.
    private nonisolated static func isWindowsHostAliveWithoutKad(lanUrls: [String]) async -> Bool {
        await Task.detached(priority: .utility) {
            for raw in lanUrls {
                guard let url = URL(string: raw),
                      let host = url.host,
                      !host.isEmpty,
                      host != "127.0.0.1",
                      !host.lowercased().hasSuffix(".trycloudflare.com") else {
                    continue
                }
                let agentPort = UInt16(url.port ?? 7788)

                // 1. If TCP connect to agentPort actively returns ECONNREFUSED (RST), the Windows TCP stack is alive, but Kad.exe is not running!
                let agentRes = probeTcpPort(ip: host, port: agentPort, timeoutMs: 650)
                if agentRes == .refused {
                    return true
                }

                // 2. If Windows Firewall silently drops packets on agentPort when Kad.exe is gone, probe Windows RPC (135) or SMB (445)
                if agentRes == .timedOut {
                    for winPort: UInt16 in [135, 445, 3389] {
                        let winRes = probeTcpPort(ip: host, port: winPort, timeoutMs: 550)
                        if winRes == .connected || winRes == .refused {
                            return true
                        }
                    }
                }
            }
            return false
        }.value
    }

    private enum TcpProbeResult {
        case connected
        case refused
        case timedOut
        case unreachable
    }

    private nonisolated static func probeTcpPort(ip: String, port: UInt16, timeoutMs: Int32) -> TcpProbeResult {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else {
            return .unreachable
        }

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return .unreachable }
        defer { Darwin.close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if rc == 0 {
            return .connected
        }
        if errno == ECONNREFUSED {
            return .refused
        }
        if errno != EINPROGRESS {
            return .unreachable
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pr = Darwin.poll(&pfd, 1, timeoutMs)
        if pr <= 0 {
            return .timedOut
        }

        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) == 0 {
            if soError == 0 {
                return .connected
            }
            if soError == ECONNREFUSED {
                return .refused
            }
        }
        return .unreachable
    }

    private nonisolated static func fetchCloudAnnouncements(token: String, requestLiveReply: Bool = false) async -> [CloudAnnouncementPayload] {
        guard !token.isEmpty else { return [] }
        let topicHash = AgentHubServer.sha256Hex("kad-rendezvous-topic-v1:" + token)
        let topic = "kad_" + String(topicHash.prefix(24))
        let keyDigest = SHA256.hash(data: Data(("kad-rendezvous-key-v1:" + token).utf8))
        let symKey = SymmetricKey(data: keyDigest)

        if requestLiveReply, let postUrl = URL(string: "https://ntfy.sh/\(topic)") {
            var postReq = URLRequest(url: postUrl)
            postReq.httpMethod = "POST"
            postReq.timeoutInterval = 4
            postReq.setValue("no", forHTTPHeaderField: "Cache")
            postReq.httpBody = Data("KADREQ1:discover".utf8)
            _ = try? await URLSession.shared.data(for: postReq)
            try? await Task.sleep(nanoseconds: 700_000_000)
        }

        guard let url = URL(string: "https://ntfy.sh/\(topic)/json?poll=1&since=all") else {
            return []
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue("KADRemote-iOS/1.3", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let bodyStr = String(data: data, encoding: .utf8) else {
            return []
        }

        var latestByMachine: [String: CloudAnnouncementPayload] = [:]
        for line in bodyStr.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (obj["event"] as? String) == "message",
                  let msg = obj["message"] as? String,
                  msg.hasPrefix("KADENC1:") else {
                continue
            }

            let b64 = String(msg.dropFirst("KADENC1:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
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
