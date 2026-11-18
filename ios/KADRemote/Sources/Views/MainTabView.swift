import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Tổng quan", systemImage: "cpu")
                }

            ScreenStreamView()
                .tabItem {
                    Label("Màn hình", systemImage: "display")
                }

            PowerShellView()
                .tabItem {
                    Label("PowerShell", systemImage: "terminal")
                }

            FilesView()
                .tabItem {
                    Label("Tập tin", systemImage: "folder")
                }
        }
        .tint(.cyan)
    }
}
