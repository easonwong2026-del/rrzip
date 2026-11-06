# rrzip v2.11.0 PRD：系统集成加固与发布就绪

版本：v1（2026-11-06） · 基线：v2.10.0（`b5de5d2`） · 目标：v2.11.0
参照：v2.10.0 交付复核报告（2026-11-06）+ 本轮源码复核
状态标记：✅ 已交付 · 🔄 进行中 · ⬜ 未开始

> **维护规则**：本文件是 v2.11.0 期间唯一进度源。`PRD-v2.8.0.md` 冻结为历史，不再追加。
> 每合并一个 PR，回写 §2（核查表）、§9（验收）、§12（交付顺序）三处。文档落后于代码视为没做完。

---

## 0. 一句话目标

**不加新功能，把 v2.8.0–v2.10.0 铺开的三个系统接缝焊死**：

1. 访达右键不再凭后缀猜格式、不再静默覆盖、不再没有结果反馈。
2. 双模式的「自动收起」从「代码存在但永远不触发」变成真能触发。
3. 双击 / 访达打开不再被后缀拦截后静默丢弃文件。

判定标准只有一条：**让一个非开发者用一整天，不丢一个文件、不出现「点了没反应」**。

---

## 1. 为什么这一版是加固版

v2.8.0–v2.10.0 四批改造把架构立住了：双模式共用 `ArchiveModel`、`ArchiveService` 统一引擎、暂存冲突策略、FinderSync 落地。产品风险已经从「功能缺失」换成「功能存在但不可信」。

四条证据（均已核对源码，见 §2）：

| 证据 | 位置 | 后果 |
|---|---|---|
| 访达右键自己维护 10 个后缀 | `FinderSync.swift:12` | 改名的包、`.tar.zst`、`.001` 分卷全都不认 |
| 解压固定 `-y` | `FinderSync.swift:62` | 静默覆盖同名文件，无提示、无回收站 |
| 右键动作 `try? process.run()` 后不管 | `FinderSync.swift:103` | 成功失败都不出声，用户以为没反应 |
| 完整模式 `minSize = 1020`，自动收起判据 `< 760` | `ContentView.swift:656` / `Model.swift:667` | 自动收起永远不可能触发 |
| `application(_:open:)` 仍按后缀前置过滤 | `ContentView.swift:369` | 与 v2.8.0 的 `OpenGate` 修复直接冲突，且失败时静默 return |

**功能增量只保留两项**（不含外层压缩、表头列显示），其余全部是修复与发布准备。理由是：现在再加功能，只会让上面这些不可信的面继续扩大。

---

## 2. 现状核查（本轮源码复核）

### 2.1 上轮报告已确认、本版承接

| 问题 | 证据 | 影响 | 处置 |
|---|---|---|---|
| 右键菜单固定 4 项 | `FinderSync.swift:35-43` 无条件构造 | 选文件也显示「解压到此处」 | ✅ PR1 已改动态菜单 |
| 后缀硬编码 10 个 | `FinderSync.swift:12-14` | 与 `FormatDetector` 双份真相 | ✅ PR1 已删，改走 `OpenGate` |
| `-y` 静默覆盖 | `FinderSync.swift:62` | **可能丢用户文件** | ✅ PR2 已改 `-aos` / `--keep-old-files`，解压前统计冲突 |
| 无进度 / 结果反馈 | `FinderSync.swift:103-109` | 「点了没反应」 | ✅ PR2 已加通知 + JSONL 任务日志 |
| 多选只处理第一个 | `FinderSync.swift:54`、`openSelection` | 多选打开丢文件 | ✅ PR1 已改多选传递 + 主界面提示 |
| 直接用 7zz 绕过 ArchiveService | `FinderSync.swift:24-27` | 加密包、DMG 行为不一致 | ✅ PR2 已走 `ArchiveService`，并修好扩展内 7zz 定位 |
| 双模式 minSize / 阈值冲突 | `ContentView.swift:654-656`、`840-842` 与 `Model.swift:667` | 自动收起不可达 | ✅ PR3 已修（下限解耦 560，阈值改推导） |
| 设置中心无 FinderSync 状态与菜单配置 | `SettingsView.swift:206-213` 文案仍是「2 个服务」 | 功能已上线，设置页没跟上 | → 模块 D（⬜ P1） |
| PRD 标注 2.10.0「待发」 | `PRD-v2.8.0.md:332` | 文档与发布脱节 | → 模块 E（⬜） |
| FinderSync 直推 main 无 PR | `b5de5d2` 单提交 | 破坏 PR + CI 纪律 | → 模块 E（⬜） |

### 2.2 本轮新增发现（报告之外）

| # | 发现 | 证据 | 严重度 |
|---|---|---|---|
| N1 | `application(_:open:)` 用 `ArchiveKind.isArchive(ext:)` 前置过滤；不匹配直接 `return`，无提示 | `ContentView.swift:368-372` | **P0**：这是 v2.8.0 修过的同一类问题在另一入口复发 · ✅ PR1 已改走 `OpenGate`，Services 同步 |
| N2 | 右键解压加密包：`-y` 无法回答密码，7zz 在无 tty 下失败，进程退出码无人读 | `FinderSync.swift:62,103` | P0：静默失败 · ✅ PR2 已改为解压前 `list` 预判，直接报「需要密码」 |
| N3 | 跨目录多选压缩：输出目录取 `selected.first` 的父目录，其余文件被搬进第一个文件所在目录 | `FinderSync.swift:67-75` | P1：落点不可预期 |
| N4 | 扩展把整个 `/` 挂进 `directoryURLs` | `FinderSync.swift:32` | P1：每个目录都问菜单，含外置卷/网络卷 |
| N5 | CI 产物校验只验 `ArchivePreview.appex`，没验 `ArchiveFinder.appex` | `.github/workflows/ci.yml` 校验产物步骤 | P1：扩展构建坏了 CI 不红 |
| N6 | 完整模式窗口内容侧 `.frame(minWidth: 360)`，三栏在 1000 宽时已开始挤压 | `ContentView.swift:434-440` | P2：与模块 B 阈值确定相关 |

