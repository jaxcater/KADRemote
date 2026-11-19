import Foundation
import Network
import CryptoKit
import Security
import UIKit
import Darwin

enum NetworkUtils {
    struct InterfaceAddress: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let ip: String
        let netmask: String?

        var label: String {
            if name == "en0" { return "Wi-Fi (\(ip))" }
            if name.hasPrefix("utun") || name.hasPrefix("ipsec") { return "VPN/Tailscale (\(ip))" }
            return "\(name) (\(ip))"
        }
    }

    static func getLocalIPAddresses() -> [InterfaceAddress] {
        var results: [InterfaceAddress] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return results }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp && !isLoopback, let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostname)
                    let name = String(cString: current.pointee.ifa_name)
                    var maskStr: String? = nil
                    if let maskAddr = current.pointee.ifa_netmask, maskAddr.pointee.sa_family == UInt8(AF_INET) {
                        var maskHost = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(maskAddr, socklen_t(maskAddr.pointee.sa_len), &maskHost, socklen_t(maskHost.count), nil, 0, NI_NUMERICHOST) == 0 {
                            maskStr = String(cString: maskHost)
                        }
                    }
                    // Exclude link-local, loopback, and cellular (pdp_ip*) interfaces
                    if !ip.hasPrefix("169.254.") && !ip.hasPrefix("127.") && !name.hasPrefix("pdp_ip") {
                        results.append(InterfaceAddress(name: name, ip: ip, netmask: maskStr))
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }

        return results.sorted { a, b in
            let scoreA = a.name == "en0" ? 2 : (a.name.hasPrefix("utun") ? 1 : 0)
            let scoreB = b.name == "en0" ? 2 : (b.name.hasPrefix("utun") ? 1 : 0)
            return scoreA > scoreB
        }
    }

    static func getSubnetBroadcastAddresses() -> [String] {
        var targets = Set<String>(["255.255.255.255"])
        for iface in getLocalIPAddresses() {
            guard let mask = iface.netmask else { continue }
            var ipAddr = in_addr()
            var maskAddr = in_addr()
            if inet_pton(AF_INET, iface.ip, &ipAddr) == 1,
               inet_pton(AF_INET, mask, &maskAddr) == 1 {
                let bcastVal = ipAddr.s_addr | ~maskAddr.s_addr
                var bcastIn = in_addr(s_addr: bcastVal)
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &bcastIn, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    targets.insert(String(cString: buf))
                }
            }
        }
        return Array(targets)
    }
}

final class RelayWebSocketHandle {
    let streamId: String
    private let onSend: (String, Bool) -> Void
    private let onCloseAction: () -> Void

    var onMessage: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?

    init(streamId: String, onSend: @escaping (String, Bool) -> Void, onClose: @escaping () -> Void) {
        self.streamId = streamId
        self.onSend = onSend
        self.onCloseAction = onClose
    }

    func sendText(_ text: String) {
        onSend(text, false)
    }

    func close() {
        onCloseAction()
    }
}

@MainActor
final class AgentHubServer: ObservableObject {
    private let tokenKey = "kad_controller_token_v1"
    private let hubPortKey = "kad_controller_hub_port_v1"
    private let agentPortKey = "kad_default_agent_port_v1"

    @Published var controllerToken: String
    @Published var hubPort: Int
    @Published var defaultAgentPort: Int
    @Published var isListening: Bool = false
    @Published var listenerStatus: String = "Đang khởi động..."
    @Published var onlineAgents: [String: AgentLiveStatus] = [:]

    var onAgentRegistered: ((AgentLiveStatus, String) -> Void)?
    var onAgentHeartbeat: ((AgentLiveStatus) -> Void)?
    var onAgentDisconnected: ((String, String) -> Void)?

    private var wsListener: NWListener?
    private var isWsReady: Bool = false
    private var udpReadSource: DispatchSourceRead?
    private var udpSocketFd: Int32 = -1
    private var pathMonitor: NWPathMonitor?
    private var lastNetworkSignature: String = ""
    private var pendingRetryTask: Task<Void, Never>?

    private var sessions: [String: NWConnection] = [:] // machineId -> NWConnection
    private var pendingHttp: [String: CheckedContinuation<(Int, Data), Error>] = [:]
    private var activeRelays: [String: RelayWebSocketHandle] = [:]

    init() {
        let defaults = UserDefaults.standard
        if let savedToken = defaults.string(forKey: tokenKey), !savedToken.isEmpty {
            self.controllerToken = savedToken
        } else {
            let fresh = Self.generateToken()
            defaults.set(fresh, forKey: tokenKey)
            self.controllerToken = fresh
        }

        let savedHubPort = defaults.integer(forKey: hubPortKey)
        self.hubPort = (1024...65535).contains(savedHubPort) ? savedHubPort : 7789

        let savedAgentPort = defaults.integer(forKey: agentPortKey)
        self.defaultAgentPort = (1024...65535).contains(savedAgentPort) ? savedAgentPort : 7788
    }

