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
                    hub.start()
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
