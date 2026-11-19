import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: ConnectionStore
    @EnvironmentObject private var backgroundManager: BackgroundManager
    @EnvironmentObject private var hub: AgentHubServer

    @State private var info: SystemInfo?
    @State private var isLoading = false
    @State private var statusBanner: String?
    @State private var pendingPowerAction: (action: String, title: String)?
    @State private var showProcesses = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !store.exeMissingAlerts.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text("Cảnh báo mất file Kad.exe (\(store.exeMissingAlerts.count) Server)")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.red)
                                Spacer()
                                Button("Ẩn") {
                                    store.clearAllExeAlerts()
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            ForEach(Array(store.exeMissingAlerts.values)) { alert in
                                Text("• \(alert.serverName): \(alert.message)")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.red.opacity(0.6), lineWidth: 1)
                        )
                        .cornerRadius(10)
                    }

                    if let banner = statusBanner {
                        Text(banner)
                            .font(.subheadline)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.cyan.opacity(0.16))
                            .foregroundColor(.cyan)
                            .cornerRadius(10)
                    }

                    if let info {
                        // Header PC Card
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                    .font(.title2)
                                    .foregroundColor(.cyan)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(info.deviceName)
                                        .font(.title3.bold())
                                    Text("\(info.userName) • \(info.monitorCount) màn hình")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Label("Online", systemImage: "circle.fill")
                                    .font(.caption.bold())
                                    .foregroundColor(.green)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.green.opacity(0.15))
                                    .cornerRadius(12)
                            }

                            Divider()

                            HStack {
                                Label("Uptime: \(ByteFormatter.formatUptime(info.uptimeSeconds))", systemImage: "clock")
                                Spacer()
                                Text(info.tunnelUrl != nil ? "Tunnel 4G" : "LAN")
                                    .foregroundColor(.cyan)
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(14)

                        // CPU & RAM Cards
                        HStack(spacing: 12) {
                            MetricCard(
                                title: "CPU",
                                value: String(format: "%.1f%%", info.cpuUsagePercent),
                                progress: info.cpuUsagePercent / 100.0,
                                color: info.cpuUsagePercent > 85 ? .red : .cyan
                            )

                            MetricCard(
                                title: "RAM",
                                value: "\(ByteFormatter.format(info.usedMemoryBytes)) / \(ByteFormatter.format(info.totalMemoryBytes))",
                                progress: info.memoryRatio,
                                color: info.memoryRatio > 0.85 ? .orange : .blue
                            )
                        }

                        // Disks
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Ổ đĩa")
                                .font(.headline)

                            ForEach(info.disks) { disk in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("\(disk.name) (\(disk.label))")
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        Text("Trống \(ByteFormatter.format(disk.freeBytes)) / \(ByteFormatter.format(disk.totalBytes))")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    ProgressView(value: disk.usedRatio)
                                        .tint(disk.usedRatio > 0.9 ? .red : .cyan)
                                }
                                .padding()
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(12)
                            }
                        }

                        // Task Manager Button
                        Button {
                            showProcesses = true
                        } label: {
                            HStack {
                                Image(systemName: "list.bullet.rectangle")
                                Text("Quản lý tiến trình (Task Manager)")
                                    .fontWeight(.semibold)
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .foregroundColor(.primary)
                            .cornerRadius(12)
                        }

                        // Background Mode Toggle
                        Toggle(isOn: Binding(
                            get: { backgroundManager.isBackgroundEnabled },
                            set: { backgroundManager.setEnabled($0) }
                        )) {
                            HStack(spacing: 10) {
                                Image(systemName: backgroundManager.isBackgroundEnabled ? "bolt.shield.fill" : "moon.zzz.fill")
                                    .foregroundColor(backgroundManager.isBackgroundEnabled ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Chạy nền (Background Mode)")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Hub :\(hub.hubPort) • \(hub.onlineAgents.count) server đang kết nối")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .tint(.green)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)

                        // Power Controls
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Điều khiển nguồn PC")
                                .font(.headline)

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                PowerButton(title: "Khóa màn hình", icon: "lock.fill", color: .cyan) {
                                    pendingPowerAction = ("lock", "Khóa màn hình PC?")
                                }
                                PowerButton(title: "Ngủ (Sleep)", icon: "moon.fill", color: .indigo) {
                                    pendingPowerAction = ("sleep", "Đưa PC vào chế độ ngủ?")
                                }
                                PowerButton(title: "Khởi động lại", icon: "arrow.clockwise", color: .orange) {
                                    pendingPowerAction = ("restart", "Khởi động lại PC sau 5 giây?")
                                }
                                PowerButton(title: "Tắt máy", icon: "power", color: .red) {
                                    pendingPowerAction = ("shutdown", "Tắt PC sau 5 giây?")
                                }
                            }

                            Button {
                                Task { await runPower("cancel_shutdown") }
                            } label: {
                                Text("Hủy lệnh tắt / khởi động lại")
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color(.secondarySystemBackground))
                                    .foregroundColor(.secondary)
                                    .cornerRadius(10)
                            }
                        }
                    } else if isLoading {
                        ProgressView("Đang tải thông tin PC...")
                            .padding(.top, 60)
                    }
                }
                .padding()
            }
            .navigationTitle(store.activePC?.name ?? "Tổng quan")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        store.disconnect()
                    } label: {
                        Label("Đổi PC", systemImage: "arrow.left.arrow.right")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadInfo() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .refreshable {
                await loadInfo()
            }
            .task {
                await loadInfo()
            }
            .sheet(isPresented: $showProcesses) {
                ProcessListSheet()
            }
            .confirmationDialog(
                pendingPowerAction?.title ?? "Xác nhận",
                isPresented: Binding(
                    get: { pendingPowerAction != nil },
                    set: { if !$0 { pendingPowerAction = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Thực hiện", role: .destructive) {
                    if let action = pendingPowerAction?.action {
                        Task { await runPower(action) }
                    }
                }
                Button("Hủy", role: .cancel) {}
            }
        }
    }

    private func loadInfo() async {
        guard let client = store.client else { return }
        isLoading = true
        do {
            let loaded = try await client.getSystemInfo()
            info = loaded
            if let pcId = store.activePC?.id {
                store.updatePCMetadata(from: loaded, for: pcId)
            }
        } catch {
            statusBanner = error.localizedDescription
        }
        isLoading = false
    }

    private func runPower(_ action: String) async {
        guard let client = store.client else { return }
        do {
            let resp = try await client.powerAction(action)
            statusBanner = resp.message ?? "Đã gửi lệnh."
        } catch {
            statusBanner = error.localizedDescription
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let progress: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            ProgressView(value: min(max(progress, 0), 1))
                .tint(color)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

private struct PowerButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(color.opacity(0.16))
            .foregroundColor(color)
            .cornerRadius(10)
        }
    }
}

private struct ProcessListSheet: View {
    @EnvironmentObject private var store: ConnectionStore
    @Environment(\.dismiss) private var dismiss

    @State private var processes: [ProcessItem] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var feedback: String?

    var filtered: [ProcessItem] {
        if searchText.isEmpty { return processes }
        return processes.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.windowTitle.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let feedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundColor(.cyan)
                }

                ForEach(filtered) { proc in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(proc.name)
                                .font(.headline)
                            if !proc.windowTitle.isEmpty {
                                Text(proc.windowTitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Text("PID: \(proc.pid) • RAM: \(ByteFormatter.format(proc.memoryBytes))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Tắt", role: .destructive) {
                            Task { await killProc(proc.pid) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Tìm ứng dụng / tiến trình")
            .navigationTitle("Tiến trình PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Đóng") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task {
                await load()
            }
        }
    }

    private func load() async {
        guard let client = store.client else { return }
        isLoading = true
        if let list = try? await client.getProcesses() {
            processes = list
        }
        isLoading = false
    }

    private func killProc(_ pid: Int) async {
        guard let client = store.client else { return }
        do {
            let res = try await client.killProcess(pid: pid)
            feedback = res.message
            await load()
        } catch {
            feedback = error.localizedDescription
        }
    }
}
