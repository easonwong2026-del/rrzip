#!/bin/bash
# 共享源文件清单。
#
# build.sh（两个扩展）和 scripts/test.sh（测试可执行文件）以前各自列了一遍，
# 新增一个文件要改两处，漏一处就是 CI 红了才发现。这里收成一份。
#
# 主程序不在这里：它用 Sources/*.swift 通配，不需要列。

# 解析、列表、创建的引擎层。三个 target 都要
ARCHIVE_CORE=(
    Sources/Archive.swift
    Sources/InProcessArchive.swift
    Sources/FormatCatalog.swift
    Sources/FormatDetector.swift
    Sources/ArchiveService.swift
)

# 扩展与主程序之间的跨进程协作：设置、待解压、待提示、唯一命名
SHARED_STATE=(
    Sources/JobCenter.swift
    Sources/FinderTaskQueue.swift
    Sources/FinderSettings.swift
    Sources/PendingExtraction.swift
    Sources/PendingNotice.swift
    Sources/UniquePath.swift
)

# 主程序与测试共用的模型、界面流程和写入协调，扩展不编入这些文件。
APP_ONLY=(
    Sources/ArchiveWriter.swift
    Sources/ArchiveIndex.swift
    Sources/PayloadCache.swift
    Sources/ArchiveStash.swift
    Sources/ExtractDestination.swift
    Sources/CacheMaintenance.swift
    # 退出状态机：不碰 AppKit，测试直接跑真的状态迁移
    Sources/AppLifecycle.swift
    # 正式写入账本：原地编辑与访达服务靠它被退出协调看见
    Sources/FormalWriteLedger.swift
    # 访达服务执行体：测试直接调，验证它进账本、走原子写
    Sources/FinderService.swift
    Sources/FinderJobKit.swift
    Sources/FinderJobRunner.swift
    Sources/FinderTaskWorker.swift
    # 键盘导航的滚动决策是纯几何，测试直接验「已可见就不动 / 只补差值」
    Sources/EntryScroll.swift
)

# 访达扩展的菜单判定
FINDER_CORE=(
    FinderSync/MenuBuilder.swift
)

# 扩展入口也编入测试，用真实控制器验证 Quick Look 完成回调。
QUICKLOOK_CORE=(QuickLook/PreviewProvider.swift)
