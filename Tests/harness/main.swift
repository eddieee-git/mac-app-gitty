// Gitty 동작 시험. Xcode 없이 돌도록 XCTest 대신 앱 소스와 함께 컴파일하는 작은 프로그램이다.
// 실행: ./scripts/test.sh
import Foundation
import CryptoKit

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "  ✓" : "  ✗", name)
    if !ok { failures += 1 }
}
func section(_ name: String) { print("\n\(name)") }

@discardableResult
func sh(_ cmd: String, in dir: URL) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", cmd]
    p.currentDirectoryURL = dir
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try! p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

let work = URL(fileURLWithPath: CommandLine.arguments[1])

@MainActor func run() async {
    section("버전 비교")
    check(Updater.isNewer("0.1.10", than: "0.1.9"), "0.1.10 > 0.1.9")
    check(Updater.isNewer("1.0", than: "0.9.9"), "1.0 > 0.9.9")
    check(!Updater.isNewer("0.1.1", than: "0.1.1"), "같은 버전은 새 버전 아님")
    check(!Updater.isNewer("0.1.0", than: "0.1.1"), "낮은 버전은 새 버전 아님")

    section("업데이트 서명")
    let key = Curve25519.Signing.PrivateKey()
    let dmg = work.appendingPathComponent("Gitty-9.9.9.dmg")
    try! Data((0..<200_000).map { UInt8($0 % 251) }).write(to: dmg)
    let sig = work.appendingPathComponent("Gitty-9.9.9.dmg.sig")
    try! key.signature(for: Data(contentsOf: dmg)).base64EncodedString().write(to: sig, atomically: true, encoding: .utf8)
    let release = Updater.Release(version: "9.9.9", notes: "", dmgURL: dmg, signatureURL: sig, pageURL: dmg)
    do {
        try await Updater.verifySignature(of: dmg, release: release, publicKey: key.publicKey)
        check(true, "올바른 서명 통과")
    } catch { check(false, "올바른 서명 통과: \(error)") }
    var bytes = try! Data(contentsOf: dmg)
    bytes[bytes.count / 2] ^= 0xFF
    let tampered = work.appendingPathComponent("tampered.dmg")
    try! bytes.write(to: tampered)
    do {
        try await Updater.verifySignature(of: tampered, release: release, publicKey: key.publicKey)
        check(false, "변조된 파일 거부")
    } catch { check(true, "변조된 파일 거부") }
    do {
        try await Updater.verifySignature(of: dmg, release: release, publicKey: Curve25519.Signing.PrivateKey().publicKey)
        check(false, "다른 키로 만든 서명 거부")
    } catch { check(true, "다른 키로 만든 서명 거부") }
    check(Updater.bundledPublicKey != nil, "앱에 공개 키가 들어 있음")

    section("로그 가리기")
    check(Log.redact("https://user:ghp_abcdefghijklmnopqrstuvwxyz0123@github.com/a/b.git") == "https://***@github.com/a/b.git",
          "원격 주소의 인증 정보")
    check(Log.redact("token github_pat_11ABCDEFG0123456789_abcdefghij done") == "token *** done", "GitHub 토큰")
    check(Log.redact("https://github.com/a/b.git") == "https://github.com/a/b.git", "평범한 주소는 그대로")

    section("이름 검사")
    check(FileOps.validateName("  a.txt ") == "a.txt", "앞뒤 공백 제거")
    check(FileOps.validateName("a/b") == nil && FileOps.validateName("..") == nil && FileOps.validateName("") == nil, "/, .., 빈 이름 거부")
    check(Places.cloudName("GoogleDrive-me@gmail.com") == "Google Drive (me@gmail.com)", "Google Drive 이름")

    section("Git 작업 (로컬 원격으로)")
    let remote = work.appendingPathComponent("remote.git")
    let clone = work.appendingPathComponent("clone")
    sh("git init -q --bare -b main remote.git && git clone -q remote.git clone && cd clone && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init && git push -q -u origin main", in: work)
    let repo = GitRepo(root: clone)
    await repo.prepareIdentity()
    await repo.prepareExcludes()
    await repo.prepareExcludes()
    let exclude = (try? String(contentsOf: clone.appendingPathComponent(".git/info/exclude"), encoding: .utf8)) ?? ""
    check(exclude.components(separatedBy: "\n").filter { $0 == ".DS_Store" }.count == 1, "제외 목록에 .DS_Store 한 번만")
    try! "memo".write(to: clone.appendingPathComponent("memo.txt"), atomically: true, encoding: .utf8)
    try! Data([1]).write(to: clone.appendingPathComponent(".DS_Store"))
    let src = work.appendingPathComponent("src")
    try! FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    let upload = src.appendingPathComponent("a*b [1].txt")
    try! "v1".write(to: upload, atomically: true, encoding: .utf8)
    func last() -> String { sh("git show --name-status --format= HEAD", in: clone).replacingOccurrences(of: "\t", with: " ") }
    do {
        try await repo.createFolder("docs")
        try await repo.upload([upload], to: "docs")
        check(last() == "A docs/a*b [1].txt", "업로드: 올린 파일만 커밋 (\(last()))")
        let uploaded = await repo.takeLastCommit()
        check(uploaded?.message.hasPrefix("Upload") == true, "만든 커밋을 기억함")
        try "v2".write(to: clone.appendingPathComponent("docs/a*b [1].txt"), atomically: true, encoding: .utf8)
        try await repo.upload([{ try! "v2".write(to: upload, atomically: true, encoding: .utf8); return upload }()], to: "docs")
        try await repo.rename("docs/a*b [1].txt", to: "note.txt")
        check(last().hasPrefix("R") && last().contains("docs/note.txt"), "이름 변경 (\(last()))")

        let history = try await repo.history(of: "docs/note.txt")
        check(history.count == 3, "변경 기록 \(history.count)개 (이름 바뀌기 전 것까지)")
        check(history.last?.path == "docs/a*b [1].txt", "옛 이름을 기억함")
        let old = work.appendingPathComponent("old.txt")
        if let first = history.last {
            try await repo.export(first, to: old)
            check((try? String(contentsOf: old, encoding: .utf8)) == "v1", "지난 버전 꺼내기")
            try await repo.restore("docs/note.txt", to: first)
            check((try? String(contentsOf: clone.appendingPathComponent("docs/note.txt"), encoding: .utf8)) == "v1", "지난 버전으로 되돌리기")
            check(last() == "M docs/note.txt", "되돌리기도 그 파일만 커밋")
        }

        try await repo.createFolder("other")
        try await repo.move(["docs/note.txt"], toDir: "other")
        check(last().contains("other/note.txt"), "이동")
        try await repo.delete(["other/note.txt"])
        check(last() == "D other/note.txt", "삭제 (\(last()))")
        if let deleted = await repo.takeLastCommit() {
            try await repo.revert(deleted)
            check(FileManager.default.fileExists(atPath: clone.appendingPathComponent("other/note.txt").path), "삭제 되돌리기")
        } else { check(false, "삭제 커밋을 기억함") }

        let status = sh("git status --porcelain --ignored", in: clone)
        check(status.contains("?? memo.txt"), "클론 폴더의 다른 파일은 커밋 안 됨")
        check(status.contains("!! .DS_Store"), ".DS_Store는 무시")
        check(sh("git rev-list --count origin/main", in: clone) == "1", "commit만으로는 push하지 않음")
        try await repo.push()
        check(sh("git --git-dir=\(remote.path) rev-parse main", in: work) == sh("git rev-parse HEAD", in: clone), "push 한 번에 모두 올라감")
    } catch { check(false, "Git 작업 실패: \(error)") }

    section("검색")
    let found = await FileItem.search("txt", in: clone, includeHidden: true, alwaysHidden: AppModel.repoHidden)
    check(Set(found.items.map(\.name)) == ["memo.txt", "note.txt"] && !found.partial, "작은 폴더 검색 (\(found.items.map(\.name).sorted()))")
    let start = Date()
    let task = Task { await FileItem.search("e", in: URL(fileURLWithPath: "/"), includeHidden: true, alwaysHidden: []) }
    try? await Task.sleep(for: .milliseconds(100))
    task.cancel()
    let cancelled = await task.value
    check(Date().timeIntervalSince(start) < 1 && cancelled.partial, "검색어가 바뀌면 바로 멈춤")

    section("목록 읽기")
    let browser = LocalBrowser()
    browser.dir = clone
    check(browser.loading, "화면을 막지 않고 바로 돌아옴")
    for _ in 0..<100 where browser.loading { try? await Task.sleep(for: .milliseconds(20)) }
    check(Set(browser.items.map(\.name)) == ["docs", "memo.txt", "other"], "목록 (\(browser.items.map(\.name).sorted()))")
    let tree = FolderChildren()
    _ = tree.children(of: clone, includeHidden: false, alwaysHidden: [])
    try? await Task.sleep(for: .milliseconds(300))
    check(tree.children(of: clone, includeHidden: false, alwaysHidden: [])?.map(\.lastPathComponent).sorted() == ["docs", "other"], "트리 하위 폴더")

    print(failures == 0 ? "\n모두 통과" : "\n\(failures)개 실패")
    exit(failures == 0 ? 0 : 1)
}

await run()
