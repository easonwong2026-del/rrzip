// SPDX-License-Identifier: GPL-3.0-or-later
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

enum FormatCatalog {
    static let formats: [ArchiveFormatSpec] = [
        ArchiveFormatSpec(id: "7zip", name: "7-Zip Archive", extensions: ["7z"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], offset: 0, fromEnd: false)])], sevenZipType: "7z"),
        ArchiveFormatSpec(id: "ar", name: "Archiver Archive", extensions: ["ar", "deb"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x21, 0x3C, 0x61, 0x72, 0x63, 0x68, 0x3E, 0x0A], offset: 0, fromEnd: false)])], sevenZipType: "Ar"),
        ArchiveFormatSpec(id: "arj", name: "ARJ Archive", extensions: ["arj"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x60, 0xEA], offset: 0, fromEnd: false)])], sevenZipType: "Arj"),
        ArchiveFormatSpec(id: "bzip2", name: "Bzip2 File", extensions: ["bz2", "bz", "bzip2"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x42, 0x5A, 0x68], offset: 0, fromEnd: false)])], sevenZipType: "bzip2"),
        ArchiveFormatSpec(id: "cab", name: "CAB Archive", extensions: ["cab"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x4D, 0x53, 0x43, 0x46], offset: 0, fromEnd: false)])], sevenZipType: "Cab"),
        ArchiveFormatSpec(id: "cpio", name: "CPIO Archive", extensions: ["cpio"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x30, 0x37, 0x30, 0x37, 0x30, 0x31], offset: 0, fromEnd: false), MagicTest(bytes: [0x30, 0x37, 0x30, 0x37, 0x30, 0x32], offset: 0, fromEnd: false), MagicTest(bytes: [0x30, 0x37, 0x30, 0x37, 0x30, 0x37], offset: 0, fromEnd: false)])], sevenZipType: "Cpio"),
        ArchiveFormatSpec(id: "dmg", name: "Apple Disk Image", extensions: ["dmg", "smi", "img"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x6B, 0x6F, 0x6C, 0x79], offset: 512, fromEnd: true)])], sevenZipType: "Dmg"),
        ArchiveFormatSpec(id: "fat", name: "FAT Disk Image", extensions: ["fat"], rules: [], sevenZipType: "FAT"),
        ArchiveFormatSpec(id: "gzip", name: "Gzip File", extensions: ["gz", "gzip"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x1F, 0x8B], offset: 0, fromEnd: false)])], sevenZipType: "gzip"),
        ArchiveFormatSpec(id: "chm", name: "Microsoft Compiled HTML Help", extensions: ["chm"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x49, 0x54, 0x53, 0x46], offset: 0, fromEnd: false)])], sevenZipType: "Chm"),
        ArchiveFormatSpec(id: "iso", name: "ISO Disk Image", extensions: ["iso"], rules: [MagicGroup(matchAll: true, tests: [MagicTest(bytes: [0x43, 0x44, 0x30, 0x30, 0x31], offset: 32769, fromEnd: false), MagicTest(bytes: [0x43, 0x44, 0x30, 0x30, 0x31], offset: 34817, fromEnd: false), MagicTest(bytes: [0x43, 0x44, 0x30, 0x30, 0x31], offset: 36865, fromEnd: false)])], sevenZipType: "Iso"),
        ArchiveFormatSpec(id: "lha", name: "LHA/LZH Archive", extensions: ["lha", "lzh"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x2D, 0x6C, 0x68, 0x30, 0x2D], offset: 2, fromEnd: false), MagicTest(bytes: [0x2D, 0x6C, 0x68, 0x35, 0x2D], offset: 2, fromEnd: false), MagicTest(bytes: [0x2D, 0x6C, 0x68, 0x64, 0x2D], offset: 2, fromEnd: false)])], sevenZipType: "Lzh"),
        ArchiveFormatSpec(id: "lz4", name: "LZ4 File", extensions: ["lz4"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x04, 0x22, 0x4D, 0x18], offset: 0, fromEnd: false)])], sevenZipType: nil),
        ArchiveFormatSpec(id: "lzma", name: "LZMA File", extensions: ["lzma"], rules: [], sevenZipType: "lzma"),
        ArchiveFormatSpec(id: "lzx", name: "LZX Archive", extensions: ["lzx"], rules: [], sevenZipType: nil),
        ArchiveFormatSpec(id: "msapp", name: "Microsoft Windows application", extensions: ["exe"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x4D, 0x5A], offset: 0, fromEnd: false)])], sevenZipType: "PE"),
        ArchiveFormatSpec(id: "msi", name: "Microsoft MSI Installer", extensions: ["msi"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1], offset: 0, fromEnd: false)])], sevenZipType: "Compound"),
        ArchiveFormatSpec(id: "ntfs", name: "NTFS Disk Image", extensions: ["ntfs"], rules: [], sevenZipType: "NTFS"),
        ArchiveFormatSpec(id: "pkg", name: "Apple Software Package", extensions: ["pkg"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x78, 0x61, 0x72, 0x21], offset: 0, fromEnd: false)])], sevenZipType: "Xar"),
        ArchiveFormatSpec(id: "qcow2", name: "QCOW2 Disk Image", extensions: ["qcow2"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x51, 0x46, 0x49, 0xFB], offset: 0, fromEnd: false)])], sevenZipType: "QCOW"),
        ArchiveFormatSpec(id: "rar", name: "RAR Archive", extensions: ["rar", "cbr"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00], offset: 0, fromEnd: false), MagicTest(bytes: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00], offset: 0, fromEnd: false)])], sevenZipType: "Rar"),
        ArchiveFormatSpec(id: "rpm", name: "Linux RPM archive", extensions: ["rpm"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0xED, 0xAB, 0xEE, 0xDB], offset: 0, fromEnd: false)])], sevenZipType: "Rpm"),
        ArchiveFormatSpec(id: "sea", name: "Self-Extracting Archive", extensions: ["sea"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x53, 0x74, 0x75, 0x66, 0x66, 0x49, 0x74, 0x20], offset: 0, fromEnd: false)])], sevenZipType: nil),
        ArchiveFormatSpec(id: "sit", name: "StuffIt Archive", extensions: ["sit"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x53, 0x74, 0x75, 0x66, 0x66, 0x49, 0x74, 0x20], offset: 0, fromEnd: false)])], sevenZipType: nil),
        ArchiveFormatSpec(id: "sitx", name: "StuffIt X Archive", extensions: ["sitx"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x53, 0x74, 0x75, 0x66, 0x66, 0x49, 0x74, 0x21], offset: 0, fromEnd: false)])], sevenZipType: nil),
        ArchiveFormatSpec(id: "squashfs", name: "SquashFS Disk Image", extensions: ["squashfs"], rules: [], sevenZipType: "SquashFS"),
        ArchiveFormatSpec(id: "tar", name: "Tar Archive", extensions: ["tar"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x75, 0x73, 0x74, 0x61, 0x72, 0x00, 0x30, 0x30], offset: 257, fromEnd: false), MagicTest(bytes: [0x75, 0x73, 0x74, 0x61, 0x72, 0x20, 0x20, 0x00], offset: 257, fromEnd: false)])], sevenZipType: "tar"),
        ArchiveFormatSpec(id: "vdi", name: "VDI Disk Image", extensions: ["vdi"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x7F, 0x10, 0xDA, 0xBE], offset: 64, fromEnd: false)])], sevenZipType: "VDI"),
        ArchiveFormatSpec(id: "vmdk", name: "VMDK Disk Image", extensions: ["vmdk"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x4B, 0x44, 0x4D], offset: 0, fromEnd: false)])], sevenZipType: "VMDK"),
        ArchiveFormatSpec(id: "vhd", name: "VHD Disk Image", extensions: ["vhd"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x63, 0x6F, 0x6E, 0x65, 0x63, 0x74, 0x69, 0x78], offset: 0, fromEnd: false)])], sevenZipType: "VHD"),
        ArchiveFormatSpec(id: "vhdx", name: "VHDX Disk Image", extensions: ["vhdx"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x76, 0x68, 0x64, 0x78, 0x66, 0x69, 0x6C, 0x65], offset: 0, fromEnd: false)])], sevenZipType: "VHDX"),
        ArchiveFormatSpec(id: "wim", name: "WIM Disk Image", extensions: ["wim"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x4D, 0x53, 0x57, 0x49, 0x4D, 0x00, 0x00, 0x00], offset: 0, fromEnd: false)])], sevenZipType: "wim"),
        ArchiveFormatSpec(id: "xar", name: "XAR Archive", extensions: ["xar"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x78, 0x61, 0x72, 0x21], offset: 0, fromEnd: false)])], sevenZipType: "Xar"),
        ArchiveFormatSpec(id: "xz", name: "XZ File", extensions: ["xz"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], offset: 0, fromEnd: false)])], sevenZipType: "xz"),
        ArchiveFormatSpec(id: "z", name: "Unix Compress File", extensions: ["z"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x1F, 0x9D], offset: 0, fromEnd: false)])], sevenZipType: "Z"),
        ArchiveFormatSpec(id: "zip", name: "ZIP Archive", extensions: ["zip", "jar", "aar", "apk", "cbz"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x50, 0x4B, 0x03, 0x04], offset: 0, fromEnd: false), MagicTest(bytes: [0x50, 0x4B, 0x03, 0x06], offset: 0, fromEnd: false), MagicTest(bytes: [0x50, 0x4B, 0x03, 0x08], offset: 0, fromEnd: false)])], sevenZipType: "zip"),
        ArchiveFormatSpec(id: "zipx", name: "ZIPX Archive", extensions: ["zipx"], rules: [MagicGroup(matchAll: false, tests: [MagicTest(bytes: [0x50, 0x4B, 0x03, 0x04], offset: 0, fromEnd: false), MagicTest(bytes: [0x50, 0x4B, 0x03, 0x06], offset: 0, fromEnd: false), MagicTest(bytes: [0x50, 0x4B, 0x03, 0x08], offset: 0, fromEnd: false)])], sevenZipType: "zip"),
    ]

    static let compounds: [CompoundSpec] = [
        CompoundSpec(id: "tar.bz2", name: "Bzip2 Tar Archive", extensions: ["tbz2", "tbz", "tbzip2", "tb", "tb2", "tar.bz2"], components: ["tar", "bzip2"]),
        CompoundSpec(id: "tar.gz", name: "Gzip Tar Archive", extensions: ["tgz", "tgzip", "tar.gz"], components: ["tar", "gzip"]),
        CompoundSpec(id: "tar.lz4", name: "LZ4 Tar Archive", extensions: ["tlz4", "tar.lz4"], components: ["tar", "lz4"]),
        CompoundSpec(id: "tar.lzma", name: "LZMA Tar Archive", extensions: ["tlzma", "tar.lzma"], components: ["tar", "lzma"]),
        CompoundSpec(id: "tar.xz", name: "XZ Tar Archive", extensions: ["txz", "tar.xz"], components: ["tar", "xz"]),
        CompoundSpec(id: "tar.z", name: "Z Tar Archive", extensions: ["taz", "tar.z"], components: ["tar", "z"]),
    ]

    static let splits: [SplitSpec] = [
        SplitSpec(id: "zip-spanned", name: "Spanned ZIP", format: "zip", scheme: "spanned", pattern: "\\.z[0-9]{2,}$"),
        SplitSpec(id: "zip-numeric", name: "Split ZIP", format: "zip", scheme: "numeric", pattern: "\\.zip\\.[0-9]{3,}$"),
        SplitSpec(id: "7z-numeric", name: "Split 7z", format: "7zip", scheme: "numeric", pattern: "\\.7z\\.[0-9]{3,}$"),
    ]
}
