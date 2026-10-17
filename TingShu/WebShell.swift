//
//  WebShell.swift
//  界面本体：一个全屏 WKWebView 加载服务器上的 /ui/ 页面。
//
//  这里刻意不做任何 UI 重写 —— 布局、配色、交互全部沿用已经调好的网页，
//  原生层只补网页拿不到的三件事：
//    ① 音频会话（见 App.swift）
//    ② 全屏 + 安全区正确传递给 CSS env()
//    ③ 加载失败时的兜底界面 / 服务器地址可改
//

import SwiftUI
import WebKit
import Combine

// MARK: - 数据模型

final class WebModel: ObservableObject {

    /// 默认地址：必须是 /ui/ 结尾（这是网页入口，不是 AudioBooth 用的根地址）
    static let fallbackAddress = "http://124.220.38.38/ui/"

    @Published var address: String
    @Published var failure: String?
    @Published var isLoading = true
    @Published var showSettings = false
    /// 每次「重试」都自增，触发 WebShell 重新 load
    @Published var reloadToken = 0

    private let storeKey = "serverAddress"

    init() {
        let saved = UserDefaults.standard.string(forKey: storeKey) ?? ""
        address = saved.isEmpty ? Self.fallbackAddress : saved
    }

    var url: URL {
        URL(string: address) ?? URL(string: Self.fallbackAddress)!
    }

    func retry() {
        failure = nil
        isLoading = true
        reloadToken += 1
    }

    func apply(address raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = Self.fallbackAddress }

        // 用户经常只写 IP：补上协议
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        // 裸 IP 一定要带路径，否则打开的是 ABS 自带的 web app
        if let u = URL(string: text), (u.path.isEmpty || u.path == "/") {
            text = text.hasSuffix("/") ? text + "ui/" : text + "/ui/"
        }
        if !text.hasSuffix("/") { text += "/" }

        UserDefaults.standard.set(text, forKey: storeKey)
        address = text
        retry()
    }

    func resetAddress() {
        UserDefaults.standard.removeObject(forKey: storeKey)
        address = Self.fallbackAddress
        retry()
    }
}

// MARK: - 根视图

struct RootView: View {
    @StateObject private var model = WebModel()

    var body: some View {
        ZStack(alignment: .top) {
            BrandColor.background.ignoresSafeArea()

            WebShell(model: model)
                .ignoresSafeArea()

            if model.isLoading && model.failure == nil {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(BrandColor.accent)
                    .frame(maxWidth: .infinity)
                    .ignoresSafeArea(edges: .top)
            }

            if let message = model.failure {
                FailurePanel(message: message, model: model)
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $model.showSettings) {
            ServerSheet(model: model)
        }
    }
}

// MARK: - 失败兜底

private struct FailurePanel: View {
    let message: String
    @ObservedObject var model: WebModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(BrandColor.accent)

            Text("连不上服务器")
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(BrandColor.ink)

            Text(message)
                .font(.system(size: 12.5))
                .foregroundColor(BrandColor.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            Text(model.address)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(BrandColor.inkTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(BrandColor.card)
                .clipShape(Capsule())

            VStack(spacing: 10) {
                Button {
                    model.retry()
                } label: {
                    Text("重试")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(BrandColor.accent)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }

                Button {
                    model.showSettings = true
                } label: {
                    Text("修改服务器地址")
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundColor(BrandColor.inkSecondary)
                        .background(BrandColor.card)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 320)
        .background(BrandColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 24, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.12).ignoresSafeArea())
    }
}

// MARK: - 服务器地址设置

private struct ServerSheet: View {
    @ObservedObject var model: WebModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("http://124.220.38.38/ui/", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                        .font(.system(size: 14, design: .monospaced))
                } header: {
                    Text("服务器地址")
                } footer: {
                    Text("填到 /ui/ 为止。只写 IP 也可以，App 会自动补全。")
                        .font(.system(size: 11.5))
                }

                Section {
                    Button("保存并重新加载") {
                        model.apply(address: text)
                        dismiss()
                    }
                    Button("恢复默认地址", role: .destructive) {
                        model.resetAddress()
                        dismiss()
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .onAppear { text = model.address }
    }
}

// MARK: - WKWebView 容器

struct WebShell: UIViewRepresentable {
    @ObservedObject var model: WebModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()          // localStorage / 登录态持久化

        // —— 媒体播放的三项关键开关 ——
        config.allowsInlineMediaPlayback = true       // 不要被系统接管成全屏播放器
        config.mediaTypesRequiringUserActionForPlayback = []  // 允许无手势自动播放（续播需要）
        config.allowsAirPlayForMediaPlayback = true   // AirPlay 到 HomePod / 电视
        config.allowsPictureInPictureMediaPlayback = false

