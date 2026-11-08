// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//

//  键盘导航时的滚动决策。
//
//  以前用 `ScrollViewReader.scrollTo(id, anchor: .center)`：不管选中项在不在
//  视口里都滚，而且一定是「居中」——鼠标点一行，整页就跳到把这一行摆中间。
//  这里只算「为了露出来还差多少」，已经可见就是 nil（一步都不动），
//  需要滚动时也只补差值，不居中。纯几何，测试里直接验。

import CoreGraphics
import Foundation

enum EntryScroll {
    /// 把 `row` 露出来需要滚动的位移；已经完全可见、或顶到内容边界动不了就是 nil。
    ///
    /// - Parameters:
    ///   - row: 行在滚动视图坐标系里的矩形
    ///   - visible: 当前可见矩形（滚动视图的 bounds）
    ///   - contentHeight: 内容总高度，用来把位移夹在可滚范围内
    /// - Returns: 需要加到 `visible.origin.y` 上的位移；正数向下（同一坐标系内）
    static func minimalDelta(row: CGRect, visible: CGRect, contentHeight: CGFloat) -> CGFloat? {
        let above = row.minY < visible.minY
        let below = row.maxY > visible.maxY
        guard above || below else { return nil }

        let raw = above ? row.minY - visible.minY : row.maxY - visible.maxY
        let maxOrigin = max(0, contentHeight - visible.height)
        let target = min(max(visible.minY + raw, 0), maxOrigin)
        let delta = target - visible.minY
        // 夹完还是 0：已经顶到内容头/尾，再滚就是空白，不动
        return delta == 0 ? nil : delta
    }
}

/// 什么时候该把选中项滚进视口。
///
/// 只有两种情况：键盘导航（tick 由模型发），以及布局切换（视图重建之后补一次定位）。
/// 关键点是**首次同步只记基线**：视图新建时拿到的 tick 是「当前值」，
/// 不是「刚发生的变化」，照它滚一次会在切目录、切布局时平白跳一下。
struct EntryRevealGate {
    private var lastTick: Int?

    /// - Returns: 这次 tick 是否代表「需要滚一下」
    mutating func shouldReveal(tick: Int, active: Bool) -> Bool {
        defer { lastTick = tick }
        guard active, let lastTick else { return false }
        return lastTick != tick
    }
}

/// 图标网格的列宽规则。视图与键盘导航共用一份，
/// 否则「下键跳一格还是跳一行」会和屏幕上看到的行对不上。
enum IconGridLayout {
    static let tileMin: CGFloat = 116
    static let spacing: CGFloat = 6
    static let padding: CGFloat = 14

    /// adaptive 网格的实际列数：与 SwiftUI 的算法一致，最少 1 列
    static func columns(forWidth width: CGFloat) -> Int {
        let available = width - padding * 2
        guard available > 0 else { return 1 }
        let count = Int((available + spacing) / (tileMin + spacing))
        return max(1, count)
    }
}

#if DEBUG
/// 调试构建才写入的落盘日志。滚动时序问题截图看不出来，
/// 只在 DEBUG=1 构建里生效，发布产物里整个不存在。
enum DebugLog {
    private static let path = "/tmp/rrzip-reveal.log"

    static func reveal(_ line: String) {
        let text = line + "\n"
        guard let data = text.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
