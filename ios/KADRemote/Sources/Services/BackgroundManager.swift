import Foundation
import AVFoundation
import BackgroundTasks
import UIKit
import UserNotifications

@MainActor
final class BackgroundManager: ObservableObject {
    static let refreshTaskId = "com.kadremote.ios.refresh"
    private let enabledKey = "kad_background_enabled_v1"

    @Published var isBackgroundEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isBackgroundEnabled, forKey: enabledKey)
            if isBackgroundEnabled {
                activateBackgroundExecution()
            } else {
                deactivateBackgroundExecution()
            }
        }
    }

    @Published var notificationsAuthorized: Bool = false
    @Published var statusLabel: String = "Tắt"

    private var silentPlayer: AVAudioPlayer?
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid
    private var lastNotificationDate: Date = .distantPast

    init() {
        let saved = UserDefaults.standard.bool(forKey: enabledKey)
        self.isBackgroundEnabled = saved
        refreshNotificationStatus()
        if saved {
            activateBackgroundExecution()
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            requestNotificationPermission()
        }
        isBackgroundEnabled = enabled
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in
                self.notificationsAuthorized = granted
            }
        }
    }

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                self.notificationsAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            }
        }
    }

    func handleScenePhase(_ phase: ScenePhaseProxy, onRefresh: @escaping () -> Void) {
        switch phase {
        case .background:
            if isBackgroundEnabled {
                beginShortBackgroundTask()
                ensureSilentAudioRunning()
                scheduleAppRefresh()
            }
        case .active:
            endShortBackgroundTask()
            if isBackgroundEnabled {
                ensureSilentAudioRunning()
            }
            onRefresh()
        case .inactive:
            break
        }
    }

    static func registerBackgroundTasks(onRefresh: @escaping () async -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskId, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }

            let work = Task {
                await onRefresh()
                refreshTask.setTaskCompleted(success: true)
            }

            refreshTask.expirationHandler = {
                work.cancel()
            }

            Task { @MainActor in
                let req = BGAppRefreshTaskRequest(identifier: refreshTaskId)
                req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
                try? BGTaskScheduler.shared.submit(req)
            }
        }
    }

    func scheduleAppRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    func notifyIfInBackground(title: String, body: String) {
        guard isBackgroundEnabled, notificationsAuthorized else { return }
        guard UIApplication.shared.applicationState != .active else { return }
        guard Date().timeIntervalSince(lastNotificationDate) > 8 else { return }
        lastNotificationDate = Date()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func activateBackgroundExecution() {
        ensureSilentAudioRunning()
        scheduleAppRefresh()
        statusLabel = "Đang bật (giữ kết nối nền)"
    }

    private func deactivateBackgroundExecution() {
        silentPlayer?.stop()
        silentPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        endShortBackgroundTask()
        statusLabel = "Tắt"
    }

    private func ensureSilentAudioRunning() {
        if silentPlayer?.isPlaying == true { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            if silentPlayer == nil {
                let wavData = Self.makeSilentWav(seconds: 2)
                let player = try AVAudioPlayer(data: wavData)
                player.numberOfLoops = -1
                player.volume = 0.0
                player.prepareToPlay()
                silentPlayer = player
            }
            silentPlayer?.play()
        } catch {
            statusLabel = "Lỗi kích hoạt nền: \(error.localizedDescription)"
        }
    }

    private func beginShortBackgroundTask() {
        endShortBackgroundTask()
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "KADRemoteKeepAlive") { [weak self] in
            Task { @MainActor in
                self?.endShortBackgroundTask()
            }
        }
    }

    private func endShortBackgroundTask() {
        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }
    }

    /// Generates a tiny silent 8kHz mono 16-bit PCM WAV buffer in memory.
    private static func makeSilentWav(seconds: Int) -> Data {
        let sampleRate: UInt32 = 8000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let numSamples = Int(sampleRate) * max(1, seconds)
        let dataSize = UInt32(numSamples * Int(channels) * Int(bitsPerSample / 8))
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var data = Data(capacity: 44 + Int(dataSize))
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: (36 + dataSize).littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        data.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        data.append(Data(count: Int(dataSize)))
        return data
    }
}

enum ScenePhaseProxy {
    case active, inactive, background
}
