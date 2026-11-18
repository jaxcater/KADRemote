import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct FilesView: View {
    @EnvironmentObject private var store: ConnectionStore

    @State private var currentPath = ""
    @State private var parentPath: String?
    @State private var entries: [FileEntry] = []
    @State private var shortcuts: [QuickShortcut] = []
    @State private var drives: [DiskInfo] = []

    @State private var searchText = ""
    @State private var isLoading = false
    @State private var isTransferring = false
    @State private var transferStatus = ""

    @State private var selectedFile: FileEntry?
    @State private var showFileImporter = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showPhotosPicker = false

    @State private var showMkdirAlert = false
    @State private var newFolderName = ""

    @State private var renameTarget: FileEntry?
    @State private var renameInput = ""

    @State private var runTarget: FileEntry?
    @State private var runArgs = ""
    @State private var runAsAdmin = false
    @State private var runWaitForExit = false
    @State private var runResultText: String?

    @State private var shareFileURL: URL?
    @State private var errorAlert: String?

    var filteredEntries: [FileEntry] {
        if searchText.isEmpty { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Quick Shortcuts & Drives Strip
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shortcuts) { sc in
                            Button {
                                Task { await loadDirectory(sc.path) }
                            } label: {
                                Label(sc.name, systemImage: "folder.fill")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(currentPath == sc.path ? Color.cyan : Color(.secondarySystemBackground))
                                    .foregroundColor(currentPath == sc.path ? .black : .primary)
                                    .cornerRadius(8)
                            }
                        }

                        ForEach(drives) { drv in
                            Button {
                                Task { await loadDirectory(drv.name) }
                            } label: {
                                Label(drv.name, systemImage: "internaldrive.fill")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color(.secondarySystemBackground))
                                    .foregroundColor(.cyan)
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(Color.black.opacity(0.35))

                // Current Path Bar
                HStack(spacing: 8) {
                    if let parent = parentPath {
                        Button {
                            Task { await loadDirectory(parent) }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title3)
                                .foregroundColor(.cyan)
                        }
                    }

                    Text(currentPath.isEmpty ? "Đang tải..." : currentPath)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground).opacity(0.5))

                if isTransferring {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(transferStatus)
                            .font(.caption)
                            .foregroundColor(.cyan)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.cyan.opacity(0.12))
                }

                // Entries List
                List {
                    ForEach(filteredEntries) { entry in
                        Button {
                            if entry.isDirectory {
                                Task { await loadDirectory(entry.fullPath) }
                            } else {
                                selectedFile = entry
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: iconFor(entry))
                                    .font(.title3)
                                    .foregroundColor(entry.isDirectory ? .cyan : (isRunnable(entry) ? .green : .secondary))
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    if !entry.isDirectory {
                                        Text(ByteFormatter.format(entry.sizeBytes))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if entry.isDirectory {
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await deleteItem(entry) }
                            } label: {
                                Label("Xóa", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $searchText, prompt: "Tìm tập tin / thư mục")
                .refreshable {
                    await loadDirectory(currentPath.isEmpty ? nil : currentPath)
                }
            }
            .navigationTitle("Tập tin PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        newFolderName = ""
                        showMkdirAlert = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }

                    Menu {
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("Gửi file từ Tệp (Files)", systemImage: "doc.badge.plus")
                        }

                        Button {
                            showPhotosPicker = true
                        } label: {
                            Label("Gửi ảnh / video từ Thư viện", systemImage: "photo.on.rectangle")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .task {
                await loadRoots()
                await loadDirectory(nil)
            }
            // Upload from Files app
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task { await uploadLocalFile(url) }
                }
            }
            // Upload from Photos
            .photosPicker(isPresented: $showPhotosPicker, selection: $selectedPhotoItem, matching: .any(of: [.images, .videos]))
            .onChange(of: selectedPhotoItem) { newItem in
                guard let newItem else { return }
                Task { await uploadPhotoItem(newItem) }
            }
            // File Actions Dialog
            .confirmationDialog(
                selectedFile?.name ?? "",
                isPresented: Binding(
                    get: { selectedFile != nil },
                    set: { if !$0 { selectedFile = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let file = selectedFile {
                    Button("Chạy / Mở trên PC") {
                        runArgs = ""
                        runAsAdmin = false
                        runWaitForExit = isScriptOrExe(file)
                        runTarget = file
                    }
                    Button("Tải về iPhone") {
                        Task { await downloadToPhone(file) }
                    }
                    Button("Đổi tên") {
                        renameInput = file.name
                        renameTarget = file
                    }
                    Button("Xóa", role: .destructive) {
                        Task { await deleteItem(file) }
                    }
                }
                Button("Hủy", role: .cancel) {}
            }
            // New Folder Alert
            .alert("Tạo thư mục mới", isPresented: $showMkdirAlert) {
                TextField("Tên thư mục", text: $newFolderName)
                Button("Tạo") {
                    Task { await createFolder() }
                }
                Button("Hủy", role: .cancel) {}
            }
            // Rename Alert
            .alert("Đổi tên", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Tên mới", text: $renameInput)
                Button("Lưu") {
                    if let target = renameTarget {
                        Task { await performRename(target, to: renameInput) }
                    }
                }
                Button("Hủy", role: .cancel) {}
            }
            // Run File Sheet
            .sheet(item: $runTarget) { target in
                NavigationStack {
                    Form {
                        Section("Tập tin") {
                            Text(target.fullPath)
                                .font(.caption.monospaced())
                        }
                        Section("Tùy chọn chạy") {
                            TextField("Tham số dòng lệnh (tùy chọn)", text: $runArgs)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Toggle("Chạy với quyền Administrator", isOn: $runAsAdmin)
                            Toggle("Chờ chạy xong & hiện output", isOn: $runWaitForExit)
                        }
                        Section {
                            Button {
                                Task { await executeRemoteFile(target) }
                            } label: {
                                Text("Chạy ngay trên PC")
                                    .frame(maxWidth: .infinity)
                                    .fontWeight(.bold)
                            }
                        }
                    }
                    .navigationTitle("Chạy file từ xa")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Đóng") { runTarget = nil }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            // Run Output Alert
            .alert("Kết quả chạy file", isPresented: Binding(
                get: { runResultText != nil },
                set: { if !$0 { runResultText = nil } }
            )) {
                Button("OK") { runResultText = nil }
            } message: {
                Text(runResultText ?? "")
            }
            // Error Alert
            .alert("Thông báo", isPresented: Binding(
                get: { errorAlert != nil },
                set: { if !$0 { errorAlert = nil } }
            )) {
                Button("OK") { errorAlert = nil }
            } message: {
                Text(errorAlert ?? "")
            }
            // Share / Save Downloaded File Sheet
            .sheet(isPresented: Binding(
                get: { shareFileURL != nil },
                set: { if !$0 { shareFileURL = nil } }
            )) {
                if let url = shareFileURL {
                    ShareSheet(activityItems: [url])
                }
            }
        }
    }

    private func iconFor(_ entry: FileEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        switch entry.extension.lowercased() {
        case ".exe", ".msi": return "app.badge"
        case ".ps1", ".bat", ".cmd", ".py", ".sh": return "terminal.fill"
        case ".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic": return "photo"
        case ".mp4", ".mov", ".mkv", ".avi": return "film"
        case ".zip", ".rar", ".7z": return "doc.zipper"
        case ".pdf", ".doc", ".docx", ".txt", ".md", ".log": return "doc.text"
        default: return "doc"
        }
    }

    private func isRunnable(_ entry: FileEntry) -> Bool {
        let ext = entry.extension.lowercased()
        return [".exe", ".bat", ".cmd", ".ps1", ".py", ".msi"].contains(ext)
    }

    private func isScriptOrExe(_ entry: FileEntry) -> Bool {
        let ext = entry.extension.lowercased()
        return [".bat", ".cmd", ".ps1"].contains(ext)
    }

    private func loadRoots() async {
        guard let client = store.client else { return }
        if let roots = try? await client.getQuickRoots() {
            shortcuts = roots.shortcuts
            drives = roots.drives
        }
    }

    private func loadDirectory(_ path: String?) async {
        guard let client = store.client else { return }
        isLoading = true
        do {
            let res = try await client.listFiles(path: path)
            currentPath = res.currentPath
            parentPath = res.parentPath
            entries = res.entries
        } catch {
            errorAlert = error.localizedDescription
        }
        isLoading = false
    }

    private func downloadToPhone(_ entry: FileEntry) async {
        guard let client = store.client else { return }
        isTransferring = true
        transferStatus = "Đang tải \(entry.name) về iPhone..."
        do {
            let localURL = try await client.downloadFile(remotePath: entry.fullPath, suggestedName: entry.name)
            shareFileURL = localURL
        } catch {
            errorAlert = error.localizedDescription
        }
        isTransferring = false
    }

    private func uploadLocalFile(_ url: URL) async {
        guard let client = store.client, !currentPath.isEmpty else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        isTransferring = true
        transferStatus = "Đang gửi \(url.lastPathComponent) sang PC..."
        do {
            let data = try Data(contentsOf: url)
            try await client.uploadData(data, filename: url.lastPathComponent, toDir: currentPath)
            await loadDirectory(currentPath)
        } catch {
            errorAlert = error.localizedDescription
        }
        isTransferring = false
    }

    private func uploadPhotoItem(_ item: PhotosPickerItem) async {
        guard let client = store.client, !currentPath.isEmpty else { return }
        isTransferring = true
        transferStatus = "Đang gửi ảnh/video sang PC..."
        do {
            if let data = try await item.loadTransferable(type: Data.self) {
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let stamp = Int(Date().timeIntervalSince1970)
                let filename = "iphone_\(stamp).\(ext)"
                try await client.uploadData(data, filename: filename, toDir: currentPath)
                await loadDirectory(currentPath)
            }
        } catch {
            errorAlert = error.localizedDescription
        }
        selectedPhotoItem = nil
        isTransferring = false
    }

    private func createFolder() async {
        guard let client = store.client, !newFolderName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let sep = currentPath.hasSuffix("\\") ? "" : "\\"
        let full = currentPath + sep + newFolderName.trimmingCharacters(in: .whitespaces)
        do {
            try await client.mkdir(path: full)
            await loadDirectory(currentPath)
        } catch {
            errorAlert = error.localizedDescription
        }
    }

    private func performRename(_ entry: FileEntry, to newName: String) async {
        guard let client = store.client else { return }
        do {
            try await client.renamePath(path: entry.fullPath, newName: newName)
            await loadDirectory(currentPath)
        } catch {
            errorAlert = error.localizedDescription
        }
    }

    private func deleteItem(_ entry: FileEntry) async {
        guard let client = store.client else { return }
        do {
            try await client.deletePath(path: entry.fullPath)
            await loadDirectory(currentPath)
        } catch {
            errorAlert = error.localizedDescription
        }
    }

    private func executeRemoteFile(_ entry: FileEntry) async {
        guard let client = store.client else { return }
        let args = runArgs
        let admin = runAsAdmin
        let wait = runWaitForExit
        runTarget = nil
        do {
            let res = try await client.runFile(path: entry.fullPath, args: args, asAdmin: admin, waitForExit: wait)
            if let out = res.output, !out.isEmpty {
                runResultText = "\(res.message)\n\n\(out)"
            } else {
                runResultText = res.message
            }
        } catch {
            errorAlert = error.localizedDescription
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