### 2.3 承接 v2.8.0 未闭环项

| ID | 项 | 状态 |
|---|---|---|
| T3/T4 | 双模式切换后目录、选中、滚动位置保留 | 逻辑成立，**实机未回归** |
| T12 | 8000 条目包来回切 10 次 < 300ms | **未压测** |
| T8 | 批量 4 包（含 dmg、加密 7z）与单包结果一致 | 引擎已统一，**未对照** |

这三项在 v2.11.0 必须闭环，否则「双模式已交付」这句话站不住。

---

## 3. 模块 A：FinderSync 重做（P0，本版核心）

### 3.1 设计原则

把扩展拆成**判定层**和**执行层**，判定层纯函数、可单测，执行层才碰文件系统。

```
menu(for:)  →  FinderMenuBuilder.actions(for: [URL])     ← 纯逻辑，编进测试
                       ↓
              FinderJob（可序列化描述）                    ← 可落盘、可日志
                       ↓
              ArchiveService / SevenZip                    ← 同一套引擎选择
                       ↓
              JobReporter（通知 + 日志）                    ← 结果必须有人看见
```

这条分层不是为了好看：判定层抽成纯函数后，上面所有菜单矩阵都能进 `Tests/main.swift`，不必每次改完手动点访达。

### 3.2 动态菜单矩阵

`menu(for:)` 内同步调用 `FIFinderSyncController.default().selectedItemURLs()`，据此生成菜单。**不缓存选择**，避免菜单与实际选择不同步。

| 选择态 | 判定 | 菜单（括号内为默认开关） |
|---|---|---|
| 单个压缩包 | 1 项且 `OpenGate.decide == .open` | 用 rrzip 打开（开）· 解压到此处（开）· 解压到「包名」文件夹（关） |
| 多个压缩包 | 全部 `.open`，≥2 项 | 用 rrzip 打开第一个（开）· 全部解压到各自目录（开）· 分别解压到同名文件夹（关） |
| 仅普通文件 / 文件夹 | 无 `.open` 项 | 压缩为 ZIP（开）· 压缩为 7Z（关）· 分别压缩（开） |
| 混合选择 | 有 `.open` 也有普通项 | 解压到此处（仅包，开）· 压缩为 ZIP（仅普通项，开）· 分别压缩（开） |
| 无法识别 | `OpenGate` 返回 `.unsupported` | 「X 暂不支持」禁用项，灰显 + 说明 |

规则：

- 所有动作进 `rrzip` 二级菜单，默认开；设置里可改为直接挂一级（默认不挂，避免污染访达右键）。
- 菜单标题带数量，让用户看见系统识别对了：「解压 3 个压缩包到此处」「压缩 2 个项目为 ZIP」。
- 选择项超过 50 个时，标题只写「N 个项目」，避免菜单过宽。
- 加密包不解压，只给「用 rrzip 打开」（需要输密码）。

### 3.3 多选语义（必须诚实）

| 动作 | 多选行为 |
|---|---|
| 用 rrzip 打开 | **只开第一个**，主界面浮出一条提示「另有 N 个压缩包未打开，可拖入窗口批量处理」 |
| 解压到此处 | 每个包解到**各自**所在目录，不合并 |
| 解压到「包名」文件夹 | 同上，但各自建同名子目录 |
| 压缩为 ZIP | 合并为一个包，落在第一个选中项的父目录 |
| 分别压缩 | 每个各生成一个 ZIP，落在各自父目录 |

跨目录多选（访达搜索结果）时，「压缩为 ZIP」的落点写进通知文案：「已生成 归档.zip 到『下载』」，不让用户猜。

不做的：假装支持多包同时打开。主窗口是单包模型，这一点 v2.8.0 已经立过规矩（不做多标签），继续守住。

### 3.4 防覆盖：先算后写，绝不靠 `-y`

```
1. ArchiveService.list(url, password: nil)
   ├─ 抛 needsPassword → 通知「需要密码，请在 rrzip 中打开」，结束，不建任何目录
   └─ 抛其它错误     → 通知「无法读取，可能已损坏」，结束
2. 算目标目录 dst
   ├─ 默认：源目录 / 「包名」
   └─ dst 已存在 → 按设置策略
3. ArchiveService.extract(url, entries: [], to: dst)
```

冲突策略（设置 → Finder → 解压）：

| 策略 | 行为 | 默认 |
|---|---|---|
| 新建文件夹 | `包名 2`、`包名 3`…（与 `uniqueOutput` 同规则） | ✅ 已实现（PR2） |
| 目录内同名跳过 | `-aos` / `--keep-old-files`，跳过数进通知 | ✅ 已实现（PR2） |
| 合并并改名 | 解进已有目录，同名文件自动 `名称 2.ext` | ⬜ v2.12（需先解到临时目录再合并，成本高） |
| 逐个询问 | 拉起主 app 显示冲突清单 | ⬜ v2.12 |

