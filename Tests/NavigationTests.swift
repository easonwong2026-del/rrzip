// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//

//  原生手感的两条硬规则，用测试钉住：
//
//  1. 鼠标选中（单击 / ⌘ / ⇧ / ⌘A）绝不允许触发自动滚动，
//     只有键盘导航才会发滚动信号；
//  2. 滚动只补「超出视口的那点差值」，已经可见就不动。
//
//  这两个规则以前都是反的：`onChange(of: selection)` 无条件
//  `scrollTo(anchor: .center)`，点一行整页跳，⌘A 还会按无序 Set 随手挑一条居中。

import AppKit

func runNavigationTests() {
    testMinimalScrollDelta()
    testGridColumns()
    testMouseSelectionNeverScrolls()
    testKeyboardNavigationFollowsAnchor()
    testMultiSelectKeepsGroup()
    testRangeFollowsSortedOrder()
    testSearchResetsWhenSwitchingArchive()
    testSelectionPrunedWhenListChanges()
}

// MARK: - 纯几何

func testMinimalScrollDelta() {
    print("滚动决策 · 只补最小位移")
    let visible = CGRect(x: 0, y: 100, width: 300, height: 200)   // 视口 100...300
    let content: CGFloat = 1000

    expect(EntryScroll.minimalDelta(row: CGRect(x: 0, y: 150, width: 300, height: 32),
                                    visible: visible,
                                    contentHeight: content) == nil,
           "行完整可见时不滚")

    expect(EntryScroll.minimalDelta(row: CGRect(x: 0, y: 60, width: 300, height: 32),
                                    visible: visible,
                                    contentHeight: content) == -40,
           "行在视口上方：只补 40",
           "\(String(describing: EntryScroll.minimalDelta(row: CGRect(x: 0, y: 60, width: 300, height: 32), visible: visible, contentHeight: content)))")

    expect(EntryScroll.minimalDelta(row: CGRect(x: 0, y: 290, width: 300, height: 32),
                                    visible: visible,
                                    contentHeight: content) == 22,
           "行在视口下方：只补 22",
           "\(String(describing: EntryScroll.minimalDelta(row: CGRect(x: 0, y: 290, width: 300, height: 32), visible: visible, contentHeight: content)))")

    // 顶到内容头部：再滚就是空白，应当不动
    expect(EntryScroll.minimalDelta(row: CGRect(x: 0, y: 20, width: 300, height: 32),
                                    visible: CGRect(x: 0, y: 0, width: 300, height: 200),
                                    contentHeight: content) == nil,
           "已到内容顶部，不制造空白")

    // 顶到内容底部同理：已经在最大偏移上，再滚只会露白
    expect(EntryScroll.minimalDelta(row: CGRect(x: 0, y: 970, width: 300, height: 32),
                                    visible: CGRect(x: 0, y: 800, width: 300, height: 200),
                                    contentHeight: content) == nil,
           "已到内容底部，不制造空白")
}

func testGridColumns() {
    print("图标网格 · 列宽与键盘跳格一致")
    expect(IconGridLayout.columns(forWidth: 0) == 1, "宽度未知时按 1 列算，不会除以 0")
    expect(IconGridLayout.columns(forWidth: 300) == 2, "300 宽排 2 列",
           "\(IconGridLayout.columns(forWidth: 300))")
    expect(IconGridLayout.columns(forWidth: 700) == 5, "700 宽排 5 列",
           "\(IconGridLayout.columns(forWidth: 700))")
}

// MARK: - 选中语义

/// 打开 basic.zip 并等条目就绪；返回 (模型, 当前层的条目)
@MainActor
func openBasic() -> (ArchiveModel, [ArchiveEntry]) {
    let model = ArchiveModel()
    model.open(url: fixtures.appendingPathComponent("basic.zip"))
    _ = waitUntil(15) { model.current != nil && !model.displayEntries.isEmpty }
    return (model, model.displayEntries)
}

func testMouseSelectionNeverScrolls() {
    MainActor.assumeIsolated {
        print("鼠标选中 · 不触发滚动")
        let (model, list) = openBasic()
        guard list.count >= 3 else {
            expect(false, "basic.zip 至少 3 个条目", "\(list.count)")
            return
        }

        let base = model.keyboardScrollTick
        model.select(list[0])
        expect(model.keyboardScrollTick == base, "单击不发滚动信号")
        model.select(list[1], modifiers: .command)
        expect(model.keyboardScrollTick == base, "⌘ 单击不发滚动信号")
        model.select(list[2], modifiers: .shift)
        expect(model.keyboardScrollTick == base, "⇧ 连选不发滚动信号")
        model.selectAll()
        expect(model.keyboardScrollTick == base, "⌘A 不发滚动信号")

        model.moveSelection(by: 1)
        expect(model.keyboardScrollTick == base + 1, "键盘导航才发滚动信号")
    }
}

