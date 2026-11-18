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

final class APIClient {
    let baseURL: String
    let token: String
    private let session: URLSession

    init(pc: SavedPC) {
        self.baseURL = pc.normalizedUrl
        self.token = pc.token.trimmingCharacters(in: .whitespacesAndNewlines)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    private func makeRequest(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String = "application/json"
    ) throws -> URLRequest {
        guard var components = URLComponents(string: baseURL + path) else {
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
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
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
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error.localizedDescription)
        }
    }

    func ping() async throws -> PingResponse {
        let req = try makeRequest(path: "/api/ping")
        return try await send(req)
    }

    func getSystemInfo() async throws -> SystemInfo {
        let req = try makeRequest(path: "/api/system/info")
        return try await send(req)
    }

    func getProcesses() async throws -> [ProcessItem] {
        let req = try makeRequest(path: "/api/processes")
        return try await send(req)
    }

    func killProcess(pid: Int) async throws -> ActionMessageResponse {
        let body = try JSONEncoder().encode(["pid": pid])
        let req = try makeRequest(path: "/api/processes/kill", method: "POST", body: body)
        return try await send(req)
    }

    func powerAction(_ action: String) async throws -> ActionMessageResponse {
        let body = try JSONEncoder().encode(["action": action])
        let req = try makeRequest(path: "/api/system/power", method: "POST", body: body)
        return try await send(req)
    }

    func execPowerShell(command: String, cwd: String?) async throws -> PsExecResponse {
        var payload: [String: String] = ["command": command]
        if let cwd, !cwd.isEmpty {
            payload["cwd"] = cwd
        }
        let body = try JSONEncoder().encode(payload)
        let req = try makeRequest(path: "/api/ps/exec", method: "POST", body: body)
        return try await send(req)
    }

    func getQuickRoots() async throws -> QuickRootsResponse {
        let req = try makeRequest(path: "/api/files/drives")
        return try await send(req)
    }

    func listFiles(path: String?) async throws -> FileListResponse {
        var items: [URLQueryItem] = []
        if let path, !path.isEmpty {
            items.append(URLQueryItem(name: "path", value: path))
        }
        let req = try makeRequest(path: "/api/files/list", queryItems: items)
        return try await send(req)
    }

    func mkdir(path: String) async throws {
        let body = try JSONEncoder().encode(["path": path])
        let req = try makeRequest(path: "/api/files/mkdir", method: "POST", body: body)
        let _: [String: Bool] = try await send(req)
    }

    func deletePath(path: String) async throws {
        let body = try JSONEncoder().encode(["path": path])
        let req = try makeRequest(path: "/api/files/delete", method: "POST", body: body)
        let _: [String: Bool] = try await send(req)
    }

    func renamePath(path: String, newName: String) async throws {
        let body = try JSONEncoder().encode(["path": path, "newName": newName])
        let req = try makeRequest(path: "/api/files/rename", method: "POST", body: body)
        struct Resp: Codable { let ok: Bool }
        let _: Resp = try await send(req)
    }

    func runFile(path: String, args: String, asAdmin: Bool, waitForExit: Bool) async throws -> RunFileResponse {
        struct ReqBody: Encodable {
            let path: String
            let args: String
            let asAdmin: Bool
            let waitForExit: Bool
        }
        let body = try JSONEncoder().encode(ReqBody(path: path, args: args, asAdmin: asAdmin, waitForExit: waitForExit))
        let req = try makeRequest(path: "/api/files/run", method: "POST", body: body)
        return try await send(req)
    }

    func downloadFile(remotePath: String, suggestedName: String) async throws -> URL {
        let req = try makeRequest(
            path: "/api/files/download",
            queryItems: [URLQueryItem(name: "path", value: remotePath)]
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

        let safeName = (suggestedName as NSString).lastPathComponent
        let destDir = FileManager.default.temporaryDirectory.appendingPathComponent("KADDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destURL = destDir.appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        return destURL
    }

    func uploadData(_ data: Data, filename: String, toDir dir: String) async throws {
        let req = try makeRequest(
            path: "/api/files/upload",
            method: "POST",
            queryItems: [
                URLQueryItem(name: "dir", value: dir),
                URLQueryItem(name: "filename", value: filename)
            ],
            body: data,
            contentType: "application/octet-stream"
        )
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.invalidURL
        }
        if http.statusCode == 401 {
            throw APIError.unauthorized
        }
        if !(200...299).contains(http.statusCode) {
            throw APIError.httpError(http.statusCode, "Upload thất bại")
        }
    }

    func getMonitors() async throws -> [MonitorInfo] {
        let req = try makeRequest(path: "/api/screen/monitors")
        return try await send(req)
    }

    func getSnapshot(monitor: Int = 0, quality: Int = 80, scale: Double = 0.85) async throws -> Data {
        let req = try makeRequest(
            path: "/api/screen/snapshot",
            queryItems: [
                URLQueryItem(name: "monitor", value: "\(monitor)"),
                URLQueryItem(name: "quality", value: "\(quality)"),
                URLQueryItem(name: "scale", value: "\(scale)")
            ]
        )
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.httpError(500, "Không thể chụp màn hình")
        }
        return data
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
