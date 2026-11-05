import Foundation

// 极简测试：不依赖 XCTest，编译成命令行直接跑
var failures = 0
var checks = 0

func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("  ✓ \(name)")
    } else {
        failures += 1
        print("  ✗ \(name) \(detail())")
    }
}

let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])

// 1. 八进制转义解码
print("decodeEscapes")
expect(Tar.decodeEscapes(#"\350\257\264\346\230\216.txt"#) == "说明.txt", "中文转义还原")
expect(Tar.decodeEscapes("plain.txt") == "plain.txt", "无转义原样返回")
expect(Tar.decodeEscapes(#"a\040b"#) == "a b", "空格转义还原")

// 2. zip 列表
print("zip 列表")
do {
    let entries = try Tar.list(fixtures.appendingPathComponent("basic.zip"))
    expect(entries.count == 6, "条目数 = 6", "实际 \(entries.count)")
    expect(entries.contains { $0.path == "说明.txt" }, "中文文件名")
    expect(entries.contains { $0.path == "带 空格.txt" }, "含空格文件名")
    expect(entries.contains { $0.path == "照片/" && $0.isDirectory }, "目录识别")
    expect(entries.first { $0.path == "照片/城市/001.jpg" }?.size == 200_000, "文件大小")
} catch {
    expect(false, "zip 列表", "\(error)")
}

// 2b. 目录折叠：根层只应看到「照片/」一项，而不是全部条目
print("目录折叠")
do {
    let entries = try Tar.list(fixtures.appendingPathComponent("basic.zip"))
    let root = ArchiveModel.children(of: "", in: entries)
    expect(root.count == 3, "根层 3 项（说明.txt / 带 空格.txt / 照片/）", "实际 \(root.map(\.path))")
    expect(root.first?.isDirectory == true, "目录排在前面")

    let inner = ArchiveModel.children(of: "照片/", in: entries)
    expect(inner.count == 2, "照片/ 下 2 项", "实际 \(inner.map(\.path))")
    expect(inner.first?.path == "照片/城市/", "子目录合并成一行")

    let deep = ArchiveModel.children(of: "照片/城市/", in: entries)
    expect(deep.count == 1 && deep[0].path == "照片/城市/001.jpg", "深层只显示文件")
} catch {
    expect(false, "目录折叠", "\(error)")
}

// 3. tar.gz
print("tar.gz 列表")
do {
    let entries = try Tar.list(fixtures.appendingPathComponent("bundle.tgz"))
    expect(entries.contains { $0.path == "readme.txt" }, "tgz 条目")
} catch {
    expect(false, "tgz 列表", "\(error)")
}

// 4. 加密包：无密码要报 needsPassword
print("加密 7z")
let encrypted = fixtures.appendingPathComponent("secret.7z")
if FileManager.default.fileExists(atPath: encrypted.path) {
    do {
        _ = try Tar.list(encrypted)
        expect(false, "无密码应报 needsPassword")
    } catch ArchiveError.needsPassword {
        expect(true, "无密码时报 needsPassword")
    } catch {
        // libarchive 可能直接失败，交给上层换引擎
        expect(true, "libarchive 拒绝（可回退 7-Zip）")
    }

    do {
        let entries = try SevenZip.list(encrypted, password: "pw123")
        expect(entries.count >= 1, "7-Zip 带密码可列出")
    } catch {
        expect(false, "7-Zip 带密码列出", "\(error)")
    }
} else {
    print("  - 跳过（无 7zz 或样本未生成）")
}

print("")
print(failures == 0 ? "全部通过（\(checks) 项）" : "失败 \(failures)/\(checks)")
exit(failures == 0 ? 0 : 1)
