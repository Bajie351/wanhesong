# 听书 · 打包成真 App（IPA）

把自建服务器上的那套网页，装进一个**真正的 iOS App** 里。

---

## 为什么非得这么做

先说结论，免得白折腾：

| 场景               | 锁屏 / 后台播放 | 说明                                 |
| ---------------- | --------- | ---------------------------------- |
| Safari 打开网页      | ✅ 有声音     | Safari 是系统 App，有完整的媒体权限            |
| 添加到主屏幕（PWA）      | ❌ **没声音** | iOS 17+ 的 WebKit 限制，网页层改不了         |
| **本工程打包的原生 App** | ✅ 有声音     | 原生层拿得到 `AVAudioSession(.playback)` |

Apple 只允许声明了 `UIBackgroundModes: audio` + 把音频会话设成 `.playback` 的**原生 App** 在锁屏时出声。  
这两样东西在网页 JS 里拿不到 —— `navigator.audioSession.type = 'playback'` 在 PWA 独立窗口下**不足以**突破。

所以这个工程做的事很简单：**界面 100% 还是那套网页，只加一个极薄的原生壳把音频权限拿回来。**

壳里额外做了三件实用的事：

- `AVAudioSession` 设成 `.playback` + `.spokenAudio` —— **绕过手机侧面的静音拨片**（听书 App 必须）
- 来电 / 闹钟打断后自动重新激活会话 —— 不然会出现「进度在走但没声音」的假死
- 全屏 + 把安全区正确传给 CSS，页面里 `env(safe-area-inset-*)` 照常生效，不用重画界面

---

## 目录里都是什么

```
deploy/ios/
├── project.yml                     XcodeGen 工程描述（纯文本，代替 .xcodeproj）
├── .github/workflows/build.yml     GitHub Actions：在云端 Mac 上编译并打出 ipa
├── .gitignore
├── TingShu/
│   ├── App.swift                   入口 + AppDelegate + 音频会话管理
│   ├── WebShell.swift              WKWebView 容器（界面本体）
│   ├── Info.plist                  后台播放 / ATS / 启动屏 / 竖屏
│   └── Assets.xcassets/            AppIcon(1024) + 配色
└── tools/
    ├── make_appicon.py             生成 1024 图标（无 alpha）
    └── verify_project.py           本地静态自检，51 项
```

**没有 `.xcodeproj` 文件是故意的** —— 你在 Windows 上，没有 Xcode 可以手点「新建工程」。  
`project.yml` 是纯文本，云端 Mac 上跑一句 `xcodegen generate` 现场生成工程，改起来也清爽。

---

## 一次性准备

**先记住文件在你电脑上的位置：**

```
C:\Users\admin\WorkBuddy\2026-10-14-20-13-12\deploy\ios\
```

后面「第 2 步」要做的就是把**这个目录里的东西**拖到 GitHub 上去。

| 需要什么             | 说明                                                                   |
| ---------------- | -------------------------------------------------------------------- |
| GitHub 账号        | 你已有                                                                  |
| 仓库必须是 **public** | 🔴 **这条最重要**：macOS runner 对私有仓库按 **10 倍**计费，免费额度撑不住；public 仓库完全免费不限量 |
| Apple ID         | 免费开发者账户即可（7 天有效期、最多 3 个 App）                                         |
| Windows 电脑       | 装 Sideloadly 签名                                                      |
| 数据线              | 手机连电脑                                                                |

---

## 第 1 步：建一个空的 public 仓库

1. 打开 <https://github.com/new>
2. **Repository name**：`tingshu-ios`（名字随意）
3. **Visibility** 选 **Public** ← 别选错
4. 下面的 `Add a README file` / `.gitignore` / `license` **全部不要勾**
5. 点 **Create repository**

建完会看到一页「Quick setup」，上面有个地址，形如：

```
https://github.com/你的用户名/tingshu-ios.git
```

记下它。

---

## 第 2 步：把本目录的文件传上去

### 方式 A：网页拖拽（最省事，推荐）

