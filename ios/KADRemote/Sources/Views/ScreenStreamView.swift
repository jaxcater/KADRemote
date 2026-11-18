import SwiftUI

enum StreamPreset: String, CaseIterable, Identifiable {
    case saver = "4G Tiết kiệm"
    case balanced = "Cân bằng"
    case sharp = "Nét cao"

    var id: String { rawValue }
    var fps: Int {
        switch self {
        case .saver: return 5
        case .balanced: return 8
        case .sharp: return 12
        }
    }
    var quality: Int {
        switch self {
        case .saver: return 40
        case .balanced: return 55
        case .sharp: return 78
        }
    }
    var scale: Double {
        switch self {
        case .saver: return 0.45
        case .balanced: return 0.65
        case .sharp: return 0.85
        }
    }
}

enum TouchMouseAction: String, CaseIterable, Identifiable {
    case leftClick = "Click trái"
    case doubleClick = "Click đúp"
    case rightClick = "Chuột phải"

    var id: String { rawValue }
    var apiType: String {
        switch self {
        case .leftClick: return "click"
        case .doubleClick: return "double_click"
        case .rightClick: return "right_click"
        }
    }
}

struct ScreenStreamView: View {
    @EnvironmentObject private var store: ConnectionStore

    @State private var currentImage: UIImage?
    @State private var monitors: [MonitorInfo] = []
    @State private var selectedMonitor: Int = 0
    @State private var preset: StreamPreset = .balanced
    @State private var isStreaming = false
    @State private var controlMode = true
    @State private var mouseAction: TouchMouseAction = .leftClick

    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero

    @State private var wsTask: URLSessionWebSocketTask?
    @State private var showTypeSheet = false
    @State private var textToType = ""
    @State private var toastMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top Control Strip
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            controlMode.toggle()
                        } label: {
                            Label(controlMode ? "Điều khiển" : "Xem / Zoom",
                                  systemImage: controlMode ? "cursorarrow.click" : "magnifyingglass")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(controlMode ? Color.cyan : Color.orange)
                                .foregroundColor(.black)
                                .cornerRadius(8)
                        }

                        if controlMode {
                            Picker("Click", selection: $mouseAction) {
                                ForEach(TouchMouseAction.allCases) { act in
                                    Text(act.rawValue).tag(act)
                                }
                            }
                            .pickerStyle(.menu)
                            .padding(.horizontal, 6)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                        } else {
                            Button("Reset Zoom") {
                                withAnimation {
                                    zoomScale = 1.0
                                    lastZoomScale = 1.0
                                    panOffset = .zero
                                    lastPanOffset = .zero
                                }
                            }
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                        }

                        if monitors.count > 1 {
                            Picker("Màn hình", selection: $selectedMonitor) {
                                ForEach(monitors) { mon in
                                    Text("Màn \(mon.index + 1)").tag(mon.index)
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: selectedMonitor) { _ in
                                sendConfig()
                            }
                        }

                        Picker("Chất lượng", selection: $preset) {
                            ForEach(StreamPreset.allCases) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: preset) { _ in
                            sendConfig()
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .background(Color.black.opacity(0.45))

                // Screen Viewport
                GeometryReader { geo in
                    ZStack {
                        Color.black

                        if let img = currentImage {
                            screenImageView(img: img, containerSize: geo.size)
                        } else {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text(isStreaming ? "Đang nhận hình ảnh từ PC..." : "Đã tạm dừng stream")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }

                        if let toast = toastMessage {
                            VStack {
                                Text(toast)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(.black.opacity(0.75))
                                    .foregroundColor(.cyan)
                                    .cornerRadius(8)
                                    .padding(.top, 10)
                                Spacer()
                            }
                        }
                    }
                    .clipped()
                }

                // Bottom Keyboard & Hotkeys Bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            showTypeSheet = true
                        } label: {
                            Label("Gõ chữ", systemImage: "keyboard")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.cyan.opacity(0.2))
                                .foregroundColor(.cyan)
                                .cornerRadius(8)
                        }

                        HotkeyChip(title: "Cuộn ↑") {
                            sendInput(["type": "scroll", "monitor": selectedMonitor, "x": 0.5, "y": 0.5, "delta": 240])
                        }
                        HotkeyChip(title: "Cuộn ↓") {
                            sendInput(["type": "scroll", "monitor": selectedMonitor, "x": 0.5, "y": 0.5, "delta": -240])
                        }
                        HotkeyChip(title: "Enter") { sendHotkey(["enter"]) }
                        HotkeyChip(title: "Esc") { sendHotkey(["esc"]) }
                        HotkeyChip(title: "Tab") { sendHotkey(["tab"]) }
                        HotkeyChip(title: "Ctrl+C") { sendHotkey(["ctrl", "c"]) }
                        HotkeyChip(title: "Alt+F4") { sendHotkey(["alt", "f4"]) }
                        HotkeyChip(title: "Win+D") { sendHotkey(["win", "d"]) }
                        HotkeyChip(title: "TaskMgr") { sendHotkey(["ctrl", "shift", "esc"]) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .background(Color(.systemBackground))
            }
            .navigationTitle("Màn hình PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        if let img = currentImage {
                            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                            showToast("Đã lưu ảnh màn hình vào Thư viện!")
                        }
                    } label: {
                        Image(systemName: "camera.viewfinder")
                    }
                    .disabled(currentImage == nil)

                    Button {
                        if isStreaming {
                            stopStream()
                        } else {
                            startStream()
                        }
                    } label: {
                        Image(systemName: isStreaming ? "pause.fill" : "play.fill")
                    }
                }
            }
            .onAppear {
                loadMonitors()
                startStream()
            }
            .onDisappear {
                stopStream()
            }
            .sheet(isPresented: $showTypeSheet) {
                NavigationStack {
                    VStack(spacing: 16) {
                        TextField("Nhập nội dung muốn gõ lên PC...", text: $textToType, axis: .vertical)
                            .lineLimit(3...6)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            if !textToType.isEmpty {
                                sendInput(["type": "text", "text": textToType])
                                textToType = ""
                                showTypeSheet = false
                            }
                        } label: {
                            Text("Gửi lên PC")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.cyan)
                                .foregroundColor(.black)
                                .cornerRadius(10)
                        }
                        Spacer()
                    }
                    .padding()
                    .navigationTitle("Gõ bàn phím từ xa")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Đóng") { showTypeSheet = false }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }

    @ViewBuilder
    private func screenImageView(img: UIImage, containerSize: CGSize) -> some View {
        let base = Image(uiImage: img)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: containerSize.width, height: containerSize.height)
            .scaleEffect(zoomScale)
            .offset(panOffset)
            .contentShape(Rectangle())

        if controlMode {
            base.gesture(
                SpatialTapGesture(coordinateSpace: .local)
                    .onEnded { value in
                        handleTap(at: value.location, in: containerSize, imageSize: img.size)
                    }
            )
        } else {
            base.gesture(
                MagnificationGesture()
                    .onChanged { val in
                        zoomScale = max(1.0, min(5.0, lastZoomScale * val))
                    }
                    .onEnded { _ in
                        lastZoomScale = zoomScale
                    }
                    .simultaneously(with:
                        DragGesture()
                            .onChanged { val in
                                panOffset = CGSize(
                                    width: lastPanOffset.width + val.translation.width,
                                    height: lastPanOffset.height + val.translation.height
                                )
                            }
                            .onEnded { _ in
                                lastPanOffset = panOffset
                            }
                    )
            )
        }
    }

    private func handleTap(at point: CGPoint, in container: CGSize, imageSize: CGSize) {
        guard container.width > 0, container.height > 0, imageSize.width > 0, imageSize.height > 0 else { return }

        // Convert container coordinates accounting for zoom & pan
        let centerX = container.width / 2.0
        let centerY = container.height / 2.0
        let unscaledX = (point.x - centerX - panOffset.width) / zoomScale + centerX
        let unscaledY = (point.y - centerY - panOffset.height) / zoomScale + centerY

        // Calculate fitted image rect inside container
        let imgAspect = imageSize.width / imageSize.height
        let boxAspect = container.width / container.height

        let fittedWidth: CGFloat
        let fittedHeight: CGFloat
        if imgAspect > boxAspect {
            fittedWidth = container.width
            fittedHeight = container.width / imgAspect
        } else {
            fittedHeight = container.height
            fittedWidth = container.height * imgAspect
        }

        let originX = (container.width - fittedWidth) / 2.0
        let originY = (container.height - fittedHeight) / 2.0

        let normX = (unscaledX - originX) / fittedWidth
        let normY = (unscaledY - originY) / fittedHeight

        guard normX >= 0, normX <= 1, normY >= 0, normY <= 1 else { return }

        sendInput([
            "type": mouseAction.apiType,
            "monitor": selectedMonitor,
            "x": Double(normX),
            "y": Double(normY)
        ])
        showToast(mouseAction.rawValue)
    }

    private func loadMonitors() {
        Task {
            if let list = try? await store.client?.getMonitors() {
                monitors = list
                if let primary = list.first(where: { $0.isPrimary }) {
                    selectedMonitor = primary.index
                }
            }
        }
    }

    private func startStream() {
        stopStream()
        guard let client = store.client,
              let task = client.makeWebSocket(
                path: "/ws/screen",
                queryItems: [
                    URLQueryItem(name: "monitor", value: "\(selectedMonitor)"),
                    URLQueryItem(name: "fps", value: "\(preset.fps)"),
                    URLQueryItem(name: "quality", value: "\(preset.quality)"),
                    URLQueryItem(name: "scale", value: "\(preset.scale)")
                ]
              ) else { return }

        wsTask = task
        isStreaming = true
        task.resume()
        receiveFrame(task)
    }

    private func stopStream() {
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        isStreaming = false
    }

    private func receiveFrame(_ task: URLSessionWebSocketTask) {
        task.receive { result in
            switch result {
            case .success(let message):
                if case .data(let data) = message, let img = UIImage(data: data) {
                    DispatchQueue.main.async {
                        self.currentImage = img
                    }
                }
                self.receiveFrame(task)

            case .failure:
                DispatchQueue.main.async {
                    self.isStreaming = false
                }
            }
        }
    }

    private func sendConfig() {
        sendInput([
            "type": "config",
            "monitor": selectedMonitor,
            "fps": preset.fps,
            "quality": preset.quality,
            "scale": preset.scale
        ])
    }

    private func sendHotkey(_ keys: [String]) {
        sendInput(["type": "hotkey", "keys": keys])
        showToast(keys.joined(separator: "+").uppercased())
    }

    private func sendInput(_ dict: [String: Any]) {
        guard let task = wsTask,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return }
        task.send(.string(str)) { _ in }
    }

    private func showToast(_ msg: String) {
        toastMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if toastMessage == msg {
                toastMessage = nil
            }
        }
    }
}

private struct HotkeyChip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.monospaced().bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(.secondarySystemBackground))
                .foregroundColor(.primary)
                .cornerRadius(8)
        }
    }
}