    func regenerateToken() {
        let fresh = Self.generateToken()
        controllerToken = fresh
        UserDefaults.standard.set(fresh, forKey: tokenKey)
    }

    func updatePorts(hub: Int, agent: Int) {
        if (1024...65535).contains(hub), hub != hubPort {
            hubPort = hub
            UserDefaults.standard.set(hub, forKey: hubPortKey)
            restart()
        }
        if (1024...65535).contains(agent) {
            defaultAgentPort = agent
            UserDefaults.standard.set(agent, forKey: agentPortKey)
        }
    }

    func start() {
        startPathMonitorIfNeeded()
        guard wsListener == nil else {
            ensureRunning()
            return
        }
        startWebSocketListener()
        startUdpDiscoveryListener()
    }

    func ensureRunning() {
        startPathMonitorIfNeeded()
        if wsListener == nil || !isWsReady || udpReadSource == nil {
            restart()
        }
    }

    func restart() {
        stopListenersOnly()
        startWebSocketListener()
        startUdpDiscoveryListener()
    }

    func stop() {
        pendingRetryTask?.cancel()
        pendingRetryTask = nil
        stopListenersOnly()
        for (_, conn) in sessions { conn.cancel() }
        sessions.removeAll()
        onlineAgents.removeAll()
        isListening = false
    }

    private func stopListenersOnly() {
        wsListener?.cancel()
        wsListener = nil
        isWsReady = false
        stopUdpDiscoveryListener()
    }

