import SwiftUI

struct ConnectView: View {
    @EnvironmentObject private var store: ConnectionStore
    @EnvironmentObject private var hub: AgentHubServer
    @EnvironmentObject private var backgroundManager: BackgroundManager

    @State private var nameInput = ""
    @State private var urlInput = ""
    @State private var tokenInput = ""
    @State private var showScanner = false
    @State private var showExportConfig = false
    @State private var localAlert: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Brand Hero
                    VStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20)
                                .fill(
                                    LinearGradient(
                                        colors: [Color(red: 0.05, green: 0.65, blue: 0.91), Color(red: 0.15, green: 0.39, blue: 0.92)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 72, height: 72)
                            Text("K")
                                .font(.system(size: 40, weight: .bold))
                                .foregroundColor(.white)
                        }
                        Text("KAD Remote")
                            .font(.largeTitle.bold())
                        Text("Quản lý PC & hàng loạt Windows Server từ xa")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 8)

                    // Quick Action 1: QR Scan
                    Button {
                        showScanner = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Quét mã QR từ PC")
                                    .font(.headline)
                                Text("Kết nối nhanh 1 máy từ Kad.exe GUI")
                                    .font(.caption)
                                    .opacity(0.85)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.cyan.opacity(0.18))
                        .foregroundColor(.cyan)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.cyan.opacity(0.5), lineWidth: 1)
                        )
                        .cornerRadius(14)
                    }

                    // Quick Action 2: Export Pre-configured Kad.exe
                    Button {
                        showExportConfig = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Xuất cấu hình (Tạo Kad.exe)")
                                    .font(.headline)
                                Text("Cài vào nhiều Windows Server — tự kết nối về máy này")
                                    .font(.caption)
                                    .opacity(0.85)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue.opacity(0.2))
                        .foregroundColor(.blue)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.blue.opacity(0.5), lineWidth: 1)
                        )
                        .cornerRadius(14)
                    }

                    // Background Mode & Hub Listener Card
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: Binding(
                            get: { backgroundManager.isBackgroundEnabled },
                            set: { backgroundManager.setEnabled($0) }
                        )) {
                            HStack(spacing: 10) {
                                Image(systemName: backgroundManager.isBackgroundEnabled ? "bolt.shield.fill" : "moon.zzz.fill")
                                    .font(.title3)
                                    .foregroundColor(backgroundManager.isBackgroundEnabled ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Chạy nền khi thoát ứng dụng")
                                        .font(.subheadline.weight(.semibold))
                                    Text(backgroundManager.isBackgroundEnabled
                                         ? "Đang bật — giữ Hub lắng nghe & kết nối server"
                                         : "Cho phép giữ kết nối Windows Server ở chế độ nền")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .tint(.green)

                        Divider()

                        HStack(spacing: 8) {
                            Circle()
                                .fill(hub.isListening ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(hub.listenerStatus)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(hub.onlineAgents.count) online")
                                .font(.caption.bold())
                                .foregroundColor(hub.onlineAgents.isEmpty ? .secondary : .green)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(14)

                    // Saved PCs / Auto-connected Servers
                    if !store.savedPCs.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Máy tính & Server (\(store.savedPCs.count))")
                                    .font(.headline)
                                Spacer()
                                Button {
                                    Task { await store.refreshRemoteStatuses() }
                                } label: {
                                    if store.isRefreshingStatuses {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                    } else {
                                        Label("Kiểm tra", systemImage: "arrow.clockwise")
                                            .font(.caption.weight(.semibold))
                                            .foregroundColor(.cyan)
                                    }
                                }
                            }

                            ForEach(store.savedPCs) { pc in
                                let live = store.liveStatus(for: pc)
                                let isOnline = store.isAgentOnline(pc)
                                let viaTunnel = store.isUsingTunnel(pc)

                                HStack {
                                    Button {
                                        Task { await store.selectPC(pc) }
                                    } label: {
                                        HStack(spacing: 12) {
                                            ZStack(alignment: .bottomTrailing) {
                                                Image(systemName: pc.isAutoDiscovered == true ? "server.rack" : "desktopcomputer")
                                                    .font(.title2)
                                                    .foregroundColor(isOnline ? (viaTunnel ? .cyan : .green) : .cyan)
                                                Circle()
                                                    .fill(isOnline ? (viaTunnel ? Color.cyan : Color.green) : Color.gray)
                                                    .frame(width: 9, height: 9)
                                                    .offset(x: 2, y: 2)
                                            }
                                            VStack(alignment: .leading, spacing: 2) {
                                                HStack(spacing: 6) {
                                                    Text(pc.name)
                                                        .font(.headline)
                                                        .foregroundColor(.primary)
                                                    if isOnline {
                                                        Text(viaTunnel ? "TUNNEL 4G" : "LAN")
                                                            .font(.system(size: 9, weight: .bold))
                                                            .padding(.horizontal, 5)
                                                            .padding(.vertical, 2)
                                                            .background((viaTunnel ? Color.cyan : Color.green).opacity(0.2))
                                                            .foregroundColor(viaTunnel ? .cyan : .green)
                                                            .cornerRadius(4)
                                                    } else if pc.normalizedTunnelUrl != nil {
                                                        Text("4G SẴN SÀNG")
                                                            .font(.system(size: 9, weight: .bold))
                                                            .padding(.horizontal, 5)
                                                            .padding(.vertical, 2)
                                                            .background(Color.blue.opacity(0.2))
                                                            .foregroundColor(.blue)
                                                            .cornerRadius(4)
                                                    }
                                                }
                                                if let live {
                                                    Text("CPU \(String(format: "%.0f", live.cpuUsagePercent))% • RAM \(ByteFormatter.format(live.usedMemoryBytes))/\(ByteFormatter.format(live.totalMemoryBytes))")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                        .lineLimit(1)
                                                } else if let tunnel = pc.normalizedTunnelUrl {
                                                    Text(viaTunnel ? tunnel : "\(pc.normalizedUrl) • \(tunnel)")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                        .lineLimit(1)
                                                } else {
                                                    Text(pc.normalizedUrl)
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                        .lineLimit(1)
                                                }
                                            }
                                            Spacer()
                                            if store.isConnecting && store.activePC?.id == pc.id {
                                                ProgressView()
                                            } else {
                                                Text("Kết nối")
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundColor(.cyan)
                                            }
                                        }
                                    }

                                    Button(role: .destructive) {
                                        store.deletePC(pc)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red.opacity(0.8))
                                            .padding(.leading, 8)
                                    }
                                }
                                .padding()
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(12)
                            }
                        }
                    }

                    // Manual Connect Card
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Thêm / Kết nối thủ công")
                            .font(.headline)

                        TextField("Tên PC (VD: PC Ở Nhà)", text: $nameInput)
                            .textFieldStyle(.roundedBorder)

                        TextField("URL (https://xxxx.trycloudflare.com hoặc http://IP:7788)", text: $urlInput)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)

                        SecureField("Access Token", text: $tokenInput)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        if let err = store.errorMessage ?? localAlert {
                            Text(err)
                                .font(.footnote)
                                .foregroundColor(.red)
                        }

                        Button {
                            Task {
                                _ = await store.connectAndSave(name: nameInput, url: urlInput, token: tokenInput)
                            }
                        } label: {
                            HStack {
                                if store.isConnecting {
                                    ProgressView()
                                        .tint(.white)
                                }
                                Text(store.isConnecting ? "Đang kết nối..." : "Kết nối & Lưu PC")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(urlInput.isEmpty || tokenInput.isEmpty ? Color.gray.opacity(0.4) : Color.cyan)
                            .foregroundColor(.black)
                            .cornerRadius(10)
                        }
                        .disabled(urlInput.isEmpty || tokenInput.isEmpty || store.isConnecting)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(14)
                }
                .padding()
            }
            .navigationTitle("Kết nối")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await store.refreshRemoteStatuses()
            }
            .task {
                await store.refreshRemoteStatuses()
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { raw in
                    if let parsed = store.handleQRString(raw) {
                        nameInput = parsed.name
                        urlInput = parsed.url
                        tokenInput = parsed.token
                        Task {
                            _ = await store.connectAndSave(name: parsed.name, url: parsed.url, token: parsed.token)
                        }
                    } else {
                        localAlert = "Mã QR không phải của KAD Remote."
                    }
                }
            }
            .sheet(isPresented: $showExportConfig) {
                ExportConfigSheet()
                    .environmentObject(hub)
            }
        }
    }
}
