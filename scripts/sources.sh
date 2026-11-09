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
    Sources/FinderSettings.swift
    Sources/PendingExtraction.swift
    Sources/PendingNotice.swift
    Sources/UniquePath.swift
)

# 只有主程序和测试用得到的设置解析层。
# 扩展不需要（它们不读解压位置），所以不并进 SHARED_STATE；
# 但测试要跑真实行为，Model.swift 依赖它，这里必须列进来。
APP_ONLY=(
    Sources/ExtractDestination.swift
    Sources/CacheMaintenance.swift
    # 退出状态机：不碰 AppKit，测试直接跑真的状态迁移
    Sources/AppLifecycle.swift
    # 键盘导航的滚动决策是纯几何，测试直接验「已可见就不动 / 只补差值」
    Sources/EntryScroll.swift
)

# 访达扩展的菜单判定与任务执行
FINDER_CORE=(
    FinderSync/MenuBuilder.swift
    FinderSync/JobKit.swift
    FinderSync/JobRunner.swift
)