1. 在仓库页面点 **uploading an existing file**
2. 打开资源管理器的 `deploy\ios\` 目录
3. 全选里面的**内容**（不是选中 `ios` 文件夹本身）拖进浏览器
4. 🔴 **`.github` 和 `.gitignore` 是隐藏项，拖拽经常会漏**。传完后一定要检查仓库根目录里有没有 `.github/workflows/build.yml`
   - 如果没传上去：点 **Add file → Create new file**，文件名输入 `.github/workflows/build.yml`，把本地这个文件的内容粘进去
5. 底部填一句说明，点 **Commit changes**

### 方式 B：命令行（如果你本机有 git）

```bash
cd deploy/ios
git init
git add -A
git commit -m "听书 iOS 原生壳"
git branch -M main
git remote add origin https://github.com/你的用户名/tingshu-ios.git
git push -u origin main
```

---

## 第 3 步：等它自己编译

上传完，GitHub 会**自动开始编译**（因为 `build.yml` 里配了 push 到 main 就触发）。

1. 打开仓库页面 → 点顶部 **Actions**
2. 会看到一条黄色的 `Build IPA` 正在跑，点进去
3. 点 **build** 这个 job 可以看实时日志

正常耗时 **3～6 分钟**。你会依次看到这些步骤亮绿勾：

```
取代码 → 显示编译环境 → 安装 XcodeGen → 生成 Xcode 工程
→ 编译（不签名）→ 校验产物 → 打包成 ipa → 上传安装包
```

**如果没自动触发**：点 **Actions** → 左侧选 `Build IPA` → 右边 **Run workflow** → **Run workflow**。

---

## 第 4 步：下载 ipa

编译成功后，在那次运行的**页面最下面**找到 **Artifacts** 区域：

1. 点 **TingShu-ipa** 下载
2. 得到一个 `TingShu-ipa.zip`
3. **解压它**，里面就是 `TingShu.ipa`

> GitHub 的 artifact 永远是 zip 包，必须解压一层才是 ipa。别直接把 zip 拖进 Sideloadly。

---

## 第 5 步：用 Sideloadly 签名安装

未签名的 ipa 是装不上的，必须用**你自己的 Apple ID** 重签一次。

### 5.1 装 Sideloadly

1. 打开 <https://sideloadly.io> ，下载 Windows 版（当前是 `sideloadly_windows.exe` 之类）
2. **先装 iTunes**（Apple 官网下载的版本，不要用 Microsoft Store 那个）：<https://www.apple.com/itunes/download/win64>
   - Sideloadly 靠 iTunes 的驱动才能和 iPhone 通信
   - 已经装了 iTunes 就跳过
3. 装完 **重启电脑**（驱动才生效，这步别省）

### 5.2 连接手机

1. iPhone 用数据线连电脑
2. 手机弹出「要信任此电脑吗」→ 点 **信任** → 输入锁屏密码
3. 打开 Sideloadly，左上角 **iOS Device** 下拉里能看到你的手机名字，就说明连上了
   - 看不到就把 iTunes 打开确认能识别到设备

### 5.3 签名

1. **IPA 那一栏**：把 `TingShu.ipa` 拖进去（或者点右边的文件夹图标选）
2. **Apple ID 那一栏**：填你的 Apple ID 邮箱
3. 点 **Start**
4. 弹窗要密码 → 填 Apple ID 密码
   - 开启了双重认证的，会弹一个「请输入发到你设备上的验证码」，填 6 位数字
5. 等进度条走完，日志里出现 `✅ Done` / `Installation complete` 就成了

手机上应该已经出现白色播放三角 + 橙红渐变底色的「听书」图标。

---

## 第 6 步：手机上还要开两道闸

装完直接点是打不开的，会提示「未受信任的开发者」。两道都要过：

### ① 信任开发者证书

**设置 → 通用 → VPN 与设备管理 → 开发者 App → 点你的 Apple ID → 信任**

### ② 打开开发者模式（iOS 16 及以上必须有）

**设置 → 隐私与安全性 → 拉到最底 → 开发者模式 → 打开 → 重启手机 → 重启后弹窗点「打开」**

> 找不到「开发者模式」这一项？说明还没连过 Xcode 类工具。用 Sideloadly 装过一次之后就会出现，或者先重启一次手机再看。

做完这两步，点开 App 就能用了。

---

## 首次打开会看到什么

**登录页。** 这是正常的 —— App 的 WebView 有自己独立的存储，和 Safari 不共享 Cookie。

用你服务器上的账号登：

- `root` / `paiwo@123`（管理员）
- 或 `赵康`（你自己设的口令）

登录一次之后，token 存在 App 本地，下次打开免登录。

**收听进度不会丢** —— 进度存在服务器数据库里，和用哪个客户端、哪台设备都无关。就算你把 App 删了重装，进度还在。

---

## 7 天到期怎么办

免费的 Apple ID 签名**只有 7 天**。到期后现象是：**点图标闪一下就退**。

续签流程（3 分钟）：

1. 手机连电脑，开 Sideloadly
2. 把 `TingShu.ipa` 再拖进去（ipa 一直留着，别删）
3. 点 Start，走一遍，完事

**不用重新下载 ipa**，也不用重新进 GitHub Actions。同一个 ipa 可以反复签。

> ⚠️ 如果 Sideloadly 报「已存在相同 Bundle ID 的 App，无法安装」，它会让你先删掉旧 App。删了之后登录态会丢，需要重新登录一次 —— 但**收听进度在服务器上，不受影响**。
>
> 想彻底摆脱 7 天限制，可以装 **AltStore**（免费）做自动续签，需要一台常开的电脑在同一 Wi-Fi 下。

---

## 想改服务器地址

画面加载失败时，App 会显示一个「连不上服务器」的界面，上面有 **修改服务器地址** 按钮，填到 `/ui/` 为止就行。

只写 IP 也可以，App 会自动补成 `http://IP/ui/`。