`-y` 已从扩展里移除。兜底用 `-aos`（跳过已存在），并在通知里报「跳过 N 个同名文件」——**跳过可解释，覆盖不可逆**。

`ArchiveService.extract` 增加参数：

```swift
enum ArchiveConflictPolicy { case overwrite, skip }
static func extract(_ url: URL, entries: [String], to destination: URL,
                    password: String?,
                    onConflict: ArchiveConflictPolicy = .overwrite) throws
```

默认 `.overwrite` 保持主程序现有行为（用户主动解压，语义不变）；访达右键一律传 `.skip`。
批量、暂存导出将来复用同一参数，避免出现第二套冲突逻辑。

### 3.5 结果反馈：三种结局都要出声

已实现（PR2）：

```swift
struct JobOutcome {                    // 一次任务的结果，纯数据
    var succeeded: [String]
    var skippedFiles: Int              // 因同名被跳过的文件数，不是包数
    var needsPassword: [String]
    var failed: [Failure]              // name + reason
    var destination: URL?
}

struct JobRecord: Codable {            // 落日志的一行
    let id: String
    let op: String                     // extractHere / extractToFolder / compressZip…
    let startedAt: Date
    let finishedAt: Date
    let payload: Payload               // 上面五个字段的扁平化
}
```

通知（`UNUserNotificationCenter`，主 app 申请授权，扩展只投递）：

| 结局 | 标题（实际文案） | 副标题 |
|---|---|---|
| 全部成功 | `解压完成 · 3 个` | `位置：下载/` |
| 有跳过 | `解压完成 2 个，跳过 3 个同名文件` | `位置：下载/` |
| 需要密码 | `需要密码 · secret.7z` | `加密包需要在 rrzip 里输入密码后再解压` |
| 全部失败 | `解压失败 · bad.zip` | 失败原因 |
| 部分失败 | `解压完成 1 个，1 个失败` | 失败原因 |

未做（写进 PRD 但不进本版）：
- 通知按钮（「在访达中显示」）：需要注册 `UNNotificationAction` 并在主程序处理回调，留 v2.12。
- 长任务开始时的「正在解压…」即时通知：会在大包解压时刷屏，等 XPC 任务服务一起做（§13 风险 1）。

`JobRecord` 追加写入 `~/Library/Application Support/rrzip/finder-jobs.log`（JSONL，保留 200 条）；
设置页「访达任务记录」在 PR4 读 `FinderJobLog.recent(20)` 展示。

### 3.6 统一格式识别（编译期共享）

`build.sh` 的 FinderSync 编译行改成与 QuickLook 扩展同一手法：

```bash
xcrun swiftc ... -module-name ArchiveFinder ... \
    Sources/Archive.swift Sources/FormatCatalog.swift Sources/FormatDetector.swift \
    Sources/ArchiveService.swift FinderSync/FinderSync.swift
```

- 删除 `archiveExts` 硬编码，判定全部走 `OpenGate.decide(url)`。
- 这四份文件已在 QuickLook appex 里编过，只依赖 Foundation，可复用。若编译报 AppKit 依赖，`Archive.swift` 带头拆分，不复制代码。
- 新增 `FinderMenuBuilder`（`FinderSync/MenuBuilder.swift`），纯函数、无 AppKit：
```swift
enum FinderAction: String, CaseIterable, Codable {
    case open, extractHere, extractToFolder
    case compressZip, compressSevenZip, compressEach
}
struct FinderMenuBuilder {
    static func actions(for urls: [URL]) -> [FinderAction]     // 有顺序
    static func title(for action: FinderAction, count: Int) -> String
}
```

### 3.7 菜单挂载范围

`directoryURLs` 从 `/` 改为挂载卷集合：

```swift
let urls = FileManager.default.mountedVolumeURLs(
    includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]
) ?? [URL(fileURLWithPath: "/")]
FIFinderSyncController.default().directoryURLs = Set(urls)
```

网络卷（SMB/NFS）默认不挂：右键解压到网络卷的失败率与耗时都不可控，用户可拖进主窗口处理。

### 3.8 与主 app 设置同步（ad-hoc 下的现实方案）

App Group 在 ad-hoc 签名下不可用（无 Team ID，`com.apple.security.application-groups` 不生效）。本版走文件：

- 路径：`~/Library/Application Support/rrzip/finder.json`
- 写入：主 app 在设置变更时原子写（temp + `replaceItemAt`）
- 读取：扩展在 `menu(for:)` 里读一次，200ms 内存缓存
- 结构：

```json
{
  "secondLevel": true,
  "enabled": ["open", "extractHere", "compressZip", "compressEach"],
  "extractStrategy": "newFolder"
}
```

上 Developer ID（模块 E）之后迁到 App Group + `UserDefaults(suiteName:)`，读取接口不变，只换存储层。

> **已修（PR2）**：`SevenZip.binary` 原来是 `Bundle.main.url(forResource:)`，在 appex 里 `Bundle.main` 是扩展自身，
> 找不到主 app 的 `Contents/Resources/7zz`，`isAvailable` 恒为 false。
> 现在改成候选路径列表：主 bundle 的 Resources + 「自己是 appex 时」上级 app 的 `Contents/Resources`。
> 快速查看扩展一并修好（它之前读 dmg 也会因为同样的原因失败）。
> 用 `static let` 缓存解析结果，不再每次解压都 stat 两条路径。

### 3.9 验收

见 §9 T13–T18。判定层 6 组矩阵用例进自动化。

---

## 4. 模块 B：双模式自动缩放修复（P1）

### 4.1 复现路径

