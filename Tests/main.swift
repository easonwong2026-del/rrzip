// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  入口：按主题分组跑，每组在各自文件里。
//  加测试时先找对应分组，不要再往这里堆。

import Foundation

runArchiveTests()
runModelTests()
runNavigationTests()
runFinderTests()
runSettingsTests()
runCompressTests()
runSaveAsTests()
runSaveAsBackgroundTests()
runResourceTests()
runInProcessArchiveTests()
runLifecycleTests()
runCacheTests()
runExitCoverageTests()
finish()