        // 网页一开始播放就告诉原生「真的在播」，
        // 原生据此重新激活音频会话，避免「进度在走但没声音」。
        let hook = """
        (function(){
          if (window.__tsNativeHooked) return;
          window.__tsNativeHooked = true;
          function post(type){
            try {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.player) {
                window.webkit.messageHandlers.player.postMessage({type: type});
              }
            } catch(e){}
          }
          // 音频事件不冒泡，必须用 capture 在 document 上截
          ['play','playing','pause','ended'].forEach(function(t){
            document.addEventListener(t, function(){ post(t); }, true);
          });
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(
                source: hook,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        config.userContentController.add(context.coordinator, name: "player")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        // 全屏铺满，安全区交给页面的 env(safe-area-inset-*) 自己处理
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.scrollView.backgroundColor = UIColor(BrandColor.background)

        // 避免加载瞬间白屏闪一下
        webView.isOpaque = false
        webView.backgroundColor = UIColor(BrandColor.background)
        webView.scrollView.showsVerticalScrollIndicator = false

        webView.load(URLRequest(url: model.url))
        context.coordinator.lastLoaded = model.url.absoluteString
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // 「重试 / 改地址」通过 reloadToken 自增来触发
        let key = model.url.absoluteString + "#\(model.reloadToken)"
        guard context.coordinator.lastReloadKey != key else { return }

        if context.coordinator.lastReloadKey != nil {
            if context.coordinator.lastLoaded != model.url.absoluteString {
                webView.load(URLRequest(url: model.url))
                context.coordinator.lastLoaded = model.url.absoluteString
            } else {
                webView.reloadFromOrigin()
            }
        }
        context.coordinator.lastReloadKey = key
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "player")
        webView.stopLoading()
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

        let model: WebModel
        var lastLoaded: String?
        var lastReloadKey: String?

        init(model: WebModel) {
            self.model = model
        }

        // —— 加载状态 ——

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.model.isLoading = true
                self.model.failure = nil
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.model.isLoading = false
                self.model.failure = nil
            }
            AudioSessionManager.shared.keepAlive()
            injectSafeAreaFallback(into: webView)
        }

        /// 安全区兜底。
        ///
        /// 正常情况 WKWebView 会把自身 safeAreaInsets 映射成 CSS 的 env(safe-area-inset-*)，
        /// 页面不用改。但如果这条链路因为系统版本或容器层级失效，env() 会静默返回 0 —
        /// 表现就是「标题被状态栏压住」「底部图标被 Home Indicator 压住」，很难查。
        /// 这里探一次：真的返回 0 才注入覆盖样式，正常时不碰页面。
        private func injectSafeAreaFallback(into webView: WKWebView) {
            let top = Int(webView.safeAreaInsets.top.rounded())
            let bottom = Int(webView.safeAreaInsets.bottom.rounded())
            guard top > 0 || bottom > 0 else { return }

            let tabPadding = max(bottom - 12, 10)

            let js = """
            (function(){
              try{
                var d = document.createElement('div');
                d.style.cssText = 'position:fixed;left:0;top:0;width:1px;'
                  + 'height:env(safe-area-inset-top,0px);pointer-events:none;opacity:0;';
                document.documentElement.appendChild(d);
                var h = d.getBoundingClientRect().height;
                d.remove();
                if (h >= 1) return 'env-ok:' + h;

                var st = document.createElement('style');
                st.id = 'ts-safearea-fallback';
                st.textContent = '#app{padding-top:\(top)px !important}'
                  + ':root{--tabpb:\(tabPadding)px !important}';
                document.head.appendChild(st);
                return 'env-failed, patched top=\(top) bottom=\(bottom)';
              }catch(e){ return 'err:' + e; }
            })();
            """
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    debugPrint("[SafeArea] 探测失败: \(error)")
                } else {
                    debugPrint("[SafeArea] \(String(describing: result))")
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            report(error)
        }

        private func report(_ error: Error) {
            let ns = error as NSError
            // 页面内主动取消（比如换了地址）不算失败
            guard ns.code != NSURLErrorCancelled else { return }

            DispatchQueue.main.async {
                self.model.isLoading = false
                self.model.failure = Self.humanize(ns)
            }
        }

        /// 把 NSURLError 翻译成能直接照着排查的中文
        private static func humanize(_ e: NSError) -> String {
            switch e.code {
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "找不到这个地址。请核对 IP 有没有打错，比如 124 打成 127 就会一直连不上。"
            case NSURLErrorCannotConnectToHost:
                return "地址通了但端口没开。确认服务器上的服务在跑，且防火墙放行了 80。"
            case NSURLErrorTimedOut:
                return "连接超时。可能是服务器关机、网络不通，或 IP 写错了。"
            case NSURLErrorNotConnectedToInternet:
                return "手机当前没有网络。"
            case NSURLErrorNetworkConnectionLost:
                return "网络中断了，点重试试试。"
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return "被系统拦截了 http 请求，请把 App 重新编译一次。"
            default:
                return "\(e.localizedDescription)（错误码 \(e.code)）"
            }
        }

        // —— 外链一律交给系统浏览器，别把用户困在壳里 ——

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let scheme = url.scheme?.lowercased() ?? ""
            if scheme != "http" && scheme != "https" {
                // tel: / mailto: 之类
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            let sameHost = url.host == model.url.host
            if !sameHost, navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        // —— 网页里的 window.open / target=_blank ——

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                UIApplication.shared.open(url)
            }
            return nil
        }

        // —— 网页 → 原生的播放事件 ——

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard
                message.name == "player",
                let body = message.body as? [String: Any],
                let type = body["type"] as? String
            else { return }

            switch type {
            case "play", "playing":
                AudioSessionManager.shared.keepAlive()
            default:
                break
            }
        }
    }
}

// MARK: - 配色（与网页 style.css 保持一致）

enum BrandColor {
    /// 页面底色 #FAF9F7
    static let background = Color(red: 0.980, green: 0.976, blue: 0.969)
    /// 卡片 #FFFFFF
    static let surface = Color.white
    static let card = Color(red: 0.949, green: 0.945, blue: 0.937)
    /// 主色 #E8432A
    static let accent = Color(red: 0.910, green: 0.263, blue: 0.165)
    /// 正文 #1C1B1A
    static let ink = Color(red: 0.110, green: 0.106, blue: 0.102)
    static let inkSecondary = Color(red: 0.455, green: 0.443, blue: 0.427)
    static let inkTertiary = Color(red: 0.639, green: 0.627, blue: 0.612)
}
