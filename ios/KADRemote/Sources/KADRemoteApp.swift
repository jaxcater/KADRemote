import SwiftUI

@main
struct KADRemoteApp: App {
    @StateObject private var store = ConnectionStore()

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
            .preferredColorScheme(.dark)
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
