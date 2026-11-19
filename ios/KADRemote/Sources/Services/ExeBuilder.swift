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
    private static let legacyMagic = "KADCFG01"
    private static let slotPrefix = "KADCFG_SLOT_V2::"
    private static let slotTotalSize = 16384
    private static let slotPayloadCapacity = slotTotalSize - 16

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
        let encodedString = "B64:" + jsonData.base64EncodedString()
        let encodedData = Data(encodedString.utf8)
        guard encodedData.count <= slotPayloadCapacity else {
            throw ExeBuilderError.configTooLarge
        }

        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("KADExport", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("Kad.exe")

        if FileManager.default.fileExists(atPath: outURL.path) {
            try FileManager.default.removeItem(at: outURL)
        }

        var binaryData = try Data(contentsOf: template)
        let markerData = Data(slotPrefix.utf8)

        if let markerRange = binaryData.range(of: markerData),
           markerRange.upperBound + slotPayloadCapacity <= binaryData.count {
            // Patch pre-allocated in-place resource slot so PE headers, section alignment, and file size remain 100% intact
            var paddedPayload = Data(capacity: slotPayloadCapacity)
            paddedPayload.append(encodedData)
            if encodedData.count < slotPayloadCapacity {
                paddedPayload.append(Data(repeating: 0x20, count: slotPayloadCapacity - encodedData.count))
            }
            let payloadRange = markerRange.upperBound..<(markerRange.upperBound + slotPayloadCapacity)
            binaryData.replaceSubrange(payloadRange, with: paddedPayload)
            updatePEHeaderChecksum(&binaryData)
            try binaryData.write(to: outURL, options: .atomic)
            return outURL
        }

        // Legacy fallback if template does not contain v2 slot
        try binaryData.write(to: outURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: outURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: jsonData)

        var lenLE = Int32(jsonData.count).littleEndian
        let lenData = Data(bytes: &lenLE, count: 4)
        try handle.write(contentsOf: lenData)
        try handle.write(contentsOf: Data(legacyMagic.utf8))

        return outURL
    }

    /// Recomputes and writes the standard Win32 PE OptionalHeader.CheckSum (identical to imagehlp.dll MapFileAndCheckSum)
    private static func updatePEHeaderChecksum(_ data: inout Data) {
        guard data.count > 0x100 else { return }
        let mz0 = data[0]
        let mz1 = data[1]
        guard mz0 == 0x4D, mz1 == 0x5A else { return } // "MZ"

        let peOffset = Int(data[0x3C])
            | (Int(data[0x3D]) << 8)
            | (Int(data[0x3E]) << 16)
            | (Int(data[0x3F]) << 24)
        let checksumOffset = peOffset + 24 + 64
        guard peOffset > 0, checksumOffset + 4 <= data.count else { return }
        guard data[peOffset] == 0x50, data[peOffset + 1] == 0x45,
              data[peOffset + 2] == 0x00, data[peOffset + 3] == 0x00 else { return } // "PE\0\0"

        data[checksumOffset] = 0
        data[checksumOffset + 1] = 0
        data[checksumOffset + 2] = 0
        data[checksumOffset + 3] = 0

        var sum: UInt64 = 0
        let count = data.count
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var i = 0
            while i + 1 < count {
                let word = UInt64(base[i]) | (UInt64(base[i + 1]) << 8)
                sum += word
                sum = (sum & 0xFFFF_FFFF) + (sum >> 32)
                i += 2
            }
            if i < count {
                sum += UInt64(base[i])
                sum = (sum & 0xFFFF_FFFF) + (sum >> 32)
            }
        }

        sum = (sum & 0xFFFF) + (sum >> 16)
        sum = (sum & 0xFFFF) + (sum >> 16)
        let finalSum = UInt32(truncatingIfNeeded: sum + UInt64(count))

        data[checksumOffset] = UInt8(finalSum & 0xFF)
        data[checksumOffset + 1] = UInt8((finalSum >> 8) & 0xFF)
        data[checksumOffset + 2] = UInt8((finalSum >> 16) & 0xFF)
        data[checksumOffset + 3] = UInt8((finalSum >> 24) & 0xFF)
    }
}