```
启动（完整模式，窗口 1180）
→ 用户拖窗口右下角向左
→ 宽度到 1020 卡住（window.minSize）
→ 判据 width < 760 永不成立
→ 自动收起永不触发
```

`applyModeWindowSize()` 里每次切模式都重设 `window.minSize`，所以**任何时刻**在完整模式下都不可达。手动点「收起」不受影响，这也是为什么之前实机测没发现。

### 4.2 修法：解耦最小尺寸与模式

| 项 | 现状 | 改后 |
|---|---|---|
| `window.minSize` | 随模式在 560×420 / 1020×600 间切换 | **恒为 560×420**，只在启动设一次 |
| 自动收起阈值 | `width < 760` | `width < Layout.autoCollapseWidth`（当前推导值 ≈ 1000） |
| 自动展开阈值 | `width > 900` | `width > Layout.autoExpandWidth`（≈ 1080） |
| 防抖 | 无 | 宽度变化合并 100ms 后再判定 |
| 自动切换时改窗口尺寸 | 不改 | 不改（保持） |
| 手动切换时改窗口尺寸 | 改 | 改（保持） |

**阈值不写死数字，从尺寸 token 推导**（这是给 v2.12 外观改造留的接口，见 §15）：

```swift
// Palette.swift 的 Metrics 里
static let sidebarMin: CGFloat = 172
static let contentMin: CGFloat = 360
static let inspectorMin: CGFloat = 250

enum Layout {
    /// 三栏刚好不挤的最小宽度
    static var fullModeMinWidth: CGFloat {
        Metrics.sidebarMin + Metrics.contentMin + Metrics.inspectorMin + Metrics.gutter * 2 + 8
    }
    static let collapseHysteresis: CGFloat = 80
    static var autoCollapseWidth: CGFloat { fullModeMinWidth - 20 }
    static var autoExpandWidth: CGFloat { fullModeMinWidth + collapseHysteresis }
}
```

推导值（2026-11-06 实测）：`fullModeMinWidth` = 172 + 360 + 250 + 14×2 + 8 = **818**；收起 **998**，展开 **1078**。外观改版若调整侧栏或详情栏宽度，只改 `Metrics` 三个常量，阈值自动跟随，不用再回来改 `autoMode`。

旧口径的处理：`SettingsView.swift:55` 的开关副标题不再写具体数字（改为「窗口变窄时自动切换」）；`DESIGN.md` 的窗口与切换段同步。
`RELEASE_NOTES.md:31` 是 v2.8.0 的历史记录，**不改**——新阈值写进 2.11.0 的新段落（PR5 补），改历史发布说明等于篡改记录。

### 4.3 自动化断言

新增 5 项（阈值改为从 `Layout` 取，不再写死数字，断言也按推导值写）：

```swift
let collapse = Layout.autoCollapseWidth   // 998
let expand = Layout.autoExpandWidth       // 1078
expect(model.autoMode(forWidth: expand + 10) == .full, "超过展开阈值自动展开")
expect(model.autoMode(forWidth: collapse + 10) == nil, "滞回区内不切换")
expect(model.autoMode(forWidth: collapse - 10) == nil, "简化模式下更窄也不再重复切")

// 阈值自洽：上一版的 bug 就是判据低于窗口最小宽度
expect(collapse > Layout.fullModeMinWidth, "收起阈值高于三栏几何下限")
expect(expand > collapse, "展开阈值高于收起阈值（留滞回）")
expect(collapse <= 1020, "收起阈值不超过旧版窗口最小宽度，否则又会不可达")

// 完整模式被拖窄必须能收起（旧版这条永远返回 nil）
model.setWorkspaceMode(.full, manual: false)
expect(model.autoMode(forWidth: collapse - 1) == .compact, "完整模式变窄自动收起")
expect(model.autoMode(forWidth: collapse + 1) == nil, "留在滞回区内不来回弹")
```

第 6 条是关键回归锁：只要有人再把窗口下限调到阈值以上，这条立刻红。

### 4.4 边界

- 启动首帧仍不跑自适应，0.6s 后接管（v2.8.0 的 `autoModeReady`，保留）。
- 完整模式被拉到 999 → 立刻切简化，三栏不会出现在窄窗口。
- 简化模式被拉宽到 1081 → 切完整并**不放大窗口**（保持用户手选的宽度），符合「不跟用户抢窗口」。

### 4.5 验收

T20–T23。

---

## 5. 模块 C：主程序打开入口收口（P0）

### 5.1 问题

```swift
// ContentView.swift:368 —— 现状
func application(_ application: NSApplication, open urls: [URL]) {
    guard let url = urls.first(where: { ArchiveKind.isArchive(ext: $0.pathExtension.lowercased()) })
    else { return }                     // ← 静默丢弃
    Task { @MainActor in AppDelegate.model?.open(url: url) }
}
```

三重问题：

1. 后缀不在白名单 → 直接 return。改名的包（v2.8.0 专门修过的场景）从访达双击、FinderSync 打开都会静默失败。
2. 不匹配时没有错误提示，用户只看到图标跳一下。
3. 多选只取第一个。

### 5.2 修法

```swift
func application(_ application: NSApplication, open urls: [URL]) {
    guard !urls.isEmpty else { return }
    let archives = urls.filter { if case .open = OpenGate.decide($0) { return true }; return false }
    Task { @MainActor in
        if let first = archives.first {
            AppDelegate.model?.open(url: first)
            if archives.count > 1 {
                AppDelegate.model?.notice = "另有 \(archives.count - 1) 个压缩包未打开"
            }
        } else {
            AppDelegate.model?.open(url: urls[0])   // 走 unrecognized 分支，给出真实提示
        }
    }
}
```

