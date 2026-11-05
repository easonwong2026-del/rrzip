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
| **三栏布局** | 目录树 / 内容 / 详情面板，右侧显示归档格式、大小、条目数、加密状态、修改时间 |
| 嵌套包浏览 | 双击内嵌包进入，面包屑可回退任意层（`⌘[`） |
| 全部解压 | `⌘E` |
| 选择性解压 | 选中条目后 `⇧⌘E` |
| 快速预览 | 图片内联、PDF 内嵌阅读、文本/代码直接显示 |
| 拖拽导出 | 从列表拖到访达 |
| 创建压缩包 | `⌘N`：ZIP / **7Z** / TAR / TAR.GZ |
| **加密** | ZIP 用 AES-256；7Z 连文件名一起加密（`-mhe=on`） |
| **分卷** | 100 MB / 700 MB / 1 GB / 4 GB |
| **加密包读取** | 打开时提示输入密码；右上角可一键锁定并清除密码 |
| **访达快速查看** | 按空格直接看压缩包内容（`ArchivePreview.appex`） |
| **包内搜索** | 工具栏搜索框，跨层级匹配，结果显示完整路径 |
| **三种视图** | 列表 / 图标网格 / **分栏列视图** 一键切换 |
| **类型配色** | 文件夹蓝、压缩包紫、图片橙、PDF 红、视频粉、音频青、代码绿、磁盘靛，深浅色都适配 |
| **外观切换** | ⋯ 菜单里可选「跟随系统 / 浅色 / 深色」 |
| **悬停预览** | 鼠标停 0.4 秒在光标旁弹出内容卡片：图片与 PDF 出大图，文本出前几行 |
| **Mini 小窗** | 常驻置顶的小窗，**多标签**同时开多个包；拖入即看、双击进目录、拖文件出来 |
| **暂存拖拽** | 条目可直接拖进暂存条（只记包内路径，不解压） |
| **批量处理** | 一次拖入多个包（或 ⇧⌘B）进入批量面板：批量解压到各自文件夹，或批量校验 |
| **完整性校验** | 用 `7zz t` 完整读一遍，损坏的文件会指出具体条目 |
| **暂存区** | 把条目攒起来，跨目录、跨压缩包累积，最后一次导出或打包成 ZIP |
| **图片 / PDF / 视频缩略图** | 图片走 ImageIO，PDF 渲染首页，视频取首帧（AVFoundation）；按需解压 + 缓存 |
| **键盘导航** | ↑↓ 选择、回车进入、空格快速查看、←（或 ⌘↑）返回上级 |
| **空格快速查看** | 系统快速查看面板全屏预览选中条目，再按空格关闭 |
| **快捷操作条** | 选中后浮出「解压到… / 导出…」 |
| **访达右键** | 选中文件后「服务 → 用 rrzip 压缩 / 用 rrzip 打开」 |
| **格式识别** | 先看后缀，后缀不认识就读内容（magic number），改名/无后缀的文件也能打开 |
| **原地编辑** | 往压缩包里加文件、删条目，保存后直接写回原包（嵌套包内不可用） |
| **磁盘映像** | DMG、ISO、VHD/VHDX、VDI、VMDK、QCOW2、WIM 等交给内置 7-Zip 打开 |
| 命令行 | `rrzip --list <包>` · `--detect <文件>` · `--thumb <包> <条目> <out.png>` · `--add` · `--remove` |

## 性能

- 条目列表按「父目录 → 子项」建一次索引，之后取一层是 O(1)；10 万条目的包切目录不再重算
- 索引构建实测：10 万条目 < 1 秒（见 `Tests/main.swift` 的基准断言）
- 缩略图按需解压、降采样后进 NSCache，缓存键含归档路径与目标尺寸，不同包不会串图
- 悬停卡片只在停留 0.4 秒后触发，移动即取消
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

`Assets/7zz` 是第三方二进制，不入库；`scripts/fetch-7zz.sh` 会从官方 release 拉取（直连失败自动走镜像）。

依赖：macOS 14+、Xcode Command Line Tools（`swiftc` 6.x）。

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
├── Sources/
│   ├── Archive.swift          # 条目模型 + bsdtar / 7zz 双引擎封装（含增删）
│   ├── FormatCatalog.swift    # 格式目录（数据来自 MacPacker，生成文件）
│   ├── FormatDetector.swift   # 后缀 + 魔数识别
│   ├── Palette.swift          # 品牌色 + 文件类型色板
│   ├── HoverPreview.swift     # 悬停预览浮窗
│   ├── QuickLook.swift        # 空格快速查看（QLPreviewPanel）
│   ├── MiniPanel.swift        # Mini 常驻小窗
│   ├── Batch.swift            # 批量解压 / 校验面板
│   ├── Model.swift            # 状态机：打开、密码、嵌套栈、解压、创建
│   ├── ContentView.swift      # 主界面
│   └── PreviewPane.swift      # 右侧预览
├── QuickLook/
│   └── PreviewProvider.swift  # 快速查看扩展（QLPreviewingController）
├── Tests/
│   └── main.swift             # 35 项断言（解析 / 转义 / 加密 / 识别 / 编辑 / 索引性能）
├── Assets/
│   ├── AppIcon.icns
│   └── 7zz                    # 不入库，构建时下载
├── scripts/
│   ├── fetch-7zz.sh
│   ├── gen-catalog.py
│   └── test.sh
├── build.sh
└── build/rrzip.app
```

## 访达右键菜单

应用启动后会在访达的「服务」菜单里注册两项（右键 → 服务）：

- **用 rrzip 压缩**：在源文件旁边生成同名 zip，重名自动加序号
- **用 rrzip 打开**：选中压缩包时直接打开

如果没看到，去「系统设置 → 键盘 → 键盘快捷键 → 服务 → 文件与文件夹」勾选一次。

## 测试

```bash
./scripts/test.sh
```

自动生成带中文名、含空格、嵌套目录、加密 7z 的样例包，断言 35 项：八进制转义还原、zip/tgz 列表、目录折叠、加密包识别与 7-Zip 回退、后缀与魔数识别、原地增删、子项索引一致性与 10 万条目性能。

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
- 预览大文件一次性读入内存，几百 MB 以上会慢
- 快速查看扩展只列条目，不预览条目内容
- 打开加密包时密码通过命令行参数传给 tar / 7zz，**同机其他用户理论上能在 `ps` 里看到**。单人使用的机器没问题，多用户共享机器上不要用它开加密包（libarchive 与 7-Zip 都不支持从标准输入读密码）
