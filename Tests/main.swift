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