- 全部判定走 `OpenGate`，与拖放、⌘O、命令行一致。
- `Model` 新增轻量 `notice: String?`（`ContentView` 底部浮条，3 秒自动消失，不进 alert）。
- Services 里的 `openWithRrzip` 同样去掉 `isArchive` 前置过滤（`ContentView.swift:267`），改用 `OpenGate`。

### 5.3 验收

T24、T15。

---

## 6. 模块 D：设置中心补访达状态与菜单配置（P1）✅ PR4

「Finder 与预览」改名「访达与预览」，六组，全部已实现：

### 6.1 访达扩展状态

| 显示项 | 数据来源 | 状态 |
|---|---|---|
| 扩展已随应用安装 | `Contents/PlugIns/ArchiveFinder.appex` 是否存在 | ✅ |
| 启用步骤 | 静态文案：系统设置 → 通用 → 登录项与扩展 → 访达扩展 → 勾选 rrzip | ✅ |
| 「打开登录项与扩展」按钮 | 复用 `openExtensionSettings()` | ✅ |
| 「重新启动访达」按钮 | `Process` 执行 `killall Finder`，二次确认 | ✅ |
| 通知权限状态 | `UNUserNotificationCenter.getNotificationSettings` | ✅ |

诚实标注：只能确认「装了」，不能确认「开了」。macOS 没有公开 API，所以只给步骤，不做假状态灯。

### 6.2 右键菜单

7 个开关，默认值如下（改完即时写 `finder.json`，提示重启访达）：

| 键 | 默认 |
|---|---|
| 放进 rrzip 二级菜单 | 开 |
| 用 rrzip 打开 | 开 |
| 解压到此处 | 开 |
| 解压到「包名」文件夹 | 开 |
| 压缩为 ZIP | 开 |
| 压缩为 7Z | 开 |
| 分别压缩 | 开 |

> 与原计划的差异：原定「解压到包名文件夹」默认关、7Z 默认关。实际全部默认开——
> 菜单项本身会按选择类型动态出现，多一项不会造成误点，而默认关掉会让人以为功能没做。

### 6.3 解压位置

- 解压到「包名」文件夹（默认）/ 压缩包所在目录
- 同名文件一律跳过（`-aos` / `--keep-old-files`），重名文件夹自动加序号
- 「合并并改名」「逐个询问」推迟到 v2.12（§3.4）

### 6.4 落盘

`FinderSettingsStore.save` 原子写（temp + `replaceItemAt`）：扩展每次开菜单都读这个文件，读到半截 JSON 就是一整轮右键没反应。

### 6.5 验收

T19、T26。另加 2 项自动化：设置写盘读回、临时文件不残留。

---

## 7. 模块 E：发布就绪（P1）

### 7.1 签名分级

| 级别 | 用途 | 前置 | 现状 |
|---|---|---|---|
| ad-hoc（`codesign -s -`） | 本地开发、内测 | 无 | ✅ v2.10.0 |
| Developer ID + 公证 | 对外分发 | Apple Developer Program 账号 | ⬜ 本版 |

ad-hoc 的两个硬限制必须写进 README，别再让用户以为是 bug：扩展注册偶发失效、Gatekeeper 首次打开需右键。

**POC 结论（2026-11-06，`scripts/poc-sandbox.sh`）**：脚本已就位并能跑出三种组合，但 ad-hoc 签名下沙盒进程**连 hello 都起不来**（exit 133 / SIGTRAP）——
不是「沙盒拒绝了 spawn」，是「沙盒根本没启用」。也就是说「沙盒扩展能否执行 7zz」在当前环境**无法验证**，
既不能判可行、也不能判不可行。结论必须等 Developer ID。这直接改变了模块 E 的排期，见 §13 风险 1 与 §12 的 E1 / E2 拆分。

### 7.2 `scripts/notarize.sh`

```bash
# 一次性：xcrun notarytool store-credentials rrzip --apple-id ... --team-id ... --password ...
xcrun notarytool submit build/rrzip-v2.11.0.zip --keychain-profile rrzip --wait
xcrun stapler staple build/rrzip.app
spctl -a -vv build/rrzip.app     # 必须 accepted / Notarized Developer ID
```

- 证书与凭据一律走 keychain profile，不进仓库、不进 CI secrets 的明文文件。
- 签名顺序：先签两个 appex → 再签主 app（现有 `build.sh` 已正确，不加 `--deep`）。
- 扩展必须加 `com.apple.security.app-sandbox` entitlement 才能公证。**这是本模块最大技术风险**，见 §13 风险 1，必须先做 POC。

### 7.3 CI 补强

| 项 | 改动 |
|---|---|
| 产物校验 | 补 `test -d build/rrzip.app/Contents/PlugIns/ArchiveFinder.appex`、`test -x .../ArchiveFinder` |
| plist 校验 | `plutil -lint` 两个扩展的 Info.plist + 主 plist |
| 测试数 | `scripts/test.sh` 末尾输出 `PASS n`，CI 断言 n ≥ 90 |
| 分支保护 | main 需 PR + CI 绿；禁止直推（含 hotfix，走 PR 后 squash） |

### 7.4 文档同步（一次性清账）

