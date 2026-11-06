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
    Sources/FormatCatalog.swift
    Sources/FormatDetector.swift
    Sources/ArchiveService.swift
)

# 扩展与主程序之间的跨进程协作：设置、待解压、待提示、唯一命名
SHARED_STATE=(
    Sources/FinderSettings.swift
    Sources/PendingExtraction.swift
    Sources/PendingNotice.swift
    Sources/UniquePath.swift
)

# 访达扩展的菜单判定与任务执行
FINDER_CORE=(
    FinderSync/MenuBuilder.swift
    FinderSync/JobKit.swift
    FinderSync/JobRunner.swift
)
