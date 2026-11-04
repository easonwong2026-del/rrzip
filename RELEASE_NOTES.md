## rrzip · macOS 原生归档工具

SwiftUI + 系统 libarchive + 内置 7-Zip 26.05。全部本地运行，不联网。

### 功能

- **浏览**：打开 / 拖入 / Finder「打开方式」，列表显示名称、大小、修改时间
- **嵌套包**：双击内嵌压缩包直接进入，面包屑可回退任意层（⌘[）
- **解压**：全部解压 ⌘E，或选中若干条目后 ⇧⌘E 只解这几项
- **预览**：选中即预览，图片内联、PDF 内嵌阅读、文本/代码直接显示
- **导出**：条目直接拖到访达
- **创建**：⌘N，可选 ZIP / 7Z / TAR / TAR.GZ
- **加密**：ZIP 用 AES-256，7Z 连文件名一起加密
- **分卷**：每卷 100 MB / 700 MB / 1 GB / 4 GB
- **加密包读取**：打开时提示输入密码，右上角可一键锁定清除
- **访达快速查看**：选中压缩包按空格，直接看条目列表

支持读取 zip · zipx · 7z（含加密头）· rar（只读）· tar · tgz · tbz2 · txz · gz · bz2 · xz · lzma · zst · cab · cpio · xar · iso · lzh · arj · rpm · deb

### 安装

1. 下载下方的 `rrzip-v*.zip`，解压得到 `rrzip.app`
2. 拖进「应用程序」文件夹
3. 首次打开若被系统拦截：**右键 → 打开**，或执行

   ```bash
   xattr -dr com.apple.quarantine /Applications/rrzip.app
   ```

   （本构建使用 ad-hoc 签名，没有走 Apple 公证，属于正常提示。）

### 系统要求

macOS 14 Sonoma 及以上，Apple Silicon（arm64）。

### 说明

- rar 只读，加密 rar 暂不支持
- 创建 TAR / TGZ 时不支持密码与分卷（格式本身不支持）
- 打开加密包时密码通过命令行参数传给 tar / 7zz，同机其他用户理论上能在 `ps` 里看到；单人机器无影响

代码 MIT，7-Zip 引擎为 LGPL + unRAR 限制，构建时按需下载，不随仓库分发。
