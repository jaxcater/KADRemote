import SwiftUI

@main
struct KADRemoteApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = ConnectionStore()
    @StateObject private var hub = AgentHubServer()
    @StateObject private var backgroundManager = BackgroundManager()
    @State private var didBootstrap = false

    init() {
        BackgroundManager.registerBackgroundTasks {
            // Keep background schedule alive
        }
    }

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                if !store.exeMissingAlerts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.white)
                            Text("MẤT FILE KAD.EXE (\(store.exeMissingAlerts.count) máy)")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                            Spacer()
                            Button {
                                store.clearAllExeAlerts()
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Đóng")
                                        .font(.caption2.bold())
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .foregroundColor(.white.opacity(0.9))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.25))
                                .cornerRadius(6)
                            }
                        }
                        if let first = store.exeMissingAlerts.values.sorted(by: { $0.detectedAt > $1.detectedAt }).first {
                            Text("\(first.serverName): \(first.message)")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.95))
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red)
                }

                Group {
                    if store.isConnected, store.activePC != nil {
                        MainTabView()
                    } else {
                        ConnectView()
                    }
                }
            }
            .environmentObject(store)
            .environmentObject(hub)
            .environmentObject(backgroundManager)
            .preferredColorScheme(.dark)
            .alert(item: $store.latestExePopupAlert) { alert in
                Alert(
                    title: Text("⚠️ Mất file Kad.exe — \(alert.serverName)"),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Đóng")) {
                        store.dismissExeAlert(for: alert.id)
                    },
                    secondaryButton: .destructive(Text("Xóa cảnh báo")) {
                        store.clearAllExeAlerts()
                    }
                )
            }
            .onAppear {
                if !didBootstrap {
                    didBootstrap = true
                    store.attach(hub: hub, backgroundManager: backgroundManager)
                    hub.start()
                }
            }
            .onChange(of: scenePhase) { newPhase in
                let proxy: ScenePhaseProxy = switch newPhase {
                case .active: .active
                case .inactive: .inactive
                case .background: .background
                @unknown default: .inactive
                }
                if proxy == .background && !store.exeMissingAlerts.isEmpty {
                    backgroundManager.scheduleBackgroundSpamBurst(alerts: Array(store.exeMissingAlerts.values))
                }
                backgroundManager.handleScenePhase(proxy) {
                    hub.ensureRunning()
                    Task {
                        await store.discoverAgents(includeSubnetScan: false)
                    }
                }
            }
            .onOpenURL { url in
                if let parsed = store.parseDeepLink(url) {
                    Task {
                        _ = await store.connectAndSave(name: parsed.name, url: parsed.url, token: parsed.token)
                    }
                }
            }
        }
    }
}
