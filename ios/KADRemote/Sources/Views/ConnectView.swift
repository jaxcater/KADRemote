import SwiftUI

struct ConnectView: View {
    @EnvironmentObject private var store: ConnectionStore

    @State private var nameInput = ""
    @State private var urlInput = ""
    @State private var tokenInput = ""
    @State private var showScanner = false
    @State private var localAlert: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
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
                        Text("Quản lý PC Windows từ xa mọi lúc mọi nơi")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 12)

                    // Quick QR Scan Button
                    Button {
                        showScanner = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Quét mã QR từ PC")
                                    .font(.headline)
                                Text("Kết nối trong 1 giây từ app Kad.exe")
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

                    // Saved PCs
                    if !store.savedPCs.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Máy tính đã lưu")
                                .font(.headline)

                            ForEach(store.savedPCs) { pc in
                                HStack {
                                    Button {
                                        Task { await store.selectPC(pc) }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "desktopcomputer")
                                                .font(.title2)
                                                .foregroundColor(.cyan)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(pc.name)
                                                    .font(.headline)
                                                    .foregroundColor(.primary)
                                                Text(pc.normalizedUrl)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
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
        }
    }
}
