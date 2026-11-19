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
            Group {
                if store.isConnected, store.activePC != nil {
                    MainTabView()
                } else {
                    ConnectView()
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
                    primaryButton: .default(Text("Đã hiểu")) {
                        store.acknowledgeExePopup(for: alert.id)
                    },
                    secondaryButton: .destructive(Text("Xóa cảnh báo")) {
                        store.dismissExeAlert(for: alert.id)
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
