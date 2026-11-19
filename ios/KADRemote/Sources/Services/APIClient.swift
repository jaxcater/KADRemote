import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case httpError(Int, String)
    case unauthorized
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Địa chỉ URL không hợp lệ."
        case .unauthorized:
            return "Access Token không đúng hoặc đã bị đổi."
        case .httpError(let code, let msg):
            return "Lỗi HTTP \(code): \(msg)"
        case .decodingError(let msg):
            return "Lỗi đọc dữ liệu: \(msg)"
        }
    }
}

final class KADWebSocketClient {
    private var directTask: URLSessionWebSocketTask?
    private var relayHandle: RelayWebSocketHandle?

    init(directTask: URLSessionWebSocketTask) {
        self.directTask = directTask
    }

    init(relayHandle: RelayWebSocketHandle) {
        self.relayHandle = relayHandle
    }

    func start(onMessage: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        if let directTask {
            directTask.resume()
            receiveLoop(task: directTask, onMessage: onMessage)
        } else if let relayHandle {
            relayHandle.onMessage = onMessage
        }
    }

    private func receiveLoop(
        task: URLSessionWebSocketTask,
        onMessage: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    ) {
        task.receive { [weak self] result in
            onMessage(result)
            if case .success = result {
                self?.receiveLoop(task: task, onMessage: onMessage)
            }
        }
    }

    func sendText(_ text: String, completion: ((Error?) -> Void)? = nil) {
        if let directTask {
            directTask.send(.string(text)) { err in
                completion?(err)
            }
        } else if let relayHandle {
            relayHandle.sendText(text)
            completion?(nil)
        }
    }

    func close() {
        directTask?.cancel(with: .normalClosure, reason: nil)
        directTask = nil
        relayHandle?.close()
        relayHandle = nil
    }
}

final class APIClient {
    let baseURL: String
    let fallbackURLs: [String]
    let token: String
    let machineId: String?
    weak var hub: AgentHubServer?
    let preferRelay: Bool
    private let session: URLSession

    init(pc: SavedPC, hub: AgentHubServer? = nil, preferRelay: Bool = false, preferTunnel: Bool = false) {
        let lanUrl = pc.normalizedUrl
        let tunnelUrl = pc.normalizedTunnelUrl

        var ordered: [String] = []
        if preferTunnel, let t = tunnelUrl {
            ordered.append(t)
        }
        ordered.append(lanUrl)
        for extra in (pc.localUrls ?? []) {
            let norm = SavedPC.normalizeUrl(extra)
            if !ordered.contains(norm) {
                ordered.append(norm)
            }
        }
        if !preferTunnel, let t = tunnelUrl, !ordered.contains(t) {
            ordered.append(t)
        }

        self.baseURL = ordered.first ?? lanUrl
        self.fallbackURLs = Array(ordered.dropFirst())
        self.token = pc.token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.machineId = pc.machineId
        self.hub = hub
        self.preferRelay = preferRelay

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    private func buildPathAndQuery(path: String, queryItems: [URLQueryItem]) -> String {
        guard !queryItems.isEmpty else { return path }
        var comp = URLComponents()
        comp.path = path
        comp.queryItems = queryItems
        return comp.string ?? path
    }

    private func makeRequest(
        base: String,
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String = "application/json",
        timeout: TimeInterval? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(string: base + path) else {
            throw APIError.invalidURL
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw APIError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        if let timeout {
            req.timeoutInterval = timeout
        } else if !base.lowercased().hasPrefix("https://") && !fallbackURLs.isEmpty {
            // Fast fail on unreachable private LAN IPs when a Cloudflare Tunnel fallback exists
            req.timeoutInterval = 2.5
        }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func rawRequest(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String = "application/json",
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        let pathAndQuery = buildPathAndQuery(path: path, queryItems: queryItems)

        if preferRelay, let machineId, let hub, await hub.hasActiveSession(machineId: machineId) {
            return try await sendViaRelay(machineId: machineId, hub: hub, method: method, pathAndQuery: pathAndQuery, contentType: contentType, body: body)
        }

        var lastError: Error = APIError.invalidURL
        let candidates = [baseURL] + fallbackURLs

        for base in candidates {
            do {
                let req = try makeRequest(base: base, path: path, method: method, queryItems: queryItems, body: body, contentType: contentType, timeout: timeout)
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw APIError.invalidURL
                }
                if http.statusCode == 401 {
                    throw APIError.unauthorized
                }
                if !(200...299).contains(http.statusCode) {
                    let msg = String(data: data, encoding: .utf8) ?? "Không rõ lỗi"
                    throw APIError.httpError(http.statusCode, msg)
                }
                return data
            } catch let err as APIError {
                if case .unauthorized = err { throw err }
                let isTunnelBase = base.lowercased().hasPrefix("https://")
                if !isTunnelBase, case .httpError(let code, _) = err, (400...499).contains(code) { throw err }
                lastError = err
            } catch {
                lastError = error
            }
        }

        if let machineId, let hub, await hub.hasActiveSession(machineId: machineId) {
            return try await sendViaRelay(machineId: machineId, hub: hub, method: method, pathAndQuery: pathAndQuery, contentType: contentType, body: body)
        }

        throw lastError
    }

    private func sendViaRelay(
        machineId: String,
        hub: AgentHubServer,
        method: String,
        pathAndQuery: String,
        contentType: String,
        body: Data?
    ) async throws -> Data {
        let (code, data) = try await hub.sendHttpRelay(
            machineId: machineId,
            method: method,
            pathAndQuery: pathAndQuery,
            contentType: contentType,
            body: body
        )
        if code == 401 { throw APIError.unauthorized }
        if !(200...299).contains(code) {
            let msg = String(data: data, encoding: .utf8) ?? "Không rõ lỗi"
            throw APIError.httpError(code, msg)
        }
        return data
    }

    private func send<T: Decodable>(_ path: String, method: String = "GET", queryItems: [URLQueryItem] = [], body: Data? = nil, timeout: TimeInterval? = nil) async throws -> T {
        let data = try await rawRequest(path: path, method: method, queryItems: queryItems, body: body, timeout: timeout)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error.localizedDescription)
        }
    }

