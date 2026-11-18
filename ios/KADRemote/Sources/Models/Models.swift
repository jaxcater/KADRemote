import Foundation

struct SavedPC: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var token: String
    var lastConnected: Date?
    var machineId: String?
    var isAutoDiscovered: Bool?
    var lastSeenCpu: Double?
    var lastSeenUsedRam: Int64?
    var lastSeenTotalRam: Int64?

    var normalizedUrl: String {
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "http://" + trimmed
        }
        return trimmed
    }
}

struct AgentExportConfig: Codable {
    var controllerHost: String
    var controllerPort: Int
    var controllerToken: String
    var agentPort: Int
    var startWithWindows: Bool
    var udpDiscovery: Bool
    var exportedBy: String?
    var exportedAt: String?
}

struct AgentLiveStatus: Equatable {
    let machineId: String
    let deviceName: String
    let localUrls: [String]
    let agentPort: Int
    let remoteIP: String
    let cpuUsagePercent: Double
    let totalMemoryBytes: Int64
    let usedMemoryBytes: Int64
    let uptimeSeconds: Int64
    let lastHeartbeat: Date
}

struct PingResponse: Codable {
    let ok: Bool
    let deviceName: String
}

struct DiskInfo: Codable, Identifiable {
    let name: String
    let label: String
    let totalBytes: Int64
    let freeBytes: Int64

    var id: String { name }
    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
    var usedRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }
}

struct SystemInfo: Codable {
    let deviceName: String
    let osVersion: String
    let userName: String
    let cpuUsagePercent: Double
    let totalMemoryBytes: Int64
    let usedMemoryBytes: Int64
    let uptimeSeconds: Int64
    let monitorCount: Int
    let disks: [DiskInfo]
    let localUrls: [String]
    let tunnelUrl: String?

    var memoryRatio: Double {
        guard totalMemoryBytes > 0 else { return 0 }
        return Double(usedMemoryBytes) / Double(totalMemoryBytes)
    }
}

struct ProcessItem: Codable, Identifiable {
    let pid: Int
    let name: String
    let windowTitle: String
    let memoryBytes: Int64

    var id: Int { pid }
}

struct ActionMessageResponse: Codable {
    let ok: Bool
    let message: String?
}

struct PsExecResponse: Codable {
    let stdout: String
    let stderr: String
    let exitCode: Int
    let cwd: String
    let durationMs: Int64
}

struct QuickShortcut: Codable, Identifiable {
    let name: String
    let path: String
    var id: String { path }
}

struct QuickRootsResponse: Codable {
    let shortcuts: [QuickShortcut]
    let drives: [DiskInfo]
}

struct FileEntry: Codable, Identifiable {
    let name: String
    let fullPath: String
    let isDirectory: Bool
    let sizeBytes: Int64
    let lastModifiedUtc: String
    let `extension`: String

    var id: String { fullPath }
}

struct FileListResponse: Codable {
    let currentPath: String
    let parentPath: String?
    let entries: [FileEntry]
}

struct RunFileResponse: Codable {
    let started: Bool
    let pid: Int?
    let message: String
    let output: String?
    let exitCode: Int?
}

struct MonitorInfo: Codable, Identifiable {
    let index: Int
    let name: String
    let width: Int
    let height: Int
    let x: Int
    let y: Int
    let isPrimary: Bool

    var id: Int { index }
}

enum ByteFormatter {
    static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func formatUptime(_ seconds: Int64) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let mins = (seconds % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h \(mins)m"
        }
        return "\(hours)h \(mins)m"
    }
}
