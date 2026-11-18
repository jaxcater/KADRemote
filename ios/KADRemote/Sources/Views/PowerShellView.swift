import SwiftUI

struct TerminalLine: Identifiable {
    let id = UUID()
    let kind: Kind
    let text: String

    enum Kind {
        case command, stdout, stderr, status
    }
}

struct PowerShellView: View {
    @EnvironmentObject private var store: ConnectionStore

    @State private var lines: [TerminalLine] = []
    @State private var commandInput = ""
    @State private var history: [String] = []
    @State private var historyIndex: Int = -1
    @State private var isConnected = false
    @State private var wsTask: URLSessionWebSocketTask?

    private let quickCommands = [
        "Get-Process | Sort-Object CPU -Descending | Select-Object -First 10",
        "ipconfig",
        "dir",
        "systeminfo | findstr /B /C:\"OS\" /C:\"System\"",
        "git status",
        "nvidia-smi"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Quick Commands Bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickCommands, id: \.self) { cmd in
                            Button {
                                sendCommand(cmd)
                            } label: {
                                Text(cmd.components(separatedBy: " ").first ?? cmd)
                                    .font(.caption.monospaced())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color(.secondarySystemBackground))
                                    .foregroundColor(.cyan)
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(Color.black.opacity(0.4))

                // Terminal Output
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(lines) { line in
                                Text(line.text)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundColor(colorFor(line.kind))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                        .padding(12)
                    }
                    .background(Color(red: 0.04, green: 0.06, blue: 0.09))
                    .onChange(of: lines.count) { _ in
                        if let last = lines.last {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                // Input Bar
                HStack(spacing: 8) {
                    Button {
                        stepHistory(up: true)
                    } label: {
                        Image(systemName: "arrow.up")
                            .padding(8)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                    }

                    TextField("Nhập lệnh PowerShell...", text: $commandInput)
                        .font(.system(size: 14, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.send)
                        .onSubmit {
                            submitCurrentCommand()
                        }

                    Button {
                        submitCurrentCommand()
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .padding(10)
                            .background(commandInput.isEmpty ? Color.gray.opacity(0.4) : Color.cyan)
                            .foregroundColor(.black)
                            .cornerRadius(8)
                    }
                    .disabled(commandInput.isEmpty)
                }
                .padding(10)
                .background(Color(.systemBackground))
            }
            .navigationTitle("PowerShell")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(isConnected ? "WS Live" : "Ngắt kết nối")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        sendInterrupt()
                    } label: {
                        Text("Ctrl+C")
                            .font(.caption.bold())
                            .foregroundColor(.orange)
                    }

                    Button {
                        lines.removeAll()
                    } label: {
                        Image(systemName: "trash")
                    }

                    Button {
                        connectShell()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear {
                if wsTask == nil {
                    connectShell()
                }
            }
            .onDisappear {
                disconnectShell()
            }
        }
    }

    private func colorFor(_ kind: TerminalLine.Kind) -> Color {
        switch kind {
        case .command: return .yellow
        case .stdout: return Color(red: 0.85, green: 0.95, blue: 0.88)
        case .stderr: return Color(red: 1.0, green: 0.45, blue: 0.45)
        case .status: return .cyan
        }
    }

    private func submitCurrentCommand() {
        let cmd = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        history.insert(cmd, at: 0)
        historyIndex = -1
        commandInput = ""
        sendCommand(cmd)
    }

    private func stepHistory(up: Bool) {
        guard !history.isEmpty else { return }
        if up {
            historyIndex = min(historyIndex + 1, history.count - 1)
            commandInput = history[historyIndex]
        }
    }

    private func connectShell() {
        disconnectShell()
        guard let client = store.client,
              let task = client.makeWebSocket(path: "/ws/ps") else {
            appendLine(.stderr, "Không thể tạo WebSocket tới PowerShell.")
            return
        }
        wsTask = task
        task.resume()
        isConnected = true
        receiveLoop(task)
    }

    private func disconnectShell() {
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        isConnected = false
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let message):
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let type = obj["type"] as? String ?? "stdout"
                        let payload = obj["data"] as? String ?? ""
                        let kind: TerminalLine.Kind = switch type {
                        case "stderr": .stderr
                        case "status": .status
                        default: .stdout
                        }
                        appendChunk(kind, payload)
                    }
                    self.receiveLoop(task)

                case .failure(let error):
                    self.isConnected = false
                    self.appendLine(.status, "[Đã ngắt kết nối: \(error.localizedDescription)]")
                }
            }
        }
    }

    private func sendCommand(_ cmd: String) {
        appendLine(.command, "> \(cmd)")
        if !isConnected || wsTask == nil {
            connectShell()
        }
        sendJSON(["type": "input", "data": cmd])
    }

    private func sendInterrupt() {
        sendJSON(["type": "interrupt"])
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let task = wsTask,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return }
        task.send(.string(str)) { error in
            if let error {
                DispatchQueue.main.async {
                    self.appendLine(.stderr, "Lỗi gửi lệnh: \(error.localizedDescription)")
                }
            }
        }
    }

    private func appendLine(_ kind: TerminalLine.Kind, _ text: String) {
        lines.append(TerminalLine(kind: kind, text: text))
        if lines.count > 800 {
            lines.removeFirst(lines.count - 800)
        }
    }

    private func appendChunk(_ kind: TerminalLine.Kind, _ chunk: String) {
        let split = chunk.components(separatedBy: .newlines)
        for part in split where !part.isEmpty {
            appendLine(kind, part)
        }
    }
}