    private func startPathMonitorIfNeeded() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let sig = "\(path.status)-\(path.availableInterfaces.map { $0.name }.joined(separator: ","))"
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.lastNetworkSignature.isEmpty {
                    self.lastNetworkSignature = sig
                    return
                }
                if sig != self.lastNetworkSignature {
                    self.lastNetworkSignature = sig
                    if path.status == .satisfied {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        self.restart()
                    }
                }
            }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    private func scheduleRecoveryRestart() {
        pendingRetryTask?.cancel()
        pendingRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if !self.isWsReady {
                self.restart()
            }
        }
    }

    func hasActiveSession(machineId: String?) -> Bool {
        guard let machineId, !machineId.isEmpty else { return false }
        return sessions[machineId] != nil
    }

    private func startWebSocketListener() {
        guard let port = NWEndpoint.Port(rawValue: UInt16(hubPort)) else { return }

        let wsOpts = NWProtocolWebSocket.Options()
        wsOpts.autoReplyPing = true
        wsOpts.maximumMessageSize = 32 * 1024 * 1024

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOpts, at: 0)

        do {
            let listener = try NWListener(using: params, on: port)
            listener.service = NWListener.Service(type: "_kadremote._tcp")
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isWsReady = true
                        self.isListening = true
                        self.listenerStatus = "Hub đang lắng nghe :\(self.hubPort)"
                    case .waiting(let err):
                        self.isWsReady = false
                        self.isListening = false
                        self.listenerStatus = "Đang chờ mạng: \(err.localizedDescription)"
                        self.scheduleRecoveryRestart()
                    case .failed(let err):
                        self.isWsReady = false
                        self.isListening = false
                        self.listenerStatus = "Lỗi Hub: \(err.localizedDescription)"
                        self.scheduleRecoveryRestart()
                    case .cancelled:
                        self.isWsReady = false
                        self.isListening = false
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor [weak self] in
                    self?.acceptAgentConnection(conn)
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.wsListener = listener
        } catch {
            isWsReady = false
            isListening = false
            listenerStatus = "Không thể mở cổng \(hubPort): \(error.localizedDescription)"
            scheduleRecoveryRestart()
        }
    }

    private func startUdpDiscoveryListener() {
        stopUdpDiscoveryListener()

        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(hubPort).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            return
        }

        let expectedHash = Self.sha256Hex(controllerToken)
        let currentPort = hubPort
        let deviceName = UIDevice.current.name

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        source.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                var senderAddr = sockaddr_in()
                var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &senderAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, &buf, buf.count, 0, sa, &senderLen)
                    }
                }
                if n <= 0 { break }

                let packetData = Data(bytes: buf, count: n)
                guard let obj = try? JSONSerialization.jsonObject(with: packetData) as? [String: Any],
                      let type = obj["type"] as? String, type == "discover",
                      let tokenHash = obj["tokenHash"] as? String,
                      tokenHash.lowercased() == expectedHash else {
                    continue
                }

                let reply: [String: Any] = [
                    "type": "here",
                    "port": currentPort,
                    "controllerName": deviceName
                ]
                if let replyData = try? JSONSerialization.data(withJSONObject: reply) {
                    replyData.withUnsafeBytes { rawBuf in
                        guard let base = rawBuf.baseAddress else { return }
                        _ = withUnsafePointer(to: &senderAddr) { ptr in
                            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                sendto(fd, base, replyData.count, 0, sa, senderLen)
                            }
                        }
                    }
                }
            }
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()

        self.udpSocketFd = fd
        self.udpReadSource = source
    }

    private func stopUdpDiscoveryListener() {
        if let src = udpReadSource {
            udpReadSource = nil
            udpSocketFd = -1
            src.cancel()
        } else if udpSocketFd >= 0 {
            Darwin.close(udpSocketFd)
            udpSocketFd = -1
        }
    }

    private func acceptAgentConnection(_ conn: NWConnection) {
        let connId = UUID().uuidString

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    self?.handleConnectionClosed(conn: conn)
                }
            default:
                break
            }
        }

        conn.start(queue: .global(qos: .userInitiated))

        func receiveNext() {
            conn.receiveMessage { [weak self] content, context, _, error in
                if error != nil {
                    conn.cancel()
                    return
                }

                if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                   meta.opcode == .close {
                    conn.cancel()
                    return
                }

                if let content, let text = String(data: content, encoding: .utf8) {
                    Task { @MainActor [weak self] in
                        self?.handleAgentMessage(text, conn: conn, connId: connId)
                    }
                }

                receiveNext()
            }
        }

        receiveNext()
    }

    private func handleConnectionClosed(conn: NWConnection) {
        guard let machineId = sessions.first(where: { $0.value === conn })?.key else { return }
        sessions.removeValue(forKey: machineId)
        let name = onlineAgents[machineId]?.deviceName ?? machineId
        onlineAgents.removeValue(forKey: machineId)
        onAgentDisconnected?(machineId, name)
    }

    private func handleAgentMessage(_ text: String, conn: NWConnection, connId: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "register":
            let token = obj["token"] as? String ?? ""
            guard token == controllerToken else {
                conn.cancel()
                return
            }
            let machineId = obj["machineId"] as? String ?? connId
            let deviceName = obj["deviceName"] as? String ?? "Windows Server"
            let agentPort = obj["agentPort"] as? Int ?? defaultAgentPort
            let localUrls = obj["localUrls"] as? [String] ?? []
            let tunnelUrl = obj["tunnelUrl"] as? String
            let cpu = obj["cpuUsagePercent"] as? Double ?? 0
            let totalMem = (obj["totalMemoryBytes"] as? NSNumber)?.int64Value ?? 0
            let usedMem = (obj["usedMemoryBytes"] as? NSNumber)?.int64Value ?? 0
            let uptime = (obj["uptimeSeconds"] as? NSNumber)?.int64Value ?? 0
            let remoteIP = Self.extractRemoteIP(conn.endpoint)

            sessions[machineId]?.cancel()
            sessions[machineId] = conn

            let status = AgentLiveStatus(
                machineId: machineId,
                deviceName: deviceName,
                localUrls: localUrls,
                tunnelUrl: tunnelUrl,
                agentPort: agentPort,
                remoteIP: remoteIP,
                cpuUsagePercent: cpu,
                totalMemoryBytes: totalMem,
                usedMemoryBytes: usedMem,
                uptimeSeconds: uptime,
                lastHeartbeat: Date()
            )
            onlineAgents[machineId] = status
            onAgentRegistered?(status, token)

        case "heartbeat":
            guard let machineId = obj["machineId"] as? String,
                  let existing = onlineAgents[machineId] else { return }
            let localUrls = obj["localUrls"] as? [String] ?? existing.localUrls
            let tunnelUrl = (obj["tunnelUrl"] as? String) ?? existing.tunnelUrl
            let cpu = obj["cpuUsagePercent"] as? Double ?? existing.cpuUsagePercent
            let totalMem = (obj["totalMemoryBytes"] as? NSNumber)?.int64Value ?? existing.totalMemoryBytes
            let usedMem = (obj["usedMemoryBytes"] as? NSNumber)?.int64Value ?? existing.usedMemoryBytes
            let uptime = (obj["uptimeSeconds"] as? NSNumber)?.int64Value ?? existing.uptimeSeconds

            let updated = AgentLiveStatus(
                machineId: machineId,
                deviceName: existing.deviceName,
                localUrls: localUrls,
                tunnelUrl: tunnelUrl,
                agentPort: existing.agentPort,
                remoteIP: existing.remoteIP,
                cpuUsagePercent: cpu,
                totalMemoryBytes: totalMem,
                usedMemoryBytes: usedMem,
                uptimeSeconds: uptime,
                lastHeartbeat: Date()
            )
            onlineAgents[machineId] = updated
            onAgentHeartbeat?(updated)

        case "http_res":
            let reqId = obj["id"] as? String ?? ""
            guard let cont = pendingHttp.removeValue(forKey: reqId) else { return }
            let statusCode = obj["statusCode"] as? Int ?? 500
            let b64 = obj["bodyBase64"] as? String ?? ""
            let bodyData = Data(base64Encoded: b64) ?? Data()
            cont.resume(returning: (statusCode, bodyData))

        case "ws_msg":
            let streamId = obj["streamId"] as? String ?? ""
            guard let handle = activeRelays[streamId] else { return }
            let isBin = obj["isBinary"] as? Bool ?? false
            let payload = obj["data"] as? String ?? ""
            if isBin {
                if let raw = Data(base64Encoded: payload) {
                    handle.onMessage?(.success(.data(raw)))
                }
            } else {
                handle.onMessage?(.success(.string(payload)))
            }

        case "ws_close":
            let streamId = obj["streamId"] as? String ?? ""
            if let handle = activeRelays.removeValue(forKey: streamId) {
                let errMsg = obj["error"] as? String ?? "Stream closed"
                handle.onMessage?(.failure(APIError.httpError(502, errMsg)))
            }

        default:
            break
        }
    }

    func sendHttpRelay(
        machineId: String,
        method: String,
        pathAndQuery: String,
        contentType: String = "application/json",
        body: Data? = nil
    ) async throws -> (Int, Data) {
        guard let conn = sessions[machineId] else {
            throw APIError.httpError(503, "Máy chủ chưa kết nối tới Hub.")
        }

        let reqId = UUID().uuidString
        var payload: [String: Any] = [
            "type": "http_req",
            "id": reqId,
            "method": method,
            "path": pathAndQuery,
            "contentType": contentType
        ]
        if let body {
            payload["bodyBase64"] = body.base64EncodedString()
        }

        let jsonData = try JSONSerialization.data(withJSONObject: payload)

        return try await withCheckedThrowingContinuation { cont in
            pendingHttp[reqId] = cont
            sendWebSocketText(conn: conn, data: jsonData)

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if let timedOut = self?.pendingHttp.removeValue(forKey: reqId) {
                    timedOut.resume(throwing: APIError.httpError(504, "Quá thời gian phản hồi qua Relay."))
                }
            }
        }
    }

    func openWebSocketRelay(machineId: String, pathAndQuery: String) -> RelayWebSocketHandle? {
        guard let conn = sessions[machineId] else { return nil }
        let streamId = UUID().uuidString

        let handle = RelayWebSocketHandle(
            streamId: streamId,
            onSend: { [weak self] text, isBin in
                Task { @MainActor [weak self] in
                    guard let self, let c = self.sessions[machineId] else { return }
                    let msg: [String: Any] = [
                        "type": "ws_msg",
                        "streamId": streamId,
                        "isBinary": isBin,
                        "data": text
                    ]
                    if let d = try? JSONSerialization.data(withJSONObject: msg) {
                        self.sendWebSocketText(conn: c, data: d)
                    }
                }
            },
            onClose: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.activeRelays.removeValue(forKey: streamId)
                    if let c = self.sessions[machineId] {
                        let msg: [String: Any] = ["type": "ws_close", "streamId": streamId]
                        if let d = try? JSONSerialization.data(withJSONObject: msg) {
                            self.sendWebSocketText(conn: c, data: d)
                        }
                    }
                }
            }
        )

        activeRelays[streamId] = handle

        let openMsg: [String: Any] = [
            "type": "ws_open",
            "streamId": streamId,
            "path": pathAndQuery
        ]
        if let d = try? JSONSerialization.data(withJSONObject: openMsg) {
            sendWebSocketText(conn: conn, data: d)
        }
        return handle
    }

    private func sendWebSocketText(conn: NWConnection, data: Data) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "wsText", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    private static func extractRemoteIP(_ endpoint: NWEndpoint) -> String {
        if case let .hostPort(host, _) = endpoint {
            var raw = "\(host)"
            // Strip IPv6 zone (%en0) or IPv4-mapped prefix (::ffff:)
            if let pct = raw.firstIndex(of: "%") {
                raw = String(raw[..<pct])
            }
            if raw.hasPrefix("::ffff:") {
                return String(raw.dropFirst("::ffff:".count))
            }
            return raw
        }
        return ""
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256Hex(_ str: String) -> String {
        let digest = SHA256.hash(data: Data(str.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
