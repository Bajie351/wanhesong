//
//  NowPlaying.swift
//  锁屏 / 控制中心 / 耳机线控 / 车机的控制权，以及锁屏卡片上的信息。
//
//  ── 为什么必须放在原生层 ──────────────────────────────────
//  网页里的 navigator.mediaSession 只够「有」这个功能，撑不住：
//    ① App 退到后台后 WebKit 的媒体进程会被系统降权，
//       setActionHandler 的回调经常干脆不触发 ⇒ 锁屏按播放没反应；
//    ② 我们这边一旦静默超过一段时间，iOS 会把全局 Now Playing
//       （锁屏那张卡）交给后台还活着的别的 App —— 典型就是喜马拉雅。
//       用户看到的就是「过一会锁屏播放框变成喜马拉雅了」。
//
//  MPRemoteCommandCenter 是 UIKit 级 API：只要 App 进程活着、
//  AudioSession 有效，按键就一定会送到这里，不经过 WebKit。
//  MPNowPlayingInfoCenter 同理，由我们主动写卡片，谁也别想顶掉。
//
//  ── 分工 ────────────────────────────────────────────────
//  原生：接按键 → 回调给 WebShell → evaluateJavaScript 调 window.__ts.*
//        收网页上报的状态 → 写 nowPlayingInfo（标题/封面/时长/进度）
//  网页：真正持有 <audio>，负责播放与进度
//

import Foundation
import MediaPlayer
import AVFoundation
import UIKit

final class NowPlayingCenter {

    static let shared = NowPlayingCenter()

    /// 原生接到的按键动作，交给 WebShell 翻译成 JS 调用
    enum Action {
        case play
        case pause
        case toggle
        case next
        case previous
        /// 绝对位置（锁屏卡片上拖进度条）
        case seek(TimeInterval)
        /// 相对位移（锁屏长按上一首/下一首当快退快进用）
        case skip(TimeInterval)
    }

    private var handler: ((Action) -> Void)?
    private var commandsInstalled = false

    /// itemId → 已下载好的封面。只有两门课，字典很小，不用做淘汰。
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    private var artworkInFlight: Set<String> = []
    private var hasContent = false

    private init() {}

    // MARK: - 注册命令

    /// 只注册一次。放在 AppDelegate 里尽早调用，
    /// 免得 App 刚起来时锁屏上的按钮是灰的。
    func installCommands() {
        guard !commandsInstalled else { return }
        commandsInstalled = true

        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.deliver(.play)
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.deliver(.pause)
            return .success
        }

        // 锁屏上那颗大键、AirPods 单击，走的都是这个
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.deliver(.toggle)
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.deliver(.next)
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.deliver(.previous)
            return .success
        }

        // 在锁屏卡片上拖进度条
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.deliver(.seek(e.positionTime))
            return .success
        }

        // 长按上一首 / 下一首 = 快退 / 快进
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.addTarget { [weak self] event in
            let e = event as? MPSkipIntervalCommandEvent
            self?.deliver(.skip(e?.interval ?? 30))
            return .success
        }

        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.addTarget { [weak self] event in
            let e = event as? MPSkipIntervalCommandEvent
            self?.deliver(.skip(-(e?.interval ?? 15)))
            return .success
        }

        debugPrint("[NowPlaying] 锁屏命令已注册")
    }

    /// WebShell 建好之后把「怎么执行」塞进来
    func bind(_ handler: @escaping (Action) -> Void) {
        self.handler = handler
        installCommands()
    }

    private func deliver(_ action: Action) {
        // 收到按键的第一件事：把音频会话抢回来。
        // 别的 App 很可能刚刚 setActive 过（喜马拉雅这类会一直抢），
        // 不先抢的话，网页那边就算调了 play() 也是「进度在走但没声音」。
        AudioSessionManager.shared.keepAlive()
        handler?(action)
    }

    // MARK: - 写锁屏卡片

    /// 用网页上报的状态刷新锁屏卡片。
    /// 传进来的就是 `window.__ts.state()` 解析后的字典。
    func update(from info: [String: Any]) {
        guard (info["ready"] as? Bool) == true else {
            // 没有可播内容。保留上一张卡片（清掉反而会让系统把位置让给别人），
            // 只是把状态标成暂停。
            if hasContent {
                MPNowPlayingInfoCenter.default().playbackState = .paused
            }
            return
        }

        let playing = (info["playing"] as? Bool) ?? false
        let title = (info["title"] as? String) ?? ""
        let artist = (info["artist"] as? String) ?? ""
        let album = (info["album"] as? String) ?? ""
        let duration = (info["duration"] as? Double) ?? 0
        let position = (info["position"] as? Double) ?? 0
        let rate = (info["rate"] as? Double) ?? 1
        let itemId = (info["itemId"] as? String) ?? ""
        let artworkUrl = (info["artwork"] as? String) ?? ""

        var dict: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            // 关键：给系统「位置 + 速率」，让它自己插值走秒。
            // 这样我们不用每秒回写一次，锁屏进度条也是顺的。
            MPNowPlayingInfoPropertyPlaybackRate: playing ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if duration > 0 {
            dict[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let art = artworkCache[itemId] {
            dict[MPMediaItemPropertyArtwork] = art
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = dict
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
        hasContent = true

        if !artworkUrl.isEmpty, artworkCache[itemId] == nil, !artworkInFlight.contains(itemId) {
            loadArtwork(urlString: artworkUrl, itemId: itemId)
        }
    }

    /// 网页直接把封面的像素送过来（canvas → base64）。
    ///
    /// 为什么还要这条：我们 plist 里同时写了 InWebContent / ForMedia / LocalNetworking，
    /// 按 iOS 的规则 `NSAllowsArbitraryLoads` 会被整体忽略，
    /// 原生自己 URLSession 拉 http 图就可能被 ATS 拦。
    /// 虽然补了 NSExceptionDomains，但让**已经把图加载出来的网页**直接传像素最稳 ——
    /// 网页那侧走的是 InWebContent 例外，一定能拿到。
    func setArtwork(base64: String, itemId: String) {
        guard
            !base64.isEmpty,
            let data = Data(base64Encoded: base64),
            let image = UIImage(data: data)
        else { return }

        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        artworkCache[itemId] = artwork
        if var current = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            current[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = current
        }
        debugPrint("[NowPlaying] 收到网页送来的封面 \(Int(image.size.width))x\(Int(image.size.height))")
    }

    /// 把卡片上已有的信息再写一遍。
    /// App 从后台回来 / 音频服务被重置之后调用 —— 这两处是卡片被顶掉的高发时刻。
    func refresh() {
        guard let info = MPNowPlayingInfoCenter.default().nowPlayingInfo, hasContent else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - 封面

    private func loadArtwork(urlString: String, itemId: String) {
        guard let url = URL(string: urlString) else { return }
        artworkInFlight.insert(itemId)

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data = data, let image = UIImage(data: data) else {
                // 回调在后台线程，去主线程收尾 —— artworkInFlight / artworkCache
                // 都是普通集合，跨线程同时改会出问题
                DispatchQueue.main.async {
                    self?.artworkInFlight.remove(itemId)
                }
                if let error = error {
                    debugPrint("[NowPlaying] 封面下载失败: \(error.localizedDescription)")
                } else {
                    debugPrint("[NowPlaying] 封面解码失败(\(data?.count ?? 0) B)")
                }
                return
            }

            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.artworkInFlight.remove(itemId)
                self.artworkCache[itemId] = artwork
                // 只补封面这一项，别把标题/进度覆盖成旧值
                if var current = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                    current[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = current
                }
            }
        }.resume()
    }
}
