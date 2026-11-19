import SwiftUI

struct ExportConfigSheet: View {
    @EnvironmentObject private var hub: AgentHubServer
    @Environment(\.dismiss) private var dismiss

    @State private var detectedIPs: [NetworkUtils.InterfaceAddress] = []
    @State private var controllerHost: String = ""
    @State private var hubPortText: String = "7789"
    @State private var agentPortText: String = "7788"
    @State private var startWithWindows: Bool = true
    @State private var udpDiscovery: Bool = true
    @State private var enableCloudflareTunnel: Bool = true
    @State private var enableCloudSync: Bool = true
    @State private var cloudflareTunnelToken: String = ""
    @State private var cloudflareTunnelUrl: String = ""

    @State private var isBuilding: Bool = false
    @State private var exportedURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tạo Kad.exe cấu hình sẵn cho Windows 10/11")
                            .font(.subheadline.bold())
                            .foregroundColor(.cyan)
                        Text("File Kad.exe chạy ẩn hoàn toàn (không Tray/Taskbar, tự chạy khi khởi động lại), tự động đồng bộ link Cloudflare Tunnel để bạn điều khiển cả khi đi ra ngoài dùng 4G / mạng khác.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Địa chỉ iPhone (LAN / VPN)") {
                    TextField("IP / Host của iPhone (VD: 192.168.1.50)", text: $controllerHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    if !detectedIPs.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(detectedIPs) { item in
                                    Button {
                                        controllerHost = item.ip
                                    } label: {
                                        Text(item.label)
                                            .font(.caption.monospaced())
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(controllerHost == item.ip ? Color.cyan : Color(.tertiarySystemBackground))
                                            .foregroundColor(controllerHost == item.ip ? .black : .primary)
                                            .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    HStack {
                        Text("Cổng Hub (iPhone)")
                        Spacer()
                        TextField("7789", text: $hubPortText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }

                    HStack {
                        Text("Cổng Agent (Windows)")
                        Spacer()
                        TextField("7788", text: $agentPortText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                }

                Section("Truy cập từ xa khác mạng (Cloudflare Tunnel)") {
                    Toggle("Bật Cloudflare Tunnel (4G / Khác Wi-Fi)", isOn: $enableCloudflareTunnel)
                        .tint(.cyan)

                    if enableCloudflareTunnel {
                        Text("Mặc định dùng Quick Tunnel miễn phí (tự tạo link https://*.trycloudflare.com và đồng bộ về iPhone, không cần tài khoản).")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        DisclosureGroup("Named Tunnel cố định (Tùy chọn)") {
                            TextField("Cloudflare Tunnel Token (để trống nếu dùng miễn phí)", text: $cloudflareTunnelToken)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Domain cố định (VD: https://srv1.domain.com)", text: $cloudflareTunnelUrl)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                        }
                        .font(.subheadline)
                    }
                }

                Section("Bảo mật & Tự động") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Token ghép nối")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(hub.controllerToken)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Đổi mới") {
                            hub.regenerateToken()
                        }
                        .font(.caption.bold())
                    }

                    Toggle("Tự khởi động cùng Windows", isOn: $startWithWindows)
                    Toggle("Tự tìm iPhone qua LAN (UDP)", isOn: $udpDiscovery)
                    Toggle("Tự nhận Server qua Cloud (mã hóa E2E)", isOn: $enableCloudSync)
                        .tint(.cyan)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                Section {
                    Button {
                        exportExe()
                    } label: {
                        HStack {
                            Spacer()
                            if isBuilding {
                                ProgressView()
                                    .padding(.trailing, 6)
                            } else {
                                Image(systemName: "square.and.arrow.up.on.square")
                            }
                            Text(isBuilding ? "Đang đóng gói Kad.exe..." : "Xuất file Kad.exe")
                                .fontWeight(.bold)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .disabled(isBuilding)
                } footer: {
                    if !ExeBuilder.hasTemplate {
                        Text("Lưu ý: Template KadAgentTemplate.exe chưa được nhúng (chỉ có trong bản build CI/Release).")
                            .foregroundColor(.orange)
                    }
                }
            }
            .navigationTitle("Xuất cấu hình")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Đóng") { dismiss() }
                }
            }
            .onAppear {
                hub.ensureRunning()
                detectedIPs = NetworkUtils.getLocalIPAddresses()
                if controllerHost.isEmpty {
                    controllerHost = detectedIPs.first?.ip ?? ""
                }
                hubPortText = "\(hub.hubPort)"
                agentPortText = "\(hub.defaultAgentPort)"
            }
            .sheet(isPresented: Binding(
                get: { exportedURL != nil },
                set: {
                    if !$0 {
                        exportedURL = nil
                        hub.ensureRunning()
                    }
                }
            )) {
                if let url = exportedURL {
                    ExportShareSheet(activityItems: [url])
                }
            }
        }
    }

    private func exportExe() {
        errorMessage = nil
        let hubPort = Int(hubPortText.trimmingCharacters(in: .whitespaces)) ?? 7789
        let agentPort = Int(agentPortText.trimmingCharacters(in: .whitespaces)) ?? 7788

        guard (1024...65535).contains(hubPort), (1024...65535).contains(agentPort) else {
            errorMessage = "Cổng phải nằm trong khoảng 1024 - 65535."
            return
        }

        let cleanHost = controllerHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHost.isEmpty && !udpDiscovery && !enableCloudSync {
            errorMessage = "Hãy nhập IP của iPhone hoặc bật Tự tìm qua LAN / Cloud."
            return
        }

        var allHosts: [String] = []
        if !cleanHost.isEmpty {
            allHosts.append(cleanHost)
        }
        for item in detectedIPs {
            if !allHosts.contains(item.ip) {
                allHosts.append(item.ip)
            }
        }

        let cleanCfToken = cloudflareTunnelToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCfUrl = cloudflareTunnelUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if enableCloudflareTunnel && !cleanCfToken.isEmpty && cleanCfUrl.isEmpty {
            errorMessage = "Khi dùng Named Tunnel Token, hãy nhập Domain cố định tương ứng."
            return
        }

        hub.updatePorts(hub: hubPort, agent: agentPort)
        hub.ensureRunning()
        isBuilding = true

        let cfg = AgentExportConfig(
            controllerHost: cleanHost,
            controllerHosts: allHosts,
            controllerPort: hubPort,
            controllerToken: hub.controllerToken,
            agentPort: agentPort,
            startWithWindows: startWithWindows,
            udpDiscovery: udpDiscovery,
            enableCloudflareTunnel: enableCloudflareTunnel,
            enableCloudSync: enableCloudSync,
            cloudflareTunnelToken: cleanCfToken.isEmpty ? nil : cleanCfToken,
            cloudflareTunnelUrl: cleanCfUrl.isEmpty ? nil : cleanCfUrl,
            exportedBy: UIDevice.current.name,
            exportedAt: ISO8601DateFormatter().string(from: Date())
        )

        Task.detached(priority: .userInitiated) {
            do {
                let url = try ExeBuilder.buildConfiguredExe(config: cfg)
                await MainActor.run {
                    isBuilding = false
                    exportedURL = url
                }
            } catch {
                await MainActor.run {
                    isBuilding = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct ExportShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
