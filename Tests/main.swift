// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  入口：按主题分组跑，每组在各自文件里。
//  加测试时先找对应分组，不要再往这里堆。

import Foundation

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--tar-locale" {
    let archive = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("basic.zip")
    let entries = try? Tar.list(archive)
    exit(entries?.contains { $0.path == "说明.txt" && $0.modifiedDate != nil } == true ? 0 : 1)
}

runArchiveTests()
runModelTests()
runNavigationTests()
runFinderTests()
runFinderTaskQueueTests()
runSettingsTests()
runCompressTests()
runSaveAsTests()
runSaveAsBackgroundTests()
runResourceTests()
runInProcessArchiveTests()
runLifecycleTests()
runCacheTests()
runExitCoverageTests()
runSecurityTests()
finish()
