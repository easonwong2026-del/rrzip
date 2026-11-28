# rrzip

[![ci](https://github.com/easonwong2026-del/rrzip/actions/workflows/ci.yml/badge.svg)](https://github.com/easonwong2026-del/rrzip/actions/workflows/ci.yml)

macOS 原生压缩包工作台。SwiftUI + 系统 libarchive（`/usr/bin/tar`）+ 内置 7-Zip 26.05。

界面、交互与实现独立编写；格式目录数据取自开源项目 MacPacker（GPL-3.0），
因此本仓库整体以 GPL-3.0 分发，详见 [NOTICE](NOTICE)。

## 功能

| 功能 | 说明 |
|---|---|
| 打开 / 拖入 | 单文件选择、拖拽到窗口、Finder「打开方式」、`⌘O` |
| 列表浏览 | 名称、大小、修改时间；目录 / 压缩包 / 图片 / 文档区分图标 |
| **目录层级** | 双击进入下一层，面包屑与左侧目录树都能跳转 |
| **三栏布局** | 目录树 / 内容 / 详情面板，右侧显示归档格式、大小、条目数、加密状态、修改时间；工具栏可分别收起左右两栏（记住选择） |
| 嵌套包浏览 | 双击内嵌包进入，面包屑可回退任意层（`⌘[`） |
| 全部解压 | `⌘E` |
| 选择性解压 | 选中条目后 `⇧⌘E` |
| 快速预览 | 图片内联（适应 / 1:1 缩放，±25% 步进）、PDF 内嵌阅读、文本/代码直接显示、视频与音频内联播放 |
| 拖拽导出 | 从列表拖到访达 |
| 创建压缩包 | `⌘N`：ZIP / **7Z** / TAR / TAR.GZ |
| **加密** | ZIP 用 AES-256；7Z 连文件名一起加密（`-mhe=on`） |
| **分卷** | 100 MB / 700 MB / 1 GB / 4 GB |
| **加密包读取** | 打开时提示输入密码；右上角可一键锁定并清除密码 |
| **访达快速查看** | 按空格查看归档格式、项目总数和未压缩大小。列表显示前 300 项及文件类型图标 |
| **包内搜索** | 工具栏搜索框，跨层级匹配，结果显示完整路径 |
| **三种视图** | 列表 / 图标网格 / **分栏列视图** 一键切换 |
| **类型配色** | 文件夹蓝、压缩包青绿（品牌色）、图片橙、PDF 红、视频玫红、音频青蓝、代码绿、磁盘蓝，深浅色都适配 |
| **外观切换** | ⋯ 菜单里可选「跟随系统 / 浅色 / 深色」 |
| **悬停预览** | 鼠标停满 1 秒在光标旁弹出内容卡片（需先移动鼠标，开窗不会自动弹）：图片与 PDF 出大图，文本出前几行 |
| **简化 / 完整模式** | 默认 720×520 单栏，轻量浏览与解压；⌃⌘M 或工具栏按钮展开成三栏工作台，目录层级、选中项、预览都不丢 |
| **设置中心** | `⌘,` 打开，5 个分页：通用 / 压缩 / 解压 / 访达与预览 / 高级；没有打开压缩包时也能改 |
| **访达右键** | FinderSync 扩展，菜单随选择变化（包 / 普通文件 / 混合），默认收进「rrzip ▸」；解压不覆盖、完成有通知；另有「服务」兜底 |
| **首页** | 无包时显示：打开 / 新建 / 最近打开（最多 8 条，失效置灰）/ 快速压缩（拖入即生成 ZIP） |
| **首次启动引导** | 一屏说明三条能力 + 快速查看扩展状态；同一版本只弹一次，帮助菜单可重看 |
| **暂存拖拽** | 条目可直接拖进暂存条（只记包内路径，不解压） |
| **批量处理** | 一次拖入多个包（或 ⇧⌘B）进入批量面板：批量解压到各自文件夹，或批量校验 |
| **完整性校验** | 用 `7zz t` 完整读一遍，损坏的文件会指出具体条目 |
| **多窗口** | ⇧⌘N 新建窗口。外部打开多个包时复用空闲窗口或开新窗，已打开的包直接聚焦 |
| **暂存区** | 所有窗口共享条目和导出布局，可跨目录、跨压缩包累积后一次导出或打包成 ZIP |
| **图片 / PDF / 视频缩略图** | 图片走 ImageIO，PDF 渲染首页，视频取首帧（AVFoundation）；按需解压 + 缓存 |
| **键盘导航** | ↑↓ 选择、回车进入 / 打开、空格快速查看、←（或 ⌘↑）返回上级；⌘/⇧ 多选、⌘A 全选、⌘F 搜索 |
| **空格快速查看** | 系统快速查看面板全屏预览选中条目，再按空格关闭 |
| **视频预览** | 右侧面板内嵌播放器（AVKit），可播放、暂停、拖动进度；音频同样可播 |
| **快捷操作条** | 选中后浮出「解压到… / 导出…」 |
| **格式识别** | 先看后缀，后缀不认识就读内容（magic number），改名/无后缀的文件也能打开 |
| **原地编辑** | 往压缩包里加文件、删条目，保存后直接写回原包（嵌套包内不可用） |
| **磁盘映像** | DMG、ISO、VHD/VHDX、VDI、VMDK、QCOW2、WIM 等交给内置 7-Zip 打开 |
| **命令行** | 归档创建、解压、校验、列表、识别、编辑和缩略图 |

## 命令行

安装后可直接运行 `/Applications/rrzip.app/Contents/MacOS/rrzip`。

| 命令 | 用法 |
|---|---|
| 帮助和版本 | `--help` / `-h`，`--version` / `-v` |
| 识别和列表 | `--detect <文件>`，`--list <归档> [--pass <密码>]` |
| 校验完整性 | `--verify <归档> [--pass <密码>]` |
| 解压 | `--extract <归档> -o <目录> [--overwrite] [--pass <密码>] [包内条目...]` |
| 创建归档 | `--create <输出归档> <源文件...> [--format zip\|7z\|tar\|tgz] [--level 0..9] [--volume <分卷>] [--pass <密码>]` |
| 加入或删除 | `--add <归档> <源文件...> [--prefix <包内目录>] [--pass <密码>]`，`--remove <归档> <包内条目...> [--pass <密码>]` |
| 生成缩略图 | `--thumb <归档> <包内条目> <输出 PNG> [--size <最大边长>] [--pass <密码>]` |

解压默认跳过同名文件。创建格式默认根据输出扩展名选择，以 `.tar.gz` 结尾时生成 TGZ。加密和分卷用于 ZIP 或 7Z，TAR 是未压缩归档。

## 性能

- 条目列表按「父目录 → 子项」建一次索引，之后取一层是 O(1)；10 万条目的包切目录不再重算
- 索引构建实测：10 万条目 < 1 秒（见 `Tests/main.swift` 的基准断言）
- 缩略图按需解压、降采样后进 NSCache，缓存键含归档路径与目标尺寸，不同包不会串图
- 悬停卡片只在停留满 1 秒后触发，移动即取消；窗口刚打开、鼠标未移动时不会自动弹出
- 缩略图存在 store 里、视图只读缓存，列表滚动重建不会丢图
- 缩略图缓存有上限（400 张 / 64 MB），失败的结果也记住，不会反复解压坏文件
- 创建压缩包先写隐藏临时文件，成功后才替换目标：失败不损坏已有文件
- 预览解压的临时目录在缓存淘汰时一并删除

## 双引擎策略

| 场景 | 引擎 |
|---|---|
| 常规 zip / tar / gz / rar / iso 等读取 | 系统 `bsdtar`（libarchive 3.7.4） |
| 磁盘映像（dmg / vhd / vhdx / vdi / vmdk / qcow2 / wim / chm / msi） | 内置 `7zz` |
| 创建 7z、加密、分卷 | 内置 `7zz` |
| 原地增删 | 内置 `7zz` |
| 加密头 7z（libarchive 不支持） | 内置 `7zz` |

打开文件时先识别格式，再按格式挑起始引擎，失败会自动换另一个。

`7zz` 位于 `Contents/Resources/7zz`，随应用分发，用户无需另装。

## 支持格式

识别 37 种、本机引擎可打开 32 种：

| 类别 | 格式 |
|---|---|
| 压缩包 | zip · zipx · 7z · rar · tar · jar · apk · cbz · cbr · cab · cpio · xar · pkg · ar · arj · lha/lzh · rpm · deb · sit · sitx |
| 单层压缩 | gz · bz2 · xz · lzma · lz4 · z · zst |
| 磁盘映像 | dmg · iso · vhd · vhdx · vdi · vmdk · qcow2 · wim · squashfs · ntfs · fat |
| 其它容器 | msi · chm · exe（自解压） |
| 复合后缀 | tar.gz · tar.bz2 · tar.xz · tar.zst 等 6 种 |
| 分卷 | zip 分卷（.z01/.zip.001）· 7z 分卷 |

sit / sitx / lz4 / lzx 只能识别、不能打开（本机引擎不支持，会给出明确提示）。
写入：zip · 7z · tar · tgz；原地编辑：zip 与 7z。

## 构建

```bash
./build.sh          # 首次会自动调 scripts/fetch-7zz.sh 下载引擎
open build/rrzip.app
```

`Assets/7zz` 是第三方二进制，不入库；`scripts/fetch-7zz.sh` 默认直连官方发布地址，校验下载包和解包后二进制的 SHA256。只有显式设置 `ALLOW_MIRROR=1` 且直连失败时才回退到镜像，镜像也强制校验。

当前只构建 Apple Silicon（`arm64`）。需要 macOS 14+ 与 Xcode Command Line Tools（`swiftc` 6.x，使用 Swift 5 语言模式）。

产物：
- `build/rrzip.app` —— 主程序
- `build/rrzip.app/Contents/PlugIns/ArchivePreview.appex` —— 快速查看扩展

## 快速查看扩展说明

扩展已嵌入并单独签名（sandbox + 用户选定文件只读）。首次运行主程序后系统自动注册：

- 在访达选中 zip / 7z / tar，按空格即可看到条目列表
- 若未生效：系统设置 → 通用 → 登录项与扩展 → 快速查看，勾选 rrzip
- 需要临时停用：删掉 `Contents/PlugIns` 目录后重新签名

## 目录

```
rrzip/
├── DESIGN.md                # 界面设计标准：原则 / 配色 / 字号 / 间距 / 组件 / 交互 / 验收清单
├── Sources/
│   ├── App.swift              # @main 入口、AppDelegate、Services、通知授权
│   ├── ContentView.swift      # 主界面骨架：状态与布局，子视图拆在下面几个文件
│   ├── MainToolbar.swift      # 工具栏：打开 / 暂存 / 新建 / 搜索 / 视图切换 / 更多
│   ├── Chrome.swift           # 面包屑、状态条、轻提示、拖放遮罩
│   ├── EntryList.swift        # 列表、分栏、图标网格、暂存条、行视图
│   ├── DetailPane.swift       # 右侧详情栏与信息卡
│   ├── SidebarPane.swift      # 左侧目录树
│   ├── TaskCard.swift         # 长任务进度卡
│   ├── Model.swift            # 打开、密码、嵌套浏览、任务队列与工作模式
│   ├── ArchiveWriter.swift    # 创建、原地编辑、原子写入与分卷回滚
│   ├── ArchiveIndex.swift     # 目录索引、排序与选中项定位
│   ├── PayloadCache.swift     # 预览和导出副本的缓存、回收与大小上限
│   ├── ArchiveStash.swift     # 暂存区布局、导出和打包
│   ├── PreviewPane.swift      # 右侧详情与预览
│   ├── Batch.swift            # 批量解压 / 校验面板
│   ├── Archive.swift          # 条目模型 + bsdtar / 7zz 双引擎封装（含增删、进度、取消）
│   ├── ArchiveService.swift   # 统一入口：按格式选引擎 + 失败回退（打开/批量/暂存/QL 共用）
│   ├── FormatCatalog.swift    # 格式目录（数据来自 MacPacker，生成文件）
│   ├── FormatDetector.swift   # 后缀 + 魔数识别
│   ├── Palette.swift          # 品牌色 + 类型色板 + 尺寸 / 字号 / 间距 token
│   ├── UniquePath.swift       # 重名避让（主程序与扩展共用一份）
│   ├── HoverPreview.swift     # 悬停预览浮窗
│   ├── QuickLook.swift        # 空格快速查看（QLPreviewPanel）
│   ├── SettingsView.swift     # 设置中心（⌘,，左栏五个分页）
│   ├── HomeView.swift         # 首页：打开 / 新建 / 最近打开 / 快速压缩
│   ├── WelcomeView.swift      # 首次启动一屏说明
│   ├── FinderSettings.swift   # 访达右键配置（主程序写、扩展读）
│   ├── FinderTaskQueue.swift  # 与访达扩展共用的文件队列
│   ├── FinderTaskWorker.swift # 主程序认领与执行访达任务
│   ├── FinderJobKit.swift     # 目标目录、冲突策略、通知文案
│   ├── FinderJobRunner.swift  # 压缩、解压与任务日志
│   ├── PendingExtraction.swift# 加密包解锁后接着解压的意图记录
│   └── PendingNotice.swift    # 扩展转交主程序的一句话结果
├── FinderSync/
│   ├── FinderSync.swift       # 菜单、提交请求和唤起主程序
│   └── MenuBuilder.swift      # 按选择类型给动作
├── QuickLook/
│   └── PreviewProvider.swift  # 快速查看扩展（QLPreviewingController）
├── Tests/
│   ├── Support.swift          # 断言计数与样例包路径
│   ├── ArchiveTests.swift     # 解析、列表、编辑、校验
│   ├── ModelTests.swift       # 批量、打开判定、工作模式、排序
│   ├── FinderTests.swift      # 菜单判定、任务计划与执行、转交
│   ├── CompressTests.swift    # 级别、进度、包内路径
│   └── main.swift             # 入口：按主题分组跑
├── Assets/
│   ├── AppIcon.icns
│   └── 7zz                    # 不入库，构建时下载
├── scripts/
│   ├── sources.sh             # 共享源文件清单（build.sh 与 test.sh 都 source 它）
│   ├── fetch-7zz.sh
│   ├── gen-catalog.py
│   ├── test.sh
│   ├── install-local.sh       # 本地安装：重注册扩展 + 重启访达
│   ├── poc-sandbox.sh         # POC：沙盒化扩展还能不能执行包内 7zz
│   └── notarize.sh            # Developer ID 签名 + 公证（需要证书）
├── build.sh
└── build/rrzip.app
```

## 访达右键菜单

装好应用后，访达里右键任意文件会出现 **rrzip ▸** 子菜单（可在 设置 → 访达与预览 里改成直接展开）：

| 选中 | 菜单 |
|---|---|
| 单个压缩包 | 用 rrzip 打开 · 解压到此处 · 解压到「包名」 |
| 多个压缩包 | 用 rrzip 打开第一个 · 解压 N 个压缩包到此处 · 分别解压到同名文件夹 |
| 普通文件 / 文件夹 | 压缩为 ZIP · 压缩为 7Z · 分别压缩（多选时） |
| 混合选择 | 只保留双方都成立的动作 |

- 格式识别和主程序共用一套（后缀 + 魔数），改名为 `.bin` 的 zip 也认得出
- 解压**不会覆盖**已有文件：解到「包名」文件夹，重名自动变「包名 2」；解到当前目录时同名文件跳过，完成通知里报跳过几个
- 右键支持压缩为 7Z，也能解压加密 7z、DMG、ISO 等可读归档。需要密码时由主程序接管，输入正确后继续原请求。
- 压缩和解压经文件队列转交主程序。任务执行时在 rrzip 中显示进度卡，支持直接取消。选择「取消任务并退出」也会终止当前归档进程，等待暂存清理和回执写入。应用意外退出后会标记中断任务，方便检查已写出的文件。
- 已完成的项目会保留。解压先写入同卷暂存目录，再按冲突策略发布。完成后可在访达中选中产物，解压到此处不跳转。任务记录位于 `~/Library/Application Support/rrzip/finder-jobs.log`。

首次使用要在 **系统设置 → 通用 → 登录项与扩展 → 访达扩展** 勾选 rrzip，然后重启访达（设置页里有「重新启动访达」按钮）。

旧版兼容：应用同时注册了 4 个「服务」菜单项（用 rrzip 压缩 / 打开 / 解压到此处 / 分别压缩），扩展不可用时可以兜底。找不到服务项时去「系统设置 → 键盘 → 键盘快捷键 → 服务 → 文件与文件夹」勾选一次。

FinderSync 任务转交和后续权限收敛设计见 [FinderSync IPC 方案](Docs/finder-ipc-design.md)。

## 测试

```bash
./scripts/test.sh
```

装好 7-Zip 引擎后，完整套件运行 **1212 项断言**。用例覆盖窗口路由与退出协调、共享暂存和预览缓存、CLI 真实归档操作、Quick Look 流式摘要、加密包和中文路径、软链与解压膨胀预检、访达队列、原子写入及设置回归。

CI 和发布流程共用 `./scripts/check-tests.sh`、`./scripts/check-targets.sh` 和 `./scripts/verify-bundle.sh`，校验测试基线、界面接线、三目标严格并发，以及打包产物和当前版本说明。

## 许可

GNU GPL-3.0（见 [LICENSE](LICENSE)）。因为使用了 MacPacker 的格式目录数据，整个仓库同样以 GPL-3.0 分发。

- 格式目录来源与改动说明：[NOTICE](NOTICE)
- 内置 7-Zip 引擎为 LGPL-2.1+（含 unRAR 限制），不随仓库分发，构建时按需下载

## 已知限制

- rar 只读；加密 rar 暂不支持
- 原地编辑只支持 zip 与 7z（7-Zip 的能力边界），tar / gz 系列不支持
- 嵌套包内的条目不能编辑：那是外层包的临时副本，改动不会保存；请先导出内层包
- 批量解压不支持加密包：会标记为「已加密，需要密码」并跳过
- 批量处理是串行队列，一次一个包，避免同时开多个 7zz 抢磁盘
- sit / sitx / lz4 / lzx 能识别但打不开
- 创建 TAR / TGZ 时不支持密码与分卷（格式本身不支持）
- 视频预览超过 800 MB 不在面板内加载，提示改用快速查看（解压整份文件到临时目录太慢）
- 文本预览只读前 120 KB
- 快速查看扩展只列条目，不预览条目内容
- **访达扩展带全盘读写例外**：ad-hoc 签名下扩展拿不到「用户已选择文件」的沙盒授权，只能用 `temporary-exception.files.absolute-path.read-write` 兜底。这意味着该扩展进程能读写整块磁盘。拿到 Developer ID 后要复验能否删掉这条（脚本 `scripts/poc-sandbox.sh`）
- 使用系统 libarchive 列目录时，密码通过进程内 API 传递，子进程参数中没有密码。7z 加密头仍由 7-Zip 列目录。调用 `tar` 或 `7zz` 执行需要密码的操作时，密码仍可能出现在进程参数中。
