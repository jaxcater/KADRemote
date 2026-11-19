import Foundation
import SwiftUI

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
            Task {
                await reconnectActive()
            }
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
        let bestUrl = status.localUrls.first
            ?? (status.remoteIP.isEmpty ? "http://127.0.0.1:\(status.agentPort)" : "http://\(status.remoteIP):\(status.agentPort)")

        if let idx = savedPCs.firstIndex(where: { $0.machineId == status.machineId || $0.normalizedUrl == bestUrl }) {
            var existing = savedPCs[idx]
            existing.name = status.deviceName
            existing.url = bestUrl
            existing.localUrls = status.localUrls
            if let t = status.tunnelUrl, !t.isEmpty {
                existing.tunnelUrl = t
            }
            existing.token = token
            existing.machineId = status.machineId
            existing.isAutoDiscovered = true
            existing.lastConnected = Date()
            existing.lastSeenCpu = status.cpuUsagePercent
            existing.lastSeenUsedRam = status.usedMemoryBytes
            existing.lastSeenTotalRam = status.totalMemoryBytes
            savedPCs[idx] = existing
            if activePC?.id == existing.id {
                activePC = existing
            }
        } else {
            let newPC = SavedPC(
                name: status.deviceName,
                url: bestUrl,
                token: token,
                lastConnected: Date(),
                machineId: status.machineId,
                isAutoDiscovered: true,
                lastSeenCpu: status.cpuUsagePercent,
                lastSeenUsedRam: status.usedMemoryBytes,
                lastSeenTotalRam: status.totalMemoryBytes,
                tunnelUrl: status.tunnelUrl,
                localUrls: status.localUrls
            )
            savedPCs.insert(newPC, at: 0)
            backgroundManager?.notifyIfInBackground(
                title: "Server mới đã kết nối",
                body: "\(status.deviceName) (\(bestUrl)) đã tự động ghép nối."
            )
        }
        save()
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
        return tunnelActiveIds.contains(pc.id) || (remoteOnlineIds.contains(pc.id) && pc.normalizedTunnelUrl != nil)
    }

    func liveStatus(for pc: SavedPC) -> AgentLiveStatus? {
        guard let mid = pc.machineId else { return nil }
        return hub?.onlineAgents[mid]
    }

    func refreshRemoteStatuses() async {
        guard !savedPCs.isEmpty else { return }
        isRefreshingStatuses = true
        defer { isRefreshingStatuses = false }

        var onlineRemote: Set<UUID> = []
        var tunnelReachable: [SavedPC] = []

        await withTaskGroup(of: (UUID, Bool, Bool).self) { group in
            for pc in savedPCs {
                group.addTask {
                    let client = APIClient(pc: pc)
                    if (try? await client.pingSpecificBase(pc.normalizedUrl, timeout: 1.2)) != nil {
                        return (pc.id, true, false)
                    }
                    if let tunnel = pc.normalizedTunnelUrl,
                       (try? await client.pingSpecificBase(tunnel, timeout: 3.0)) != nil {
                        return (pc.id, true, true)
                    }
                    return (pc.id, false, false)
                }
            }

            for await (id, ok, viaTunnel) in group {
                if ok {
                    onlineRemote.insert(id)
                    if viaTunnel {
                        tunnelActiveIds.insert(id)
                    } else {
                        tunnelActiveIds.remove(id)
                    }
                    if let pc = savedPCs.first(where: { $0.id == id }), viaTunnel {
                        tunnelReachable.append(pc)
                    }
                }
            }
        }

        remoteOnlineIds = onlineRemote

        // Sync fresh Tunnel URLs of any rebooted LAN peers from the first reachable Tunnel PC
        if let gateway = tunnelReachable.first {
            await syncPeers(via: gateway)
        }
    }

    private func syncPeers(via gateway: SavedPC) async {
        let client = APIClient(pc: gateway, preferTunnel: true)
        guard let peers = try? await client.getPeers() else { return }

        var updatedAny = false
        for peer in peers {
            if let idx = savedPCs.firstIndex(where: { $0.machineId == peer.machineId }) {
                var pc = savedPCs[idx]
                if let t = peer.tunnelUrl, !t.isEmpty, pc.tunnelUrl != t {
                    pc.tunnelUrl = t
                    updatedAny = true
                }
                if !peer.localUrls.isEmpty {
                    pc.localUrls = peer.localUrls
                }
                pc.lastSeenCpu = peer.cpuUsagePercent
                pc.lastSeenUsedRam = peer.usedMemoryBytes
                pc.lastSeenTotalRam = peer.totalMemoryBytes
                savedPCs[idx] = pc
                if pc.normalizedTunnelUrl != nil {
                    remoteOnlineIds.insert(pc.id)
                    tunnelActiveIds.insert(pc.id)
                }
            } else if let t = peer.tunnelUrl, !t.isEmpty {
                let newPC = SavedPC(
                    name: peer.deviceName,
                    url: peer.localUrls.first ?? t,
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
                tunnelActiveIds.insert(newPC.id)
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

        // 1. Try direct LAN first (fastest)
        if (try? await probe.pingSpecificBase(pc.normalizedUrl, timeout: 1.5)) != nil {
            tunnelActiveIds.remove(pc.id)
            if let mid = pc.machineId { relayMachineIds.remove(mid) }
            resolvedRoute = true
        }
        // 2. Try active LAN Hub Relay if firewalled
        else if let mid = pc.machineId, hub?.hasActiveSession(machineId: mid) == true {
            relayMachineIds.insert(mid)
            tunnelActiveIds.remove(pc.id)
            resolvedRoute = true
        }
        // 3. Try saved Cloudflare Tunnel URL (when away from home / 4G)
        else if let tunnel = pc.normalizedTunnelUrl,
                (try? await probe.pingSpecificBase(tunnel, timeout: 3.5)) != nil {
            tunnelActiveIds.insert(pc.id)
            if let mid = pc.machineId { relayMachineIds.remove(mid) }
            resolvedRoute = true
        }
        // 4. If Tunnel URL rotated after reboot, ask any other reachable PC on LAN via /api/peers
        else {
            for other in savedPCs where other.id != pc.id {
                if let otherTunnel = other.normalizedTunnelUrl,
                   (try? await APIClient(pc: other).pingSpecificBase(otherTunnel, timeout: 2.5)) != nil {
                    await syncPeers(via: other)
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

    private func upsertPC(_ pc: SavedPC) {
        if let idx = savedPCs.firstIndex(where: {
            ($0.machineId != nil && $0.machineId == pc.machineId)
            || $0.normalizedUrl == pc.normalizedUrl
            || ($0.normalizedTunnelUrl != nil && $0.normalizedTunnelUrl == pc.normalizedTunnelUrl)
        }) {
            var existing = pc
            existing.id = savedPCs[idx].id
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
}
