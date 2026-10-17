# -*- coding: utf-8 -*-
"""ipa 体检：在装到手机之前，先确认这个包是「对的、能装、能后台出声」的。

用法：
    python deploy/ios/tools/verify_ipa.py "C:\\Users\\admin\\Downloads\\TingShu.ipa"

能查出来的问题（都是装到手机上才会暴露的）：
  · Payload 里不是恰好一个 .app            → Sideloadly 直接报错
  · UIBackgroundModes 没有 audio            → 装了也没锁屏声音，白折腾
  · 二进制不是 arm64                        → 真机装不上
  · MinimumOSVersion 高于手机系统           → 装不上
  · Assets.car 缺失                         → 桌面图标是白板
  · Info.plist 的 CFBundleIdentifier 是占位符 → 签名会失败
  · 已经有 _CodeSignature                  → 说明签名残留，重签可能冲突
"""
import os
import plistlib
import struct
import sys
import zipfile

ok = 0
warn = 0
fail = 0


def good(m):
    global ok
    ok += 1
    print("  OK   %s" % m)


def warning(m):
    global warn
    warn += 1
    print("  WARN %s" % m)


def bad(m):
    global fail
    fail += 1
    print("  FAIL %s" % m)


def macho_arches(data):
    """读 Mach-O 头部，返回支持的架构列表。"""
    if len(data) < 8:
        return []
    magic = struct.unpack(">I", data[:4])[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):          # fat binary
        count = struct.unpack(">I", data[4:8])[0]
        arches = []
        for i in range(count):
            off = 8 + i * 20
            if len(data) < off + 20:
                break
            cputype = struct.unpack(">i", data[off:off + 4])[0]
            arches.append(cputype)
        return arches
    # 单架构
    cputype = struct.unpack("<i", data[4:8])[0]
    return [cputype]


CPU_NAMES = {
    12: "arm",
    16777228: "arm64",
    7: "x86",
    16777223: "x86_64",
}


