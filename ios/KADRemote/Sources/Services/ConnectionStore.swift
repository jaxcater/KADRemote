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

    private let pcsKey = "kad_saved_pcs_v1"
    private let activeIdKey = "kad_active_pc_id_v1"

    weak var hub: AgentHubServer?
    weak var backgroundManager: BackgroundManager?

    var client: APIClient? {
        guard let pc = activePC else { return nil }
        let useRelay = pc.machineId.map { relayMachineIds.contains($0) } ?? false
        return APIClient(pc: pc, hub: hub, preferRelay: useRelay)
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

        hub.onAgentDisconnected = { [weak self] machineId, name in
            Task { @MainActor [weak self] in
                self?.backgroundManager?.notifyIfInBackground(
                    title: "KAD Remote",
                    body: "\(name) đã ngắt kết nối khỏi Hub."
                )
                if self?.activePC?.machineId == machineId {
                    // Keep saved, relay will resume when agent reconnects
                }
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
                lastSeenTotalRam: status.totalMemoryBytes
            )
            savedPCs.insert(newPC, at: 0)
            backgroundManager?.notifyIfInBackground(
                title: "Server mới đã kết nối",
                body: "\(status.deviceName) (\(bestUrl)) đã tự động ghép nối."
            )
        }
        save()
    }

    func isAgentOnline(_ pc: SavedPC) -> Bool {
        guard let mid = pc.machineId else { return false }
        return hub?.onlineAgents[mid] != nil
    }

    func liveStatus(for pc: SavedPC) -> AgentLiveStatus? {
        guard let mid = pc.machineId else { return nil }
        return hub?.onlineAgents[mid]
    }

    func reconnectActive() async {
        guard let pc = activePC else { return }
        isConnecting = true
        errorMessage = nil

        // Check direct connectivity first if machine has a live hub session, so we know whether to use fast direct LAN or firewall-bypass relay
        if let mid = pc.machineId, hub?.hasActiveSession(machineId: mid) == true {
            let directClient = APIClient(pc: pc, hub: hub, preferRelay: false)
            if let _ = try? await directClient.pingDirectOnly(timeout: 1.5) {
                relayMachineIds.remove(mid)
            } else {
                relayMachineIds.insert(mid)
            }
        }

        do {
            let useRelay = pc.machineId.map { relayMachineIds.contains($0) } ?? false
            let resp = try await APIClient(pc: pc, hub: hub, preferRelay: useRelay).ping()
            var updated = pc
            if !resp.deviceName.isEmpty {
                updated.name = resp.deviceName
            }
            updated.lastConnected = Date()
            upsertPC(updated)
            activePC = updated
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

        var candidate = SavedPC(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "My PC" : name,
            url: url,
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            lastConnected: Date()
        )

        do {
            let pingResp = try await APIClient(pc: candidate, hub: hub).ping()
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !pingResp.deviceName.isEmpty {
                candidate.name = pingResp.deviceName
            }
            upsertPC(candidate)
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
        if activePC?.id == pc.id {
            activePC = nil
            isConnected = false
        }
        save()
    }

    private func upsertPC(_ pc: SavedPC) {
        if let idx = savedPCs.firstIndex(where: {
            ($0.machineId != nil && $0.machineId == pc.machineId) || $0.normalizedUrl == pc.normalizedUrl
        }) {
            var existing = pc
            existing.id = savedPCs[idx].id
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
