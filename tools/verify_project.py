# -*- coding: utf-8 -*-
"""iOS 工程静态自检。

Windows 上没有 Xcode，编译不了。这个脚本把「编译前就能查出」的问题先扫一遍：
  1. 所有必需文件是否齐全
  2. Info.plist 是否合法、后台播放/ATS 的关键键是否都在
  3. 所有 Contents.json 是否是合法 JSON
  4. AppIcon 是否 1024x1024 且**不带 alpha**（带 alpha 会导致上传/安装校验失败）
  5. Info.plist 里引用的颜色名是否真的存在于 Assets
  6. project.yml 里的 INFOPLIST_FILE / scheme 名是否与源码一致
  7. Swift 文件里的大括号是否配平（粗略，但能抓住粘贴截断）

用法：
    python deploy/ios/tools/verify_project.py
"""
import json
import os
import plistlib
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
APP_NAME = "TingShu"

ok = 0
warn = 0
fail = 0


def good(msg):
    global ok
    ok += 1
    print("  \033[32mOK\033[0m   %s" % msg)


def warning(msg):
    global warn
    warn += 1
    print("  \033[33mWARN\033[0m %s" % msg)


def bad(msg):
    global fail
    fail += 1
    print("  \033[31mFAIL\033[0m %s" % msg)


def check_required_files():
    print("\n[1] 必需文件")
    need = [
        "project.yml",
        ".github/workflows/build.yml",
        "%s/App.swift" % APP_NAME,
        "%s/WebShell.swift" % APP_NAME,
        "%s/Info.plist" % APP_NAME,
        "%s/Assets.xcassets/Contents.json" % APP_NAME,
        "%s/Assets.xcassets/AppIcon.appiconset/Contents.json" % APP_NAME,
        "%s/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" % APP_NAME,
        "%s/Assets.xcassets/AccentColor.colorset/Contents.json" % APP_NAME,
        "%s/Assets.xcassets/LaunchBackground.colorset/Contents.json" % APP_NAME,
    ]
    for rel in need:
        p = os.path.join(ROOT, rel)
        if os.path.isfile(p):
            good("%s (%d B)" % (rel, os.path.getsize(p)))
        else:
            bad("缺少 %s" % rel)
    return all(os.path.isfile(os.path.join(ROOT, r)) for r in need)


def check_plist():
    print("\n[2] Info.plist")
    path = os.path.join(ROOT, APP_NAME, "Info.plist")
    try:
        with open(path, "rb") as f:
            data = plistlib.load(f)
    except Exception as e:
        bad("解析失败：%s" % e)
        return None

    good("plist 可解析，共 %d 个键" % len(data))

    modes = data.get("UIBackgroundModes") or []
    if "audio" in modes:
        good("UIBackgroundModes 含 audio —— 后台/锁屏出声的前提")
    else:
        bad("UIBackgroundModes 缺少 audio，锁屏一定没声音")

    # 🔴 这里踩过大坑：iOS 10+ 只要出现 InWebContent / ForMedia / LocalNetworking 任一键，
    #    NSAllowsArbitraryLoads 就会被整体忽略；而 WKWebView 只认 NSAllowsArbitraryLoadsInWebContent。
    #    只写 NSAllowsArbitraryLoads 的版本能编译、能装、能打开，但一加载就 -1022 白屏。
    ats = data.get("NSAppTransportSecurity") or {}
    if ats.get("NSAllowsArbitraryLoadsInWebContent"):
        good("ATS 含 NSAllowsArbitraryLoadsInWebContent —— WKWebView 才能加载 http 裸 IP")
    else:
        bad("ATS 缺 NSAllowsArbitraryLoadsInWebContent —— WKWebView 会报 -1022 白屏（有 NSAllowsArbitraryLoads 也没用）")

    if ats.get("NSAllowsArbitraryLoads"):
        good("ATS 也保留了 NSAllowsArbitraryLoads")
    else:
        warn("没有 NSAllowsArbitraryLoads，URLSession 直连 http 会受限")

    if ats.get("NSAllowsLocalNetworking"):
        good("ATS 含 NSAllowsLocalNetworking（将来改局域网 IP 也能连）")
    else:
        warn("没有 NSAllowsLocalNetworking，改成局域网 IP 会连不上")

    if data.get("UILaunchScreen") is not None:
        good("有 UILaunchScreen（缺了会以兼容模式跑，四周出现黑边）")
    else:
        warn("没有 UILaunchScreen，可能以兼容模式运行")

    orient = data.get("UISupportedInterfaceOrientations") or []
    if orient == ["UIInterfaceOrientationPortrait"]:
        good("仅竖屏")
    else:
        warn("屏幕方向配置为 %s" % orient)

    launch_color = (data.get("UILaunchScreen") or {}).get("UIColorName")
    if launch_color:
        p = os.path.join(ROOT, APP_NAME, "Assets.xcassets", "%s.colorset" % launch_color)
        if os.path.isdir(p):
            good("启动屏颜色 %s 存在于 Assets" % launch_color)
        else:
            bad("启动屏引用了不存在的颜色 %s" % launch_color)

    if data.get("CFBundleDisplayName"):
        good("桌面显示名：%s" % data["CFBundleDisplayName"])

    return data


