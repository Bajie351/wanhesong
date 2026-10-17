# 听书 App 续签备忘

## 有效期

- 当前签名 **2026-10-24 17:39 到期**（免费账号固定 7 天）
- 到期现象：点图标**一闪就退**。不是 App 坏了，重签即可
- 建议 **10-23 就重签**，别等到闪退

## 文件放在哪

```
C:\Users\admin\Documents\听书App\
    TingShu-未签名-20261017.ipa    204 KB  ← 重签用这个（干净的原包）
    TingShu-已签名-20261017.ipa    215 KB  ← 当前手机上装的那份，备份
```

> ⚠️ 每次重签都用**未签名**那个原包，不要拿已签名的再去签。

## 拿 ipa 的免登录直链

GitHub 的 Actions 产物**必须登录才能下载**，本机没装 `gh` 就取不到。
所以流水线每次编译完会额外产出一个 Release，tag 固定为 `latest-ipa`：

```
https://github.com/Bajie351/wanhesong/releases/download/latest-ipa/TingShu.ipa
```

公开仓库的 Release 附件可以匿名直链下载，地址永远不会变。
**只有改了原生层才需要重新出包**，改界面（`app.js` / `style.css` / `index.html`）不用。

## 续签步骤（不用重新编译，约 5 分钟）

1. **先关掉 iKuuuVPN** —— 签名必须直连 Apple，开代理会报 503
2. 手机连电脑，**保持解锁亮屏**（自动锁屏先改成 5 分钟）
3. 爱思助手 → `工具箱` → `IPA 签名`
4. `添加 IPA 文件` → 选 `TingShu-未签名-20261017.ipa`
5. **先在手机上拿码**（关键）：
   设置 → 顶部头像（Apple 账户）→ **登录与安全性** → **获取验证码**
   记住 6 位数字，**30 秒内**填进电脑
6. 勾选 IPA + Apple ID `1340307403@qq.com` → `开始签名`
7. `我的设备` → `应用` → `导入安装`
   选 `C:\Users\admin\Documents\` 下**时间最新**的那个签名包
8. 手机上：
   - 设置 → 通用 → **VPN 与设备管理** → 点 `礼康 赵` → **信任**
   - 设置 → 隐私与安全性 → 最底 → **开发者模式** → 打开 → **重启**

## 三个必踩的坑

| 现象 | 原因 | 解决 |
|---|---|---|
| 装错版本 | 签名输出会重名成 `TingShu(1).ipa`、`TingShu(2).ipa`… | 认**修改时间最新**的，别只看文件名 |
| 「无法安装此 App，因为无法验证其完整性」 | 换证书重签后 iOS 不接受覆盖安装 | **先删旧 App + 重启手机**，再装 |
| 「验证码不正确」 | 用了旧码，或从手机弹码到填进电脑隔太久 | 先在手机**主动获取验证码**，再回电脑填 |

## 想改界面？不用重签

界面是网页，全在服务器上：

```
/opt/abs-ui/app/app.js      交互逻辑
/opt/abs-ui/app/style.css   样式
/opt/abs-ui/app/index.html  结构 + 版本号
```

改完把 `index.html` 里的 `?v=` 往后推一位，手机把 App **从后台划掉重开**即可看到新界面。

**只有**改 `App.swift` / `WebShell.swift` / `Info.plist`（原生层）才需要重新走 GitHub Actions 编译 + 爱思重签。

## 服务器地址

| 用途 | 地址 |
|---|---|
| 浏览器打开 | `http://124.220.38.38/ui/` |
| AudioBooth 填这个 | `http://124.220.38.38`（只到 IP，不带 `/ui/`） |
| 账号 | `root` / `paiwo@123` |

## 网络要求的矛盾（必须记住）

| 操作 | 需要 |
|---|---|
| `git push` / 下载 GitHub 产物 | **开 iKuuuVPN** |
| 爱思签名 / Apple 授权 | **关 iKuuuVPN** |
| 手机访问 `124.220.38.38` | 都行（国内服务器） |

---

## 这次踩过的坑（留给以后）

- **Windows 根证书库被精简过**，`LocalMachine\Root` 只有 48 张、**零 Apple 证书**
  → 所有侧载工具在 TLS 阶段就失败。已装 `Apple Root CA` / `-G2` / `-G3` 修复
- **Sideloadly 0.70.1 不可用**：它用 `com.apple.dt.Xcode` 身份，Apple 直接返回 503
- **AltServer 1.8 不可用**：报 `-22411`，2FA 会话建立不起来（手机弹码、电脑上没有输入框）
- **唯一可用：爱思助手（i4Tools）**
- **App 白屏**是 ATS 配置错：WKWebView 只认 `NSAllowsArbitraryLoadsInWebContent`，
  只写 `NSAllowsArbitraryLoads` 等于没写（有 `LocalNetworking` 在场时会被整体忽略）