| 文件 | 动作 |
|---|---|
| `PRD-v2.8.0.md:332` | 2.10.0 状态改「✅ 已发布 `b5de5d2`（release #17）」 |
| `PRD-v2.8.0.md` 头部 | 加一行「已冻结，进度见 PRD-v2.11.0.md」 |
| `README.md` | 版本号、测试数、访达集成章节（补 FinderSync 4 项 + 启用步骤）核对 |
| `RELEASE_NOTES.md` | 2.11.0 段落与本文 §9 验收结果对齐 |
| `DESIGN.md:102` | 阈值与新窗口策略同步 |

### 7.5 交付纪律（恢复 v2.8.0 的做法）

- 一个 PR 一个模块，PR 描述里贴对应 T 编号与勾选结果。
- v2.10.0 那种「判定层 + 执行层 + 签名」混在一个直推提交里的做法不再允许。
- 每批 PR 合并前必须：CI 绿、`-strict-concurrency=complete` 零告警、至少一条人工实机勾选。

---

## 8. 模块 F：小需求（P2，余量才做）

### 8.1 压缩文件夹内容，不含外层目录

现状 `SevenZip.add` 传绝对路径（`Archive.swift:348-355`），包内层级依赖 7-Zip 自身对绝对路径的裁剪，不可控。

做法：新增 `layout` 参数，`contentsOnly` 时切 `cwd = 父目录` + 传相对名，复用现有 `prefix` 分支的 symlink staging 手法，不新增临时拷贝。

**前置**：先写 3 项断言固定现状行为（`a folder` / `a folder/file` / 深层嵌套），再改，否则无法判断是修复还是换了另一种错。

入口：新建压缩包面板加「包含外层文件夹」勾选（默认勾）；访达菜单加「压缩文件夹内容」。

### 8.2 表头列显示管理

右键表头勾选：名称 / 大小 / 压缩后大小 / 修改时间 / 权限，「名称」不可隐藏。状态存 `UserDefaults`（按「视图 × 模式」分开）。

### 8.3 设计 token 审计（纯重构，不改视觉）

为 v2.12 的外观改造做前置，本版只做「把散落的数字收进 token」，**不改任何视觉结果**。

现状：`Palette.swift` 已有完整的 `Palette` / `TypeScale` / `Space` / `Metrics` 四层 token，但 `ContentView.swift`（1955 行）只引用了 15 处 `Metrics.`，其余尺寸仍是即兴数字。换外观时这些数字要一个个找，等于重写。

| 动作 | 范围 | 判定 |
|---|---|---|
| 把列表行内边距、工具栏分组间距、浮层偏移等硬编码收进 `Metrics` | `ContentView.swift`、`PreviewPane.swift`、`HoverPreview.swift` | 改前后截图逐像素比对一致 |
| 补齐 `Metrics` 缺失档位：侧栏最小宽、内容最小宽、详情最小宽（供 §4.2 的 `Layout` 推导） | `Palette.swift` | 与现有 `.frame(minWidth:)` 数值完全相等 |
| 禁止新增裸字号：`TypeScale` 之外不出现 `Font.system(size:)` | 全 `Sources/` | `grep "Font.system(size:"` 只允许出现在 `Palette.swift` |

这一步的风险很低（不改变渲染结果），但收益是 v2.12 换外观从「全库搜索替换」变成「改一张 token 表」。

### 8.4 明确推迟

| 项 | 原因 |
|---|---|
| 列宽拖动 + 双击自适应 | 要改的是整个列表的布局模型，与模块 B 的窗口阈值研究叠在一起容易互相干扰，v2.12 单独做 |
| 扩展属性 / 资源叉 / 文件名编码验证 | 属数据正确性专项，需要一套样例包（GBK 名、xattr、符号链接、分卷），单独开一批 |
| XPC 任务服务（真进度条） | 依赖签名方案定型，见 §13 风险 1 |

---

## 9. 验收清单

| ID | 场景 | 判定 | 类型 |
|---|---|---|---|
| T13 | 把 7z 改名成 `.bin`，访达右键 | 出「解压到此处」，能解开 | ✅ 自动化（PR1，`FinderMenuBuilder` 12 项） |
| T14 | 选 3 个包 + 2 张图，右键 | 混合态菜单 3 项，标题带数量 | ✅ 自动化（PR1） |
| T15 | 多选 3 个包点「用 rrzip 打开」 | 只开第一个，主界面浮条提示「另有 2 个」 | 人工 |
| T16 | 已存在 `包名/` 时右键解压 | 生成 `包名 2`，原目录一个字节不动 | ✅ 自动化（PR2 端到端：解两次，原 `说明.txt` 内容仍是 ADMIN） |
| T17 | 加密 7z 右键解压 | 通知「需要密码」，**不产生空目录** | ✅ 自动化（PR2） |
| T18 | 右键解压 1.2 GB 包 | 完成后有通知，标题带数量与落点 | ⬜ 实机（通知按钮留 v2.12） |
| T19 | 关闭通知权限后右键解压 | 任务正常完成，设置页显示「已拒绝」+ 跳转按钮 | ✅ 逻辑（PR4）· 实机待验 |
| T20 | 完整模式拖窄到 990 | 自动切简化（此前不可能） | ✅ 断言通过（`autoCollapseWidth`≈998）· 实机待拖 |
| T21 | 简化模式拖宽到 1090 | 自动切完整，窗口不被放大 | ✅ 断言通过（≈1078）· 实机待拖 |
| T22 | 手动展开后 5 分钟内拖宽窄 | 不自动切 | ✅ 断言通过（冷却） |
| T23 | 完整模式启动 → 一路拉窄 | 一次切换，无抖动、无回弹 | ⬜ 实机（100ms 防抖已加） |
| T24 | 双击访达里改名为 `.bin` 的 zip | 正常打开（此前静默无反应） | ✅ 逻辑已修（PR1）· 实机待验 |
| T25 | 8000 条目包，切 10 次 | 无卡顿（<300ms），选中与滚动保留 | 人工压测 |
| T26 | 设置里关「解压到此处」→ 重启访达 | 菜单少一项 | ✅ 逻辑（PR4）· 实机待验 |
| T27 | 压缩文件夹选「不含外层」 | 包内首层是文件夹内容 | 自动化（`list` 断言） |
| T28 | CI 产物 | 两个 appex 都在，`plutil -lint` 通过 | 自动化 |
| T3/T4 | 承接：简化→完整→简化 | 目录、选中、滚动位置全保留 | 人工（v2.8.0 遗留） |
| T8 | 承接：批量 4 包对照单包 | 条目数一致，加密包标记跳过 | 人工（遗留） |

