//
//  App.swift
//  听书 —— 自建 Audiobookshelf 客户端的原生外壳
//
//  为什么需要这一层：
//  纯网页（PWA）在 iOS 17+ 的独立窗口里**锁屏 / 后台不出声**，
//  这是 WebKit 的平台限制，网页层无论怎么改都突破不了。
//  能出声的前提是「原生 App + AVAudioSession(.playback) + UIBackgroundModes:audio」，
//  这三样东西只有原生代码拿得到。所以这里只做一个极薄的壳，
//  界面 100% 仍然是服务器上那套网页，原生部分只负责音频会话与容器。
//

import SwiftUI
import AVFoundation
import MediaPlayer

@main
struct TingShuApp: App {
    // 挂一个 AppDelegate：AVAudioSession 必须在 App 启动最早阶段就设好，
    // 晚于 WebView 创建的话，第一次播放会被判成 ambient（跟随静音开关）。
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                // 安全区交给网页自己用 env(safe-area-inset-*) 处理，
                // 这里必须真正全屏，否则 WKWebView 的 safeAreaInsets 会变成 0。
                .ignoresSafeArea()
                .preferredColorScheme(.light)
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        AudioSessionManager.shared.configure()

        // 允许 App 响应锁屏 / 耳机的播放暂停按键
        application.beginReceivingRemoteControlEvents()

        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // 进后台时确保音频会话仍然活跃。只要会话活跃且真有音频在播，
        // 系统就不会把 App 挂起，WKWebView 里的 <audio> 也能继续出声。
        AudioSessionManager.shared.keepAlive()
    }
}

// MARK: - 音频会话

/// 音频会话管理。
///
/// `.playback` 有两个关键作用：
///   ① 绕过 iPhone 侧面的静音拨片（听书 App 必须做到这一点）
///   ② 允许 App 在后台 / 锁屏状态下继续输出声音
/// `mode: .spokenAudio` 是人声朗读专用模式，会关掉一些为音乐准备的音效处理，
/// 对长时间听课程更合适（也更省电）。
final class AudioSessionManager {

    static let shared = AudioSessionManager()
    private var observing = false

    private init() {}

    func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            debugPrint("[Audio] 会话已激活 category=playback mode=spokenAudio")
        } catch {
            debugPrint("[Audio] 会话配置失败: \(error)")
        }
        startObserving()
    }

    /// 从后台回来 / 会话被系统打断后，重新激活。
    func keepAlive() {
        let session = AVAudioSession.sharedInstance()
        guard !session.isOtherAudioPlaying else { return }
        do {
            try session.setActive(true)
        } catch {
            debugPrint("[Audio] 重新激活失败: \(error)")
        }
    }

    private func startObserving() {
        guard !observing else { return }
        observing = true

        let center = NotificationCenter.default

        // 来电、闹钟、Siri 会打断音频。打断结束后必须重新 setActive，
        // 否则会出现「播放进度在走但没有声音」的假死状态。
        _ = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { note in
            guard
                let info = note.userInfo,
                let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }

            switch type {
            case .began:
                debugPrint("[Audio] 被打断")
            case .ended:
                let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optRaw)
                if options.contains(.shouldResume) {
                    AudioSessionManager.shared.keepAlive()
                    debugPrint("[Audio] 打断结束，允许恢复")
                }
            @unknown default:
                break
            }
        }

        // 拔耳机 / 断开蓝牙：系统会自动暂停播放，这里只补一次会话激活
        _ = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            AudioSessionManager.shared.keepAlive()
        }
    }
}