    func ping(fastTimeout: TimeInterval = 4.0) async throws -> PingResponse {
        try await send("/api/ping", timeout: fastTimeout)
    }

    func pingSpecificBase(_ base: String, timeout: TimeInterval = 2.0) async throws -> PingResponse {
        let req = try makeRequest(base: base, path: "/api/ping", timeout: timeout)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.invalidURL
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.httpError(http.statusCode, "Ping failed")
        }
        return try JSONDecoder().decode(PingResponse.self, from: data)
    }

    func getPeers() async throws -> [PeerInfo] {
        try await send("/api/peers", timeout: 6.0)
    }

    func getSystemInfo() async throws -> SystemInfo {
        try await send("/api/system/info")
    }

    func getProcesses() async throws -> [ProcessItem] {
        try await send("/api/processes")
    }

    func killProcess(pid: Int) async throws -> ActionMessageResponse {
        let body = try JSONEncoder().encode(["pid": pid])
        return try await send("/api/processes/kill", method: "POST", body: body)
    }

    func powerAction(_ action: String) async throws -> ActionMessageResponse {
        let body = try JSONEncoder().encode(["action": action])
        return try await send("/api/system/power", method: "POST", body: body)
    }

    func execPowerShell(command: String, cwd: String?) async throws -> PsExecResponse {
        var payload: [String: String] = ["command": command]
        if let cwd, !cwd.isEmpty {
            payload["cwd"] = cwd
        }
        let body = try JSONEncoder().encode(payload)
        return try await send("/api/ps/exec", method: "POST", body: body)
    }

    func getQuickRoots() async throws -> QuickRootsResponse {
        try await send("/api/files/drives")
    }

    func listFiles(path: String?) async throws -> FileListResponse {
        var items: [URLQueryItem] = []
        if let path, !path.isEmpty {
            items.append(URLQueryItem(name: "path", value: path))
        }
        return try await send("/api/files/list", queryItems: items)
    }

    func mkdir(path: String) async throws {
        let body = try JSONEncoder().encode(["path": path])
        let _: [String: Bool] = try await send("/api/files/mkdir", method: "POST", body: body)
    }

    func deletePath(path: String) async throws {
        let body = try JSONEncoder().encode(["path": path])
        let _: [String: Bool] = try await send("/api/files/delete", method: "POST", body: body)
    }

    func renamePath(path: String, newName: String) async throws {
        let body = try JSONEncoder().encode(["path": path, "newName": newName])
        struct Resp: Codable { let ok: Bool }
        let _: Resp = try await send("/api/files/rename", method: "POST", body: body)
    }

    func runFile(path: String, args: String, asAdmin: Bool, waitForExit: Bool) async throws -> RunFileResponse {
        struct ReqBody: Encodable {
            let path: String
            let args: String
            let asAdmin: Bool
            let waitForExit: Bool
        }
        let body = try JSONEncoder().encode(ReqBody(path: path, args: args, asAdmin: asAdmin, waitForExit: waitForExit))
        return try await send("/api/files/run", method: "POST", body: body)
    }

    func downloadFile(remotePath: String, suggestedName: String) async throws -> URL {
        let safeName = (suggestedName as NSString).lastPathComponent
        let destDir = FileManager.default.temporaryDirectory.appendingPathComponent("KADDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destURL = destDir.appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }

        if preferRelay, let machineId, let hub, await hub.hasActiveSession(machineId: machineId) {
            let pq = buildPathAndQuery(path: "/api/files/download", queryItems: [URLQueryItem(name: "path", value: remotePath)])
            let data = try await sendViaRelay(machineId: machineId, hub: hub, method: "GET", pathAndQuery: pq, contentType: "application/octet-stream", body: nil)
            try data.write(to: destURL)
            return destURL
        }

        var lastError: Error = APIError.invalidURL
        for base in ([baseURL] + fallbackURLs) {
            do {
                let req = try makeRequest(
                    base: base,
                    path: "/api/files/download",
                    queryItems: [URLQueryItem(name: "path", value: remotePath)],
                    timeout: 300
                )
                let (tempURL, resp) = try await session.download(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw APIError.invalidURL
                }
                if http.statusCode == 401 {
                    throw APIError.unauthorized
                }
                if !(200...299).contains(http.statusCode) {
                    throw APIError.httpError(http.statusCode, "Tải file thất bại")
                }

                try FileManager.default.moveItem(at: tempURL, to: destURL)
                return destURL
            } catch let err as APIError {
                if case .unauthorized = err { throw err }
                lastError = err
            } catch {
                lastError = error
            }
        }

        if let machineId, let hub, await hub.hasActiveSession(machineId: machineId) {
            let pq = buildPathAndQuery(path: "/api/files/download", queryItems: [URLQueryItem(name: "path", value: remotePath)])
            let data = try await sendViaRelay(machineId: machineId, hub: hub, method: "GET", pathAndQuery: pq, contentType: "application/octet-stream", body: nil)
            try data.write(to: destURL)
            return destURL
        }

        throw lastError
    }

    func uploadData(_ data: Data, filename: String, toDir dir: String) async throws {
        _ = try await rawRequest(
            path: "/api/files/upload",
            method: "POST",
            queryItems: [
                URLQueryItem(name: "dir", value: dir),
                URLQueryItem(name: "filename", value: filename)
            ],
            body: data,
            contentType: "application/octet-stream",
            timeout: 300
        )
    }

    func getMonitors() async throws -> [MonitorInfo] {
        try await send("/api/screen/monitors")
    }

    func getSnapshot(monitor: Int = 0, quality: Int = 80, scale: Double = 0.85) async throws -> Data {
        try await rawRequest(
            path: "/api/screen/snapshot",
            queryItems: [
                URLQueryItem(name: "monitor", value: "\(monitor)"),
                URLQueryItem(name: "quality", value: "\(quality)"),
                URLQueryItem(name: "scale", value: "\(scale)")
            ]
        )
    }

    @MainActor
    func openWebSocket(path: String, queryItems: [URLQueryItem] = []) -> KADWebSocketClient? {
        if preferRelay, let machineId, let hub, hub.hasActiveSession(machineId: machineId) {
            let pq = buildPathAndQuery(path: path, queryItems: queryItems)
            if let handle = hub.openWebSocketRelay(machineId: machineId, pathAndQuery: pq) {
                return KADWebSocketClient(relayHandle: handle)
            }
        }

        guard let task = makeWebSocket(path: path, queryItems: queryItems) else { return nil }
        return KADWebSocketClient(directTask: task)
    }

    func makeWebSocket(path: String, queryItems: [URLQueryItem] = []) -> URLSessionWebSocketTask? {
        var wsBase = baseURL
        if wsBase.lowercased().hasPrefix("https://") {
            wsBase = "wss://" + wsBase.dropFirst("https://".count)
        } else if wsBase.lowercased().hasPrefix("http://") {
            wsBase = "ws://" + wsBase.dropFirst("http://".count)
        }
        guard var components = URLComponents(string: wsBase + path) else { return nil }
        var items = queryItems
        items.append(URLQueryItem(name: "token", value: token))
        components.queryItems = items
        guard let url = components.url else { return nil }
        return session.webSocketTask(with: url)
    }
}