自动化落点：`Tests/main.swift`。进度：PR1 +19（70→89）、PR3 +6（89→95）、PR2 +27（95→**122**）。
其中 PR2 的 7 项是端到端——真的解压两次，验证已存在的 `说明.txt` 内容仍是 `ADMIN`、跳过数 = 4。
收尾目标 ≥ 92 已提前达成，剩余给 PR4/PR5 留余量。

---

## 10. 性能与容量基线

| 指标 | 目标 | 测法 |
|---|---|---|
| 右键菜单构建 | < 50ms | 3 个 URL（2 包 + 1 普通文件）调 `actions(for:)` 计时 |
| 8 万条目包 `list` | < 3s | 生成器脚本造包 |
| 8000 条目模式切换 | < 300ms | 10 次取中位数 |
| 扩展冷启动到出菜单 | < 200ms | 重启 Finder 后首次右键计时 |

---

## 11. 非目标

- 不做 App Store 沙盒发行（FinderSync + 外部 7zz 的组合不适合）。
- 不做多窗口 / 多标签同时开多个包（v2.8.0 已定，不回头）。
- 不重写列表为 `NSTableView`（视觉成果要保）。
- 不做压缩包内重命名、不做 rar 写入。
- 不做 Finder 图标角标 / 缩略图覆盖。
- **不做外观 / 手感重做**（v2.12 专项，见 §15）；本版只做 token 审计，不改任何视觉结果。
- 不改 `Palette` 色值与 `TypeScale` 字号，不调整工具栏高度与行高。
- 不做 21 种语言，仍为中英双语。
- 不在本版做「逐个询问」冲突对话框（v2.12）。
- 不引入 XPC 任务服务，进度反馈先用通知代替（v2.12 按签名结论再定）。

---

## 12. 交付顺序

| 批次 | 分支 / PR | 内容 | 依赖 | 状态 |
|---|---|---|---|---|
| 1 | `feat/finder-menu-core` | `FinderMenuBuilder` + `OpenGate` 编入扩展 + 6 组矩阵测试 + 模块 C 主入口收口 | — | 🔄 代码完成（测试 70→89），待 PR |
| 2 | `feat/finder-exec` | `FinderJob` + 防覆盖策略 + `ArchiveService` 冲突参数 + 通知 + 日志 | 1 | 🔄 代码完成（测试 95→122），待 PR |
| 3 | `fix/mode-autoresize` | 模块 B：minSize 解耦、阈值从 token 推导、100ms 防抖、文案与 DESIGN 同步 | — | 🔄 代码完成（测试 89→95），待 PR |
| 4 | `feat/settings-finder` | 模块 D：访达分页重做、共享 `finder.json`、通知权限、二级菜单 | 1、2 | 🔄 代码完成（测试 122→124），待 PR |
| 5a | `chore/release-ready` | **E1**：签名 POC 脚本 + `notarize.sh` 就绪、CI 补强、文档清账 | 1–4 | ⬜ |
| 5b | — | **E2**：证书 POC → Developer ID 签名 → 公证 → 分发说明（**需要 Apple Developer 账号；无证书时本版以 ad-hoc 内测版发布**） | 5a + 证书 | ⬜ 阻塞 |
| 6 | `feat/quality-polish` | 模块 F：不含外层压缩（先测后改）、列显示管理、设计 token 审计（§8.3） | 3 | ⬜ 余量 |

1、2 必须串行（判定层先立，执行层才能测）；3 可并行；4 依赖 2 的 `finder.json`；5 收尾；6 有空才做。

**版本号**：模块 A+B+C 合并后打 `v2.11.0-beta.1`；D 完成打 `beta.2`；E 完成打正式 `v2.11.0`。beta 期间只修 bug，不再加项。

---

## 13. 风险

| # | 风险 | 影响 | 对策 | 状态 |
|---|---|---|---|---|
| 1 | **沙盒化后扩展能否执行包内 7zz** | 公证的前置条件卡在这里 | POC 脚本已就位（`scripts/poc-sandbox.sh`，三种组合 + hello 诊断），但 **ad-hoc 签名开不了沙盒**（exit 133），必须拿到 Developer ID 才能验。本版按「不阻塞」处理：E1 先做完，E2 等证书 | 🔄 方法就绪，等证书 |
| 2 | 动态菜单在 `menu(for:)` 里读选择有延迟 | 菜单与实际选择不同步 | 只用同步 API，不缓存、不异步 | ⬜ |
| 3 | 通知权限被拒 | 反馈缺失回到原点 | 设置页显式状态 + 主 app 首次启动请求；任务日志兜底 | ⬜ |
| 4 | 阈值从 760/900 改到 1000/1080 | 老用户感觉「更容易被切模式」 | 保留 5 分钟冷却 + 开关；文案不写死数字 | ⬜ |
| 5 | `finder.json` 并发写 | 设置被打回旧值 | 原子写（temp + `replaceItemAt`）；扩展只读 | ⬜ |
| 6 | 四份源码编进第三个 target | 编译体积与符号冲突 | 先做 `-typecheck` 验证；`Archive.swift` 若混入 AppKit 则拆分而非复制 | ⬜ |
| 7 | 模块 B 改了窗口尺寸策略 | 首帧闪烁回归 | 保留 `autoModeReady` 0.6s 静默窗，实测首帧 | ⬜ |
| 8 | 一版塞 5 个模块 | 又一次「一次推一堆」 | 严格按 §12 分批，每批 PR + CI + 人工勾选 | ⬜ |