def check_json_assets():
    print("\n[3] Assets 目录 JSON")
    base = os.path.join(ROOT, APP_NAME, "Assets.xcassets")
    found = 0
    for dirpath, _dirnames, filenames in os.walk(base):
        for fn in filenames:
            if not fn.endswith(".json"):
                continue
            found += 1
            p = os.path.join(dirpath, fn)
            try:
                with open(p, "r", encoding="utf-8") as f:
                    json.load(f)
                good(os.path.relpath(p, ROOT))
            except Exception as e:
                bad("%s 不是合法 JSON：%s" % (os.path.relpath(p, ROOT), e))
    if found == 0:
        bad("Assets 里一个 JSON 都没有，资源集不会被识别")

    # AppIcon 声明与文件是否对得上
    icon_json = os.path.join(base, "AppIcon.appiconset", "Contents.json")
    if os.path.isfile(icon_json):
        with open(icon_json, "r", encoding="utf-8") as f:
            meta = json.load(f)
        for img in meta.get("images", []):
            fn = img.get("filename")
            if not fn:
                continue
            p = os.path.join(base, "AppIcon.appiconset", fn)
            if os.path.isfile(p):
                good("AppIcon 声明与文件对得上：%s（%s）" % (fn, img.get("size")))
            else:
                bad("Contents.json 声明了 %s 但文件不存在" % fn)


