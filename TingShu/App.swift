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
import UIKit

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

        // 尽早把锁屏那几个命令挂上，否则 App 刚起来时锁屏按钮是灰的。
        // 真正执行什么要等 WebShell 建好后 bind 进来。
        NowPlayingCenter.shared.installCommands()

        // 允许 App 响应锁屏 / 耳机的播放暂停按键
        application.beginReceivingRemoteControlEvents()

        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // 进后台时确保音频会话仍然活跃。只要会话活跃且真有音频在播，
        // 系统就不会把 App 挂起，WKWebView 里的 <audio> 也能继续出声。
        AudioSessionManager.shared.keepAlive()

        // 再要一小段后台执行时间，在暂停状态下多撑几十秒。
        // 目的是「暂停后立刻切出去再回来，锁屏卡片还在我们这儿」。
        AudioSessionManager.shared.beginBackgroundGrace()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // 回到前台：把那段临时执行时间还掉，重新抢会话，并把卡片重写一遍。
        // 这两步是「卡片被别人顶掉」的高发时刻的补救。
        AudioSessionManager.shared.endBackgroundGrace()
        AudioSessionManager.shared.keepAlive()
        NowPlayingCenter.shared.refresh()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
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

    /// 打断开始（来电 / 闹钟 / 别的 App 抢麦）。WebShell 用它记下「打断前是不是在播」
    var onInterruptionBegan: (() -> Void)?

    /// 打断结束（来电挂断、Siri 退场、别的 App 放手）后回调，用来续播
    var onInterruptionEnded: (() -> Void)?

    /// 音频服务被系统重置（换耳机、系统音频进程重启）。
    /// 这时所有会话设置都回到了默认，必须重新 configure 一遍。
    var onMediaServicesReset: (() -> Void)?

    private var graceTask: UIBackgroundTaskIdentifier = .invalid
    private var graceTimer: Timer?

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

    /// 重新激活会话。
    ///
    /// 🔴 这里以前有一句「别人正在出声就别抢，直接 return」的 guard，
    /// 那是「过一会锁屏卡片变成喜马拉雅」的元凶之一：
    /// 为真只表示**别人正在播**，而 playback 分类下 setActive(true)
    /// 本身就是抢占动作（对方会收到 interruption，自己停下来）。
    /// 一看到别人在播就 return，等于主动把锁屏控制权交出去 ——
    /// 交出去之后，锁屏上那颗播放键就成了别人的。
    ///
    /// 自检脚本会盯着这个判断：以后再写回来会被判失败。
    func keepAlive() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true)
        } catch {
            // 来电 / 闹钟持有更高优先级时会失败，这是正常的。
            // 不用在这里死磕重试 —— interruption ended 时会再补一次。
            debugPrint("[Audio] 重新激活失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 后台宽限

    /// 进后台时申请一小段额外执行时间，在这段时间里定期 keepAlive + 重写卡片。
    ///
    /// 为什么需要：暂停之后系统会在几十秒内把 App 挂起并让会话失效，
    /// 喜马拉雅这类常驻抢麦的 App 就会顺势拿到 Now Playing。
    /// 有了这段宽限，用户「暂停 → 切微信 → 切回来」这几十秒内卡片跑不掉。
    func beginBackgroundGrace() {
        endBackgroundGrace()          // 幂等，避免重复申请

        graceTask = UIApplication.shared.beginBackgroundTask(withName: "ts-audio-grace") { [weak self] in
            // 时间到，必须还回去，否则 App 会被 watchdog 直接杀掉
            self?.endBackgroundGrace()
        }

        graceTimer?.invalidate()
        graceTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard self != nil else { return }
            AudioSessionManager.shared.keepAlive()
            NowPlayingCenter.shared.refresh()
        }
    }

    func endBackgroundGrace() {
        graceTimer?.invalidate()
        graceTimer = nil
        if graceTask != .invalid {
            UIApplication.shared.endBackgroundTask(graceTask)
            graceTask = .invalid
        }
    }

    // MARK: - 通知监听

    private func startObserving() {
        guard !observing else { return }
        observing = true

        let center = NotificationCenter.default

        // 来电、闹钟、Siri、别的 App 抢占会打断音频。
        // 打断结束后必须重新 setActive 并续播，
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
                AudioSessionManager.shared.onInterruptionBegan?()
            case .ended:
                let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optRaw)
                AudioSessionManager.shared.keepAlive()
                NowPlayingCenter.shared.refresh()
                if options.contains(.shouldResume) {
                    debugPrint("[Audio] 打断结束，允许恢复")
                    AudioSessionManager.shared.onInterruptionEnded?()
                } else {
                    // 系统没给 shouldResume（比如用户手动接了电话又挂断），
                    // 但会话已经回到我们手上，把卡片重写一遍就够了。
                    debugPrint("[Audio] 打断结束，不自动续播")
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

        // 音频服务被重置：会话设置全部丢失，必须重新配 category
        _ = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { _ in
            debugPrint("[Audio] 音频服务被重置，重新配置会话")
            AudioSessionManager.shared.configure()
            AudioSessionManager.shared.onMediaServicesReset?()
        }
    }
}
