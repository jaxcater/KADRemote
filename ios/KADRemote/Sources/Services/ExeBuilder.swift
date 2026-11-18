import Foundation

enum ExeBuilderError: LocalizedError {
    case templateNotFound
    case configTooLarge

    var errorDescription: String? {
        switch self {
        case .templateNotFound:
            return "Không tìm thấy KadAgentTemplate.exe trong gói ứng dụng. Hãy build lại Kad.ipa qua GitHub Actions."
        case .configTooLarge:
            return "Cấu hình xuất ra vượt quá kích thước cho phép."
        }
    }
}

enum ExeBuilder {
    private static let magic = "KADCFG01"

    static var hasTemplate: Bool {
        templateURL() != nil
    }

    private static func templateURL() -> URL? {
        Bundle.main.url(forResource: "KadAgentTemplate", withExtension: "exe")
            ?? Bundle.main.url(forResource: "KadAgentTemplate", withExtension: "exe", subdirectory: "Resources")
    }

    static func buildConfiguredExe(config: AgentExportConfig) throws -> URL {
        guard let template = templateURL() else {
            throw ExeBuilderError.templateNotFound
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let jsonData = try encoder.encode(config)
        guard jsonData.count <= 64 * 1024 else {
            throw ExeBuilderError.configTooLarge
        }

        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("KADExport", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("Kad.exe")

        if FileManager.default.fileExists(atPath: outURL.path) {
            try FileManager.default.removeItem(at: outURL)
        }
        try FileManager.default.copyItem(at: template, to: outURL)

        let handle = try FileHandle(forWritingTo: outURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: jsonData)

        var lenLE = Int32(jsonData.count).littleEndian
        let lenData = Data(bytes: &lenLE, count: 4)
        try handle.write(contentsOf: lenData)
        try handle.write(contentsOf: Data(magic.utf8))

        return outURL
    }
}