def check_icon():
    print("\n[4] AppIcon 规格")
    try:
        from PIL import Image
    except ImportError:
        warn("没装 Pillow，跳过图片检查（pip install pillow）")
        return

    p = os.path.join(ROOT, APP_NAME, "Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
    if not os.path.isfile(p):
        bad("AppIcon-1024.png 不存在")
        return

    img = Image.open(p)
    if img.size == (1024, 1024):
        good("尺寸 1024x1024")
    else:
        bad("尺寸是 %s，iOS 要求 1024x1024" % (img.size,))

    if img.mode == "RGB":
        good("无 alpha 通道（mode=RGB）")
    else:
        bad("mode=%s，带 alpha 会导致校验失败，须存成 RGB" % img.mode)


def check_project_yml():
    print("\n[5] project.yml")
    p = os.path.join(ROOT, "project.yml")
    if not os.path.isfile(p):
        return
    text = open(p, "r", encoding="utf-8").read()

    if "INFOPLIST_FILE: %s/Info.plist" % APP_NAME in text:
        good("INFOPLIST_FILE 指向 %s/Info.plist" % APP_NAME)
    else:
        bad("INFOPLIST_FILE 没指到 %s/Info.plist" % APP_NAME)

    if "GENERATE_INFOPLIST_FILE: NO" in text:
        good("显式关闭自动生成 plist（避免手写 plist 被覆盖）")
    else:
        warn("没有 GENERATE_INFOPLIST_FILE: NO，手写 plist 可能被忽略")

    if "APPICON_NAME: AppIcon" in text:
        good("AppIcon 资源名已配置")
    else:
        bad("缺 ASSETCATALOG_COMPILER_APPICON_NAME，桌面图标会是白板")

    if "CODE_SIGNING_ALLOWED: NO" in text:
        good("无签名构建（Sideloadly 安装时重签）")

    if "schemes:" in text and "TingShu:" in text:
        good("已定义 scheme TingShu")

    # sources 里排除了 Info.plist，否则会被当资源塞进 bundle
    if 'excludes:' in text and 'Info.plist' in text:
        good("sources 已排除 Info.plist，不会被复制成资源")
    else:
        warn("sources 未排除 Info.plist，可能被打包进 bundle（一般无害但会告警）")


def check_workflow():
    print("\n[6] GitHub Actions")
    p = os.path.join(ROOT, ".github/workflows/build.yml")
    if not os.path.isfile(p):
        return
    text = open(p, "r", encoding="utf-8").read()

    if "runs-on: macos" in text:
        good("跑在 macOS runner 上")
    else:
        bad("没有 macOS runner，编译不了 iOS")

    if "-scheme TingShu" in text:
        good("xcodebuild 使用的 scheme 与 project.yml 一致")
    else:
        bad("xcodebuild 的 scheme 与 project.yml 不一致")

    if "xcodegen generate" in text:
        good("会先 xcodegen generate")
    else:
        bad("没有生成 .xcodeproj 的步骤")

    if "upload-artifact" in text:
        good("产物会上传为 artifact")
    else:
        bad("没有上传产物，编译完拿不到 ipa")

    if "TingShu.ipa" in text:
        good("打包文件名为 TingShu.ipa")


def check_swift():
    print("\n[7] Swift 源码")
    files = ["%s/App.swift" % APP_NAME, "%s/WebShell.swift" % APP_NAME]
    for rel in files:
        p = os.path.join(ROOT, rel)
        if not os.path.isfile(p):
            continue
        src = open(p, "r", encoding="utf-8").read()

        # 粗略配平检查
        for open_ch, close_ch, label in [("{", "}", "大括号"), ("(", ")", "小括号")]:
            if src.count(open_ch) != src.count(close_ch):
                bad("%s %s不配平：%d 个 %s vs %d 个 %s"
                    % (rel, label, src.count(open_ch), open_ch, src.count(close_ch), close_ch))
            else:
                good("%s %s配平" % (rel, label))

        if "@main" in src or "struct RootView" in src:
            pass

    app = open(os.path.join(ROOT, APP_NAME, "App.swift"), "r", encoding="utf-8").read()
    for token, why in [
        ("AVAudioSession", "音频会话"),
        (".playback", "绕过静音拨片的关键分类"),
        (".spokenAudio", "人声朗读模式"),
        ("setActive(true)", "真正激活会话"),
        ("interruptionNotification", "来电打断后恢复"),
    ]:
        if token in app:
            good("App.swift 含 %s（%s）" % (token, why))
        else:
            bad("App.swift 缺少 %s —— %s" % (token, why))

    shell = open(os.path.join(ROOT, APP_NAME, "WebShell.swift"), "r", encoding="utf-8").read()
    for token, why in [
        ("allowsInlineMediaPlayback", "不要被接管成全屏播放器"),
        ("mediaTypesRequiringUserActionForPlayback", "允许无手势续播"),
        ("allowsAirPlayForMediaPlayback", "AirPlay"),
        ("contentInsetAdjustmentBehavior = .never", "安全区交给 CSS env()"),
        ("124.220.38.38", "默认服务器地址"),
        ('"/ui/"', "网页入口路径"),
        ("window.__ts", "锁屏按键转发到网页的落点"),
        ("NowPlayingCenter.shared.bind", "把锁屏命令接到 WebView 上"),
        ("pullState()", "网页状态变化时刷新锁屏卡片"),
    ]:
        if token in shell:
            good("WebShell.swift 含 %s（%s）" % (token, why))
        else:
            bad("WebShell.swift 缺少 %s —— %s" % (token, why))

    # —— 锁屏控制权（本轮核心） ——
    print("\n[8] 锁屏控制权")
    np_path = os.path.join(ROOT, APP_NAME, "NowPlaying.swift")
    if not os.path.isfile(np_path):
        bad("缺少 NowPlaying.swift —— 锁屏控制权只能靠它，锁屏卡片会被喜马拉雅抢走")
    else:
        good("有 NowPlaying.swift（锁屏控制权放在原生层）")
        npsrc = open(np_path, "r", encoding="utf-8").read()
        for open_ch, close_ch, label in [("{", "}", "大括号"), ("(", ")", "小括号")]:
            if npsrc.count(open_ch) != npsrc.count(close_ch):
                bad("NowPlaying.swift %s不配平：%d vs %d"
                    % (label, npsrc.count(open_ch), npsrc.count(close_ch)))
        for token, why in [
            ("MPRemoteCommandCenter", "接住锁屏/耳机/车机按键"),
            ("togglePlayPauseCommand", "锁屏上那颗大键"),
            ("changePlaybackPositionCommand", "锁屏拖进度条"),
            ("MPNowPlayingInfoCenter", "我们主动写锁屏卡片，不让别人占位"),
            ("MPMediaItemPropertyArtwork", "锁屏封面"),
            ("MPNowPlayingInfoPropertyElapsedPlaybackTime", "位置"),
            ("MPNowPlayingInfoPropertyPlaybackRate", "速率，系统据此自行插值走秒"),
            ("MPMediaItemArtwork", "封面包成 MPMediaItemArtwork"),
        ]:
            if token in npsrc:
                good("NowPlaying.swift 含 %s（%s）" % (token, why))
            else:
                bad("NowPlaying.swift 缺少 %s —— %s" % (token, why))

    # 🔴 这条 guard 是「锁屏卡片变成喜马拉雅」的直接元凶，绝不能回来
    if "isOtherAudioPlaying" in app:
        bad("App.swift 又出现了 isOtherAudioPlaying 的判断 —— "
            "它会让 keepAlive 在别人播放时直接放弃抢会话，锁屏卡片会被抢走")
    else:
        good("keepAlive 不再因 isOtherAudioPlaying 放弃抢会话")

    for token, why in [
        ("mediaServicesWereResetNotification", "音频服务被重置后重新配 category"),
        ("beginBackgroundTask", "进后台要一小段宽限，暂停时不让会话立刻失效"),
        ("endBackgroundTask", "宽限到期必须还回去，否则 App 会被 watchdog 杀掉"),
        ("NowPlayingCenter.shared.installCommands", "App 一启动就挂上锁屏命令"),
        ("NowPlayingCenter.shared.refresh", "回前台/打断结束后重写卡片"),
    ]:
        if token in app:
            good("App.swift 含 %s（%s）" % (token, why))
        else:
            bad("App.swift 缺少 %s —— %s" % (token, why))

    if "127.220" in shell:
        bad("源码里出现了 127.220.38.38 —— 这是历史踩过的坑，127 段是回环地址！")
    else:
        good("没有误写成 127.220.38.38")


def main():
    print("=" * 62)
    print(" iOS 工程自检    %s" % ROOT)
    print("=" * 62)

    check_required_files()
    check_plist()
    check_json_assets()
    check_icon()
    check_project_yml()
    check_workflow()
    check_swift()

    print("\n" + "=" * 62)
    print(" 通过 %d 项｜告警 %d 项｜失败 %d 项" % (ok, warn, fail))
    print("=" * 62)
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