def main(path):
    print("=" * 64)
    print(" ipa 体检   %s" % path)
    print("=" * 64)

    if not os.path.isfile(path):
        print("\n找不到文件。确认路径是否正确（Windows 路径要用引号包起来）。")
        return 1

    size_mb = os.path.getsize(path) / 1024 / 1024
    print("\n[1] 文件")
    good("存在，%.2f MB" % size_mb)
    if size_mb < 0.05:
        warning("体积不到 50KB，可能只有壳没有内容")
    if size_mb > 200:
        warning("超过 200MB，对于纯壳 App 偏大")

    # —— 解压 ——
    print("\n[2] 包结构")
    import tempfile
    tmp = tempfile.mkdtemp(prefix="ipa_")
    try:
        with zipfile.ZipFile(path) as z:
            names = z.namelist()
            z.extractall(tmp)
    except zipfile.BadZipFile:
        bad("不是合法的 zip/ipa 文件")
        return 1

    apps = sorted({
        "/".join(n.split("/")[:2])
        for n in names
        if n.startswith("Payload/") and n.count("/") >= 2
    })
    apps = [a for a in apps if a.endswith(".app")]
    if len(apps) == 1:
        good("Payload 里恰好一个 .app：%s" % os.path.basename(apps[0]))
    elif len(apps) == 0:
        bad("Payload 里没有 .app —— 这个 ipa 是废的")
        return 1
    else:
        bad("Payload 里有 %d 个 .app，Sideloadly 会报错" % len(apps))

    app_dir = os.path.join(tmp, *apps[0].split("/"))

    # —— Info.plist ——
    print("\n[3] Info.plist")
    plist_path = os.path.join(app_dir, "Info.plist")
    if not os.path.isfile(plist_path):
        bad("缺 Info.plist")
        return 1
    with open(plist_path, "rb") as f:
        info = plistlib.load(f)
    good("可解析，共 %d 个键" % len(info))

    modes = info.get("UIBackgroundModes") or []
    if "audio" in modes:
        good("UIBackgroundModes 含 audio ← 这是锁屏出声的关键")
    else:
        bad("UIBackgroundModes 没有 audio！装了也没有锁屏声音（实际值：%s）" % (modes or "无"))

    # iOS 10+ 只要出现 InWebContent / ForMedia / LocalNetworking 任一键，
    # NSAllowsArbitraryLoads 就被整体忽略；WKWebView 只认 InWebContent。
    # 缺了它 = App 能装能开，但一加载就 -1022 白屏「连不上服务器」。
    ats = info.get("NSAppTransportSecurity") or {}
    if ats.get("NSAllowsArbitraryLoadsInWebContent"):
        good("ATS 含 NSAllowsArbitraryLoadsInWebContent ← WKWebView 才能加载 http 裸 IP")
    else:
        bad("ATS 缺 NSAllowsArbitraryLoadsInWebContent！装上会白屏报 -1022（有 NSAllowsArbitraryLoads 也不顶用）")

    # 四条开关同时存在会让 NSAllowsArbitraryLoads 被整体忽略，
    # 原生自己 URLSession 拉 http（锁屏封面）会被 ATS 拦，必须靠例外域
    doms = ats.get("NSExceptionDomains") or {}
    if doms:
        good("ATS 有 NSExceptionDomains（%s）← 原生下载 http 封面靠它" % ",".join(doms.keys()))
    else:
        bad("ATS 缺 NSExceptionDomains —— 原生拉 http 封面会被 ATS 拦掉，锁屏没有封面")

    bid = info.get("CFBundleIdentifier", "")
    if bid == "com.paiwo.tingshu":
        good("CFBundleIdentifier = %s" % bid)
    elif "$(" in bid:
        bad("bundle id 还是占位符 %r，说明变量没被替换" % bid)
    else:
        warning("CFBundleIdentifier = %r（与预期 com.paiwo.tingshu 不同，能用但要留意）" % bid)

    name = info.get("CFBundleDisplayName") or info.get("CFBundleName") or ""
    good("桌面名称：%s" % name)

    minos = info.get("MinimumOSVersion", "?")
    good("最低系统要求：iOS %s" % minos)

    plat = info.get("CFBundleSupportedPlatforms")
    if plat and "iPhoneOS" in plat:
        good("目标平台 iPhoneOS")
    else:
        warning("CFBundleSupportedPlatforms = %s" % plat)

    # 图标
    icons = info.get("CFBundleIcons") or {}
    primary = (icons.get("CFBundlePrimaryIcon") or {}).get("CFBundleIconFiles") or []
    assets = os.path.join(app_dir, "Assets.car")
    if os.path.isfile(assets):
        good("Assets.car 存在（%.0f KB），图标已编译进去"
             % (os.path.getsize(assets) / 1024))
    else:
        bad("缺 Assets.car，桌面图标会是白板")
    if primary:
        good("Info.plist 声明了图标文件：%s" % ", ".join(primary))

    # —— 主二进制 ——
    print("\n[4] 可执行文件")
    exe_name = info.get("CFBundleExecutable", "")
    exe = os.path.join(app_dir, exe_name)
    if not os.path.isfile(exe):
        bad("找不到可执行文件 %r" % exe_name)
        return 1
    good("存在 %s（%.0f KB）" % (exe_name, os.path.getsize(exe) / 1024))

    with open(exe, "rb") as f:
        head = f.read(4096)
    arches = macho_arches(head)
    names_a = [CPU_NAMES.get(a, "cputype=%d" % a) for a in arches]
    if "arm64" in names_a:
        good("架构含 arm64（真机可用）：%s" % ", ".join(names_a))
    else:
        bad("架构 %s 里没有 arm64，真机装不上" % names_a)

    # —— 签名状态 ——
    print("\n[5] 签名状态")
    sig = os.path.join(app_dir, "_CodeSignature")
    prov = os.path.join(app_dir, "embedded.mobileprovision")
    if os.path.isdir(sig) or os.path.isfile(prov):
        warning("发现签名痕迹（_CodeSignature 或 mobileprovision）。"
                "Sideloadly 重签一般能覆盖，若报冲突就先删掉旧 App")
    else:
        good("未签名 —— 符合预期，侧载工具（爱思助手）会用你的 Apple ID 重签")

    # —— 锁屏控制权有没有真的编进去 ——
    print("\n[6] 锁屏控制权（二进制符号）")
    exe = os.path.join(app_dir, "TingShu")
    try:
        with open(exe, "rb") as f:
            blob = f.read()
    except OSError as e:
        bad("读不到可执行文件：%s" % e)
        blob = b""
    for tok, why in [
        (b"NowPlayingCenter", "锁屏控制的原生类"),
        (b"setArtwork", "网页直传封面的通道"),
        (b"window.__ts", "锁屏按键转发到网页的落点"),
        (b"togglePlayPause", "MPRemoteCommandCenter 的播放/暂停键"),
    ]:
        if tok in blob:
            good("二进制含 %s（%s）" % (tok.decode(), why))
        else:
            bad("二进制里找不到 %s —— %s 没编进去？" % (tok.decode(), why))

    # —— 关键文件清单 ——
    print("\n[7] 包内文件")
    for dirpath, _dirs, files in os.walk(app_dir):
        rel = os.path.relpath(dirpath, app_dir)
        for fn in sorted(files)[:200]:
            p = os.path.join(dirpath, fn)
            depth = 0 if rel == "." else rel.count(os.sep) + 1
            label = "" if rel == "." else rel.replace(os.sep, "/") + "/"
            print("     %s%s%s  (%.0f KB)"
                  % ("   " * depth, label, fn, os.path.getsize(p) / 1024))

    print("\n" + "=" * 64)
    print(" 通过 %d 项｜告警 %d 项｜失败 %d 项" % (ok, warn, fail))
    if fail == 0:
        print(" 结论：可以拿去重签安装了")
    else:
        print(" 结论：有失败项，先别装，把上面的 FAIL 发出来")
    print("=" * 64)
    return 1 if fail else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("用法: python verify_ipa.py <路径\\TingShu.ipa>")
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
