#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 rrzip contributors
#
# 从 MacPacker 的 Catalog.json 生成 Sources/FormatCatalog.swift。
#
# 用法：
#   ./scripts/gen-catalog.py [Catalog.json 路径]
#
# 默认读取 ./vendor/Catalog.json，也可以用参数指定，例如：
#   curl -sL https://raw.githubusercontent.com/sarensw/MacPacker/main/Modules/Sources/Core/Formats/Catalog.json -o /tmp/Catalog.json
#   ./scripts/gen-catalog.py /tmp/Catalog.json
#
# 数据来源与许可说明见 NOTICE。

import json
import sys
from pathlib import Path

# 格式 id → 内置 7-Zip 的类型名（依据 `7zz i` 的实测输出）
# 值为 None 表示 7-Zip 也不支持：只能识别，不能打开
SEVENZIP_TYPES = {
    "7zip": "7z", "ar": "Ar", "arj": "Arj", "bzip2": "bzip2", "cab": "Cab",
    "cpio": "Cpio", "dmg": "Dmg", "fat": "FAT", "gzip": "gzip", "chm": "Chm",
    "iso": "Iso", "lha": "Lzh", "msapp": "PE", "msi": "Compound", "ntfs": "NTFS",
    "pkg": "Xar", "qcow2": "QCOW", "rar": "Rar", "rpm": "Rpm",
    "squashfs": "SquashFS", "tar": "tar", "vdi": "VDI", "vmdk": "VMDK",
    "vhd": "VHD", "vhdx": "VHDX", "wim": "wim", "xar": "Xar", "xz": "xz",
    "z": "Z", "zip": "zip", "zipx": "zip", "lzma": "lzma",
}


def bytes_literal(text: str) -> str:
    if not text:
        return "[]"
    return "[" + ", ".join("0x%02X" % int(b, 16) for b in text.split()) + "]"


def swift_string(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "vendor" / "Catalog.json"
    if not source.exists():
        print(f"找不到 {source}，请先下载 Catalog.json 或显式传入路径", file=sys.stderr)
        return 1

    data = json.loads(source.read_text())

    out = []
    out.append('''// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
//  格式目录数据取自 MacPacker（https://github.com/sarensw/MacPacker，GPL-3.0）
//  的 Modules/Sources/Core/Formats/Catalog.json，按其条款一并以 GPL-3.0 分发。
//  改动：只保留识别所需字段，补充与本项目引擎对应的 7-Zip 类型名。
//  详见 NOTICE。
//
//  这个文件由 scripts/gen-catalog.py 生成，不要手改。
//

import Foundation

/// 一条 magic 判定：字节序列出现在指定位置
struct MagicTest: Hashable {
    let bytes: [UInt8]
    /// `fromEnd` 为 true 时表示从文件末尾倒数（例如 DMG 的 koly 尾标记）
    let offset: Int
    let fromEnd: Bool
}

/// 一组判定，组内按 any / all 合并
struct MagicGroup: Hashable {
    let matchAll: Bool
    let tests: [MagicTest]
}

/// 一种受支持的归档格式
struct ArchiveFormatSpec: Hashable, Identifiable {
    let id: String
    let name: String
    let extensions: [String]
    let rules: [MagicGroup]
    /// 交给内置 7-Zip 时的类型名；nil 表示本机引擎打不开，仅能识别
    let sevenZipType: String?

    var isOpenable: Bool { sevenZipType != nil }
}

/// 复合后缀，例如 tar.gz = tar + gzip
struct CompoundSpec: Hashable {
    let id: String
    let name: String
    let extensions: [String]
    /// 组成顺序，首个是最终形态
    let components: [String]
}

/// 分卷方案，例如 x.zip.001 / x.z01
struct SplitSpec: Hashable {
    let id: String
    let name: String
    let format: String
    let scheme: String
    let pattern: String
}
''')

    out.append("enum FormatCatalog {")
    out.append("    static let formats: [ArchiveFormatSpec] = [")
    for fmt in data["formats"]:
        rules = []
        for group in fmt.get("rules") or []:
            tests = ", ".join(
                "MagicTest(bytes: %s, offset: %d, fromEnd: %s)"
                % (bytes_literal(t["bytes"]), t.get("offset", 0),
                   "true" if t["type"] == "end_signature" else "false")
                for t in group["tests"]
            )
            rules.append("MagicGroup(matchAll: %s, tests: [%s])"
                         % ("true" if group["policy"] == "all" else "false", tests))
        sz = SEVENZIP_TYPES.get(fmt["id"])
        out.append(
            '        ArchiveFormatSpec(id: %s, name: %s, extensions: [%s], rules: [%s], sevenZipType: %s),'
            % (swift_string(fmt["id"]), swift_string(fmt["name"]),
               ", ".join(swift_string(e) for e in fmt.get("extensions") or []),
               ", ".join(rules), swift_string(sz) if sz else "nil"))
    out.append("    ]")
    out.append("")

    out.append("    static let compounds: [CompoundSpec] = [")
    for comp in data["compounds"]:
        out.append('        CompoundSpec(id: %s, name: %s, extensions: [%s], components: [%s]),'
                   % (swift_string(comp["id"]), swift_string(comp["name"]),
                      ", ".join(swift_string(e) for e in comp.get("extensions") or []),
                      ", ".join(swift_string(c) for c in comp.get("components") or [])))
    out.append("    ]")
    out.append("")

    out.append("    static let splits: [SplitSpec] = [")
    for split in data["splits"]:
        out.append('        SplitSpec(id: %s, name: %s, format: %s, scheme: %s, pattern: %s),'
                   % (swift_string(split["id"]), swift_string(split["name"]),
                      swift_string(split["format"]), swift_string(split["scheme"]),
                      swift_string(split["pattern"])))
    out.append("    ]")
    out.append("}")

    target = root / "Sources" / "FormatCatalog.swift"
    target.write_text("\n".join(out) + "\n")
    openable = sum(1 for f in data["formats"] if f["id"] in SEVENZIP_TYPES)
    print(f"写入 {target}：{len(data['formats'])} 种格式，其中 {openable} 种可打开")
    return 0


if __name__ == "__main__":
    sys.exit(main())