想恢复默认：同一个界面里点 **恢复默认地址**。

> 🔴 **注意区分两个入口**：
>
> - **本 App / 浏览器** → `http://124.220.38.38/ui/`（带 `/ui/`）
> - **AudioBooth 官方 App** → `http://124.220.38.38`（不带 `/ui/`，它要探测 `/status`）

---

## 排错

| 现象                                         | 原因                                           | 怎么办                                                  |
| ------------------------------------------ | -------------------------------------------- | ---------------------------------------------------- |
| Actions 里没有 `Build IPA` 这一项                | `.github/workflows/build.yml` 没传上去（隐藏文件夹常被漏） | 用 **Add file → Create new file** 手动建这个路径，粘贴内容后再提交    |
| Actions 报 `Resource not accessible` / 账单警告 | 仓库是 **private**                              | Settings → 最下面 **Change visibility → Make public**   |
| Actions 报 `xcodegen: command not found`    | brew 那步挂了                                    | 重跑一次；日志里看 `安装 XcodeGen` 是否红叉                         |
| 编译报 `No such module 'WebKit'`              | 平台选错了                                        | 检查 `project.yml` 里 `platform: iOS` 是否被改掉             |
| 编译报 `AppIcon` 尺寸/alpha 错误                  | 图标被替换过                                       | 重跑 `python tools/make_appicon.py`，必须 1024×1024 且 RGB |
| Sideloadly 认不到手机                           | 驱动没装好                                        | 装 Apple 官网版 iTunes → 重启电脑 → 再插线                      |
| Sideloadly 报 `Unable to sign`              | Apple ID 密码错 / 需要 App 专用密码                   | 到 appleid.apple.com 生成「App 专用密码」填进去                  |
| 装上了但点开闪退                                   | 没开开发者模式 / 证书没信任                              | 走上面第 6 步两道闸                                          |
| 一次装了两个 App 就失败                             | 免费账号最多 3 个签名 App                             | 删掉不用的                                                |
| App 里能播放但锁屏还是没声音                           | 音频会话没激活                                      | 先在 App 里点一次播放（要真的出声），再锁屏                             |
| 打开后是 ABS 官方界面，不是自研那套                       | 地址少了 `/ui/`                                  | 设置里改成 `http://124.220.38.38/ui/`                     |

---

## 本地自检（改了代码之后跑一下）

Windows 上编译不了，但结构性问题可以先扫出来：

```bash
python deploy/ios/tools/verify_project.py
```

会检查 51 项：plist 合法性、`UIBackgroundModes: audio` 在不在、ATS 放没放、图标有没有 alpha、scheme 名对不对、Swift 括号配不配平、默认地址有没有又打成 `127.220`……

全绿再推 GitHub，省一轮云编译。

---

## 备份方案（GitHub Actions 不好使时）

| 方案                          | 说明                                                               |
| --------------------------- | ---------------------------------------------------------------- |
| **Codemagic**               | 对 public 仓库免费 500 分钟/月，配置里把 `xcodebuild` 那段照搬即可                  |
| **MacinCloud / MacStadium** | 租云端 Mac，远程桌面上去用 Xcode 直接编译，按小时计费                                 |
| **借一台 Mac**                 | 装上 Xcode → `xcodegen generate` → 打开工程 → 手机连上 → 直接 Run。免费账号同样 7 天 |

---

## 一句实话

这个壳解决的是**锁屏/后台出声**。界面的所有细节、配色、交互、搜索、续播，全部还在服务器上那套网页里 ——  
**改界面不用重新打包，改完 `/opt/abs-ui/app` 里的文件，App 下次打开就是新的。**

只有当你需要动 `App.swift` / `WebShell.swift` / `Info.plist` 这些原生层的东西时，才需要重新走一遍 Actions。

---

## 装好之后，请把这四项结果告诉我

这是本方案唯一没法在 Windows 上验证的部分，需要真机实测：

1. **锁屏播放有没有声音** ← 整个打包的核心目的，成败就看这条
2. **锁屏卡片上的封面和标题对不对**（可能显示「未知」，那是 WebKit 没把 Media Session 信息推给系统，可以改用原生 `MPNowPlayingInfoCenter` 补）
3. **锁屏卡片的上一集/下一集按钮好使吗**
4. **页面顶部标题有没有被状态栏压住**（如果被压住，说明 `env()` 那条链路在 WKWebView 里没生效，日志里会打印 `[SafeArea] env-failed`）

哪条不对，我针对性改一两个文件，你重新走一次 Actions 就行 —— 通常不用动网页。
