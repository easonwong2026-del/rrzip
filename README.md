# rrzip

[![ci](https://github.com/easonwong2026-del/rrzip/actions/workflows/ci.yml/badge.svg)](https://github.com/easonwong2026-del/rrzip/actions/workflows/ci.yml)

macOS 原生压缩包工作台。SwiftUI + 系统 libarchive（`/usr/bin/tar`）+ 内置 7-Zip 26.05。

代码、界面、文案全部独立编写，未使用任何第三方商业软件的代码或素材。

## 功能

| 功能 | 说明 |
|---|---|
| 打开 / 拖入 | 单文件选择、拖拽到窗口、Finder「打开方式」、`⌘O` |
| 列表浏览 | 名称、大小、修改时间；目录 / 压缩包 / 图片 / 文档区分图标 |
| **目录层级** | 双层按目录折叠，双击进入下一层，面包屑可回退；不再平铺全部条目 |
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
| **两种视图** | 列表 / 图标网格一键切换 |
| **快捷操作条** | 选中后浮出「解压到… / 导出…」 |
| **访达右键** | 选中文件后「服务 → 用 rrzip 压缩 / 用 rrzip 打开」 |
| 命令行 | `rrzip --list <包> [--pass 密码]` |

## 双引擎策略

| 场景 | 引擎 |
|---|---|
| 常规 zip / tar / gz / rar / iso 等读取 | 系统 `bsdtar`（libarchive 3.7.4） |
| 创建 7z、加密、分卷 | 内置 `7zz`（7-Zip 26.05 arm64） |
| 加密头 7z（libarchive 不支持） | 内置 `7zz` |

`7zz` 位于 `Contents/Resources/7zz`，随应用分发，用户无需另装。

## 支持格式

读取：zip · zipx · 7z（含加密头）· rar（只读）· tar · tgz · tbz2 · txz · gz · bz2 · xz · lzma · lz · zst · cab · cpio · xar · iso · lzh · arj · rpm · deb
写入：zip · 7z · tar · tgz

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
│   ├── Archive.swift          # 条目模型 + bsdtar / 7zz 双引擎封装
│   ├── Model.swift            # 状态机：打开、密码、嵌套栈、解压、创建
│   ├── ContentView.swift      # 主界面
│   └── PreviewPane.swift      # 右侧预览
├── QuickLook/
│   └── PreviewProvider.swift  # 快速查看扩展（QLPreviewingController）
├── Tests/
│   └── main.swift             # 11 项断言（解析 / 转义 / 加密回退）
├── Assets/
│   ├── AppIcon.icns
│   └── 7zz                    # 不入库，构建时下载
├── scripts/
│   ├── fetch-7zz.sh
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

自动生成带中文名、含空格、嵌套目录、加密 7z 的样例包，断言 11 项：八进制转义还原、zip/tgz 列表、目录识别、文件大小、加密包识别与 7-Zip 回退。

## 许可

本仓库代码 MIT。内置的 7-Zip 引擎为 LGPL + unRAR 限制，不随仓库分发，构建时按需下载。

## 已知限制

- rar 只读；加密 rar 暂不支持
- 创建 TAR / TGZ 时不支持密码与分卷（格式本身不支持）
- 预览大文件一次性读入内存，几百 MB 以上会慢
- 快速查看扩展只列条目，不预览条目内容
- 打开加密包时密码通过命令行参数传给 tar / 7zz，**同机其他用户理论上能在 `ps` 里看到**。单人使用的机器没问题，多用户共享机器上不要用它开加密包（libarchive 与 7-Zip 都不支持从标准输入读密码）