---

## 14. 完成定义

v2.11.0 可以发布，当且仅当：

1. §2.1 / §2.2 的 P0、P1 项全部关闭，P2 项有明确去向（做或写明推迟理由）。
2. §9 的 T13–T28 全绿，其中自动化 ≥ 22 项（当前 122 项全通过），测试总数 ≥ 92。
3. 承接项 T3/T4、T8、T12 有实机记录（截图或录屏，不留「逻辑上应该」）。
4. 一次完整走查：找一台没装过 rrzip 的机器，只给「右键解压这 3 个包」一句指令，不丢文件、不需要看文档。
5. 文档四件套（README / RELEASE_NOTES / DESIGN / 本 PRD）与代码状态一致。

第 4 条是这版真正的主验收：**前三个版本证明了 rrzip 能打开很多格式；这一版要证明它不会弄坏用户的东西。**

**无 Developer ID 时的发布口径**：以 ad-hoc 内测版发布，README 明确写「未签名未公证，首次打开需右键」，
不把「正式发布能力」算作已完成。拿到证书后补 E2（§12-5b），不改代码——只改签名与分发流程。

---

## 15. 与 v2.12 外观 / 手感改造的接口

结论：**外观重做与手感优化放 v2.12.0，不进 v2.11.0。** 但 v2.11.0 要为它留三个接口，现在做，成本几乎为零。

### 15.1 为什么不能同期做

| 理由 | 说明 |
|---|---|
| 回归矩阵翻倍 | v2.11.0 动的是访达扩展、窗口策略、设置页；外观重做要重测双模式 × 首页/列表/预览/暂存/设置/引导 全部状态。同期做，一个错位分不清是逻辑 bug 还是样式 bug |
| 尺寸 token 会推翻阈值 | 自动切换阈值由三栏最小宽度推导。新外观若改侧栏/详情栏/行高，阈值作废——所以本版把阈值写成从 `Metrics` 推导（§4.2），而不是写死 1000 |
| 手感依赖列表结构 | 拖拽、双击、悬停、框选都长在现在的 `ScrollView + LazyVStack` 上。外观大概率要动行结构与命中区，手感必须和结构一起改，否则同一段交互写两遍 |

### 15.2 v2.11.0 现在要留的三个接口

| 接口 | 本版动作 | 下一版收益 |
|---|---|---|
| 尺寸 token | §8.3 审计：硬编码尺寸收进 `Metrics`，补齐 `sidebarMin` / `contentMin` / `inspectorMin` | 换外观只改一张表 |
| 模式阈值 | §4.2 `Layout` 从 token 推导 | 改了栏宽不用回来改 `autoMode` |
| 字号 | `TypeScale` 之外的裸 `Font.system(size:)` 清零 | 换字号阶梯不必全库搜索 |

### 15.3 设计阶段请先定这 6 个数字

它们同时是新外观的骨架和本版阈值的输入。设计稿定下这 6 个，§4.2 的推导值就锁定，PR3 不用返工。

| # | 数字 | 现值 | 影响 |
|---|---|---|---|
| 1 | 工具栏高度 | 44 | 首屏信息量、状态栏呼吸 |
| 2 | 列表行高（紧凑 / 宽松） | 28 / 38 | 8000 条目滚动密度、双击命中区 |
| 3 | 侧栏默认宽 / 最小宽 | 198 / 172 | `fullModeMinWidth` |
| 4 | 详情栏默认宽 / 最小宽 | 288 / 250 | `fullModeMinWidth` |
| 5 | 内容列最小宽 | 360 | `fullModeMinWidth` |
| 6 | 窗口最小尺寸 | 560×420 | 与简化模式浮层预览的 620 断点联动 |

设计期间不用等代码：改这 6 个数字只是改 PRD 的一张表，代码在本版按现值推导即可。

### 15.4 v2.12.0 建议范围（现在只记录，不展开）

1. 视觉：配色、层次、图标、空状态与引导页；深浅色两套一起定。
2. 手感：行高与命中区、拖拽反馈、框选、双击行为、悬停延迟、滚动惯性。
3. 结构：仅在「手感必须依赖结构」时才动列表容器，动则同时补 T12 的性能基线。
4. 不混入功能：外观版不新增能力，避免又一次「一次推一堆」。

### 15.5 边界

- 本版不改 `Palette` 的色值与 `TypeScale` 的字号，只补 token 名字（§8.3）。
- 设计稿若在 v2.11.0 期间定稿且改了上述 6 个数字，只更新 §15.3 表格与 `Metrics` 常量，不动 PR3 的逻辑。
- 外观方案若要求「完整模式不再是三栏」，那属于产品结构变更，需要单独 PRD，不在 v2.12 顺手做。