func testKeyboardNavigationFollowsAnchor() {
    MainActor.assumeIsolated {
        print("键盘导航 · 从锚点连续移动")
        let (model, list) = openBasic()
        guard list.count >= 3 else {
            expect(false, "basic.zip 至少 3 个条目", "\(list.count)")
            return
        }

        // 全选之后按向下：从「最后点击的那一条」接着走，
        // 以前是拿 Set 里的第一条当起点，多选一按方向键就跳回顶部附近
        model.selectAll()
        model.moveSelection(by: 1)
        expect(model.selection == [list[1].id], "全选后下移一格落在第二条",
               "\(model.selection)")

        // 键盘走过之后，⇧ 连选以它为锚点
        model.select(list[2], modifiers: .shift)
        expect(model.selection == [list[1].id, list[2].id], "⇧ 从键盘落点继续选",
               "\(model.selection)")

        // 预览跟着「当前这一条」，不是 Set 里的任意一条
        expect(model.selectedEntry?.id == list[2].id, "预览跟随最后操作的那条",
               model.selectedEntry?.id ?? "nil")

        // 到顶到底不越界
        model.moveSelection(by: -1)
        model.moveSelection(by: -1)
        expect(model.selection == [list[0].id], "向上到第一条就停")
        model.moveSelection(by: 99)
        expect(model.selection == [list[list.count - 1].id], "向下到最后一条就停")
    }
}

func testMultiSelectKeepsGroup() {
    MainActor.assumeIsolated {
        print("多选 · 不丢已选项")
        let (model, list) = openBasic()
        guard list.count >= 3 else {
            expect(false, "basic.zip 至少 3 个条目", "\(list.count)")
            return
        }

        model.select(list[0])
        model.select(list[1], modifiers: .command)
        model.select(list[2], modifiers: .command)
        expect(model.selection == [list[0].id, list[1].id, list[2].id],
               "⌘ 连点三次得到三条", "\(model.selection)")

        // ⌘ 再点一次取消这一条，其余保留
        model.select(list[1], modifiers: .command)
        expect(model.selection == [list[0].id, list[2].id], "⌘ 反选只摘掉点中的那条",
               "\(model.selection)")

        // ⇧ 连选从「最后一次点的那条」铺到落点（访达同款）
        model.select(list[2], modifiers: .shift)
        expect(model.selection == [list[1].id, list[2].id],
               "⇧ 从锚点铺到落点，不多选别的", "\(model.selection)")
    }
}

/// ⇧ 连选和方向键必须按**屏幕上看到的顺序**走。
/// 以前用的是索引里的原始顺序，按大小排序时 ⇧ 会圈到别的行。
func testRangeFollowsSortedOrder() {
    MainActor.assumeIsolated {
        print("排序后连选 · 跟屏幕顺序一致")
        let (model, _) = openBasic()
        guard model.displayEntries.count >= 3 else {
            expect(false, "basic.zip 至少 3 个条目")
            return
        }

        model.sortKey = .name
        model.sortAscending = false          // 名字倒序，屏幕顺序和索引顺序相反
        let shown = model.displayEntries
        guard shown.count >= 3 else {
            expect(false, "倒序后仍有条目")
            return
        }

        model.select(shown[0])
        model.select(shown[2], modifiers: .shift)
        expect(model.selection == [shown[0].id, shown[1].id, shown[2].id],
               "⇧ 圈住前三条（按显示顺序）", "\(model.selection)")

        // 方向键同样按显示顺序走
        model.moveSelection(by: 1)
        expect(model.selection == [shown[1].id], "向下一条落在显示顺序的第二条",
               "\(model.selection)")

        model.sortAscending = true
    }
}

// MARK: - 搜索与换包
func testSearchResetsWhenSwitchingArchive() {
    MainActor.assumeIsolated {
        print("换包 · 旧搜索条件不残留")
        let model = ArchiveModel()
        model.open(url: fixtures.appendingPathComponent("basic.zip"))
        expect(waitUntil(15) { model.current != nil && !model.displayEntries.isEmpty },
               "打开 basic.zip")

        model.searchText = "readme"
        expect(model.isSearching, "搜索生效")
        expect(model.displayEntries.isEmpty, "basic.zip 里没有 readme，列表为空")

        model.open(url: fixtures.appendingPathComponent("bundle.tgz"))
        expect(waitUntil(15) {
            model.current?.archive.lastPathComponent == "bundle.tgz" && !model.isLoading
        }, "切到 bundle.tgz")

        expect(model.searchText.isEmpty, "换包后关键词清空", model.searchText)
        expect(!model.displayEntries.isEmpty,
               "新包内容照常显示，不会被旧关键词筛成空包",
               "\(model.displayEntries.count)")
        expect(model.displayEntries.contains { $0.name == "readme.txt" },
               "bundle.tgz 的 readme.txt 看得见")
    }
}

func testSelectionPrunedWhenListChanges() {
    MainActor.assumeIsolated {
        print("改关键词 · 摘掉看不见的选中项")
        let (model, _) = openBasic()
        model.selectAll()
        expect(!model.selection.isEmpty, "先全选")

        model.searchText = "readme"
        expect(model.displayEntries.isEmpty, "没有匹配项")
        expect(model.selection.isEmpty, "看不见的选中项被摘掉，不会出现「已选 N 项」但没有内容",
               "\(model.selection.count)")

        model.searchText = ""
        expect(model.selection.isEmpty, "清空关键词也不会把旧选择捡回来")
    }
}
