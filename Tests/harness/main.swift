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

    section("Google Drive 내 드라이브 찾기")
    let fm = FileManager.default
    let streaming = work.appendingPathComponent("home-stream")
    for d in ["Library/CloudStorage/GoogleDrive-me@gmail.com/My Drive/문서", "Library/CloudStorage/GoogleDrive-me@gmail.com/Shared drives/팀"] {
        try! fm.createDirectory(at: streaming.appendingPathComponent(d), withIntermediateDirectories: true)
    }
    let s1 = Places.googleMyDrives(home: streaming)
    check(s1.map(\.title) == ["내 드라이브 (me@gmail.com)"] && s1.first?.url.lastPathComponent == "My Drive", "스트리밍: 계정 폴더 안의 내 드라이브")
    let mirror = work.appendingPathComponent("home-mirror")
    for d in ["Library/CloudStorage/GoogleDrive-me@gmail.com/Shared drives/팀", "My Drive/문서"] {
        try! fm.createDirectory(at: mirror.appendingPathComponent(d), withIntermediateDirectories: true)
    }
    let s2 = Places.googleMyDrives(home: mirror)
    check(s2.map(\.url.lastPathComponent) == ["My Drive"] && s2.first?.url.path.hasPrefix(mirror.resolvingSymlinksInPath().path) == true, "미러링: 홈의 My Drive")
    // 미러링인데 CloudStorage에도 빈 My Drive가 있는 경우 (실제 사용자 Mac에서 본 모양)
    let both = work.appendingPathComponent("home-both")
    for d in ["Library/CloudStorage/GoogleDrive-me@gmail.com/My Drive", "Library/CloudStorage/GoogleDrive-me@gmail.com/Shared drives/팀", "My Drive/10_Work"] {
        try! fm.createDirectory(at: both.appendingPathComponent(d), withIntermediateDirectories: true)
    }
    let s3 = Places.googleMyDrives(home: both)
    check(s3.count == 1 && s3[0].url.path == both.appendingPathComponent("My Drive").resolvingSymlinksInPath().path, "미러링: 비어 있는 CloudStorage 쪽 대신 실제 폴더")
    check(s3.first?.title == "내 드라이브 (me@gmail.com)", "미러링 폴더에 계정 이름 (\(s3.first?.title ?? ""))")
    try! fm.createDirectory(at: both.appendingPathComponent("Library/CloudStorage/GoogleDrive-me@gmail.com/My Drive/문서"), withIntermediateDirectories: true)
    check(Places.googleMyDrives(home: both).count == 2, "CloudStorage 쪽에도 파일이 있으면 둘 다")
    // 사용자 Mac과 같은 모양: 계정 폴더의 My Drive → ~/My Drive 바로가기, ~/Google Drive → 계정 폴더 바로가기
    let real = work.appendingPathComponent("home-real")
    let account = real.appendingPathComponent("Library/CloudStorage/GoogleDrive-eddie@cf.com")
    try! fm.createDirectory(at: account, withIntermediateDirectories: true)
    try! fm.createDirectory(at: real.appendingPathComponent("My Drive/10_Work"), withIntermediateDirectories: true)
    try! "x".write(to: real.appendingPathComponent("My Drive/메모.txt"), atomically: true, encoding: .utf8)
    try! fm.createSymbolicLink(atPath: account.appendingPathComponent("My Drive").path, withDestinationPath: real.appendingPathComponent("My Drive").path)
    try! fm.createSymbolicLink(atPath: real.appendingPathComponent("Google Drive").path, withDestinationPath: account.path)
    let s4 = Places.googleMyDrives(home: real)
    check(s4.count == 1, "바로가기 두 개와 실제 폴더 → 내 드라이브 하나 (\(s4.map(\.url.path)))")
    check(s4.first?.url.path == real.appendingPathComponent("My Drive").resolvingSymlinksInPath().path, "실제 폴더(~/My Drive)를 가리킴")
    check(s4.first?.title == "내 드라이브 (eddie@cf.com)", "계정 이름 붙음")
    let viaLink = FileItem.list(in: account.appendingPathComponent("My Drive"), includeHidden: false, alwaysHidden: [])
    check(Set(viaLink.map(\.name)) == ["10_Work", "메모.txt"], "바로가기 폴더도 내용이 보임 (\(viaLink.map(\.name)))")
    let elsewhere = work.appendingPathComponent("elsewhere/내 드라이브")
    try! fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    check(Places.googleMyDrives(extra: [elsewhere], home: mirror).count == 2, "Spotlight로 찾은 다른 곳의 내 드라이브")
    let linkHome = work.appendingPathComponent("home-link")
    try! fm.createDirectory(at: linkHome, withIntermediateDirectories: true)
    try! fm.createSymbolicLink(at: linkHome.appendingPathComponent("Google Drive"), withDestinationURL: mirror.appendingPathComponent("My Drive"))
    let listed = FileItem.list(in: linkHome, includeHidden: false, alwaysHidden: [])
    check(listed.first?.isDirectory == true, "폴더를 가리키는 링크는 폴더로")
    check(Places.cloudName("GoogleDrive-me@gmail.com") == "Google Drive (me@gmail.com)", "계정 폴더 이름")

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

    section("충돌")
    check(GitRepo.copyName(for: "docs/a.txt", existing: { _ in false }) == "docs/a (원격).txt", "복사본 이름")
    check(GitRepo.copyName(for: "README", existing: { $0 == "README (원격)" }) == "README (원격 2)", "복사본 이름이 겹치면 번호")
    sh("git init -q --bare -b main c-remote.git && git clone -q c-remote.git c-mine && cd c-mine && printf 'base' > a.txt && printf 'base' > b.txt && printf 'base' > gone.txt && git add -A && git -c user.name=t -c user.email=t@t commit -q -m base && git push -q -u origin main && cd .. && git clone -q c-remote.git c-other && cd c-other && printf 'theirs' > a.txt && printf 'theirs' > b.txt && printf 'theirs' > gone.txt && git -c user.name=o -c user.email=o@o commit -qam other && git push -q", in: work)
    let mineDir = work.appendingPathComponent("c-mine")
    let mine = GitRepo(root: mineDir)
    await mine.prepareIdentity()
    func content(_ name: String) -> String? { try? String(contentsOf: mineDir.appendingPathComponent(name), encoding: .utf8) }
    do {
        try "mine".write(to: mineDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "mine".write(to: mineDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try await mine.delete(["gone.txt"])
        sh("cd c-mine && git -c user.name=t -c user.email=t@t commit -qam mine", in: work)
        do {
            try await mine.pull()
            check(false, "충돌을 알아챔")
        } catch let conflict as MergeConflictError {
            check(conflict.files.map(\.path).sorted() == ["a.txt", "b.txt", "gone.txt"], "충돌한 파일 3개 (\(conflict.files.map(\.path)))")
            check(conflict.files.first { $0.path == "gone.txt" }?.mine == nil, "내 쪽에서 지운 것을 앎")
            let waiting = await mine.mergeInProgress()
            check(waiting, "합치기가 열린 채로 기다림")
            try await mine.resolveConflicts(["a.txt": .mine, "b.txt": .both, "gone.txt": .theirs])
            check(content("a.txt") == "mine", "내 것 남기기")
            check(content("b.txt") == "mine" && content("b (원격).txt") == "theirs", "둘 다 남기기")
            check(content("gone.txt") == "theirs", "원격 것 남기기 (지운 파일 살리기)")
            let stillOpen = await mine.mergeInProgress()
            check(!stillOpen, "합치기 마무리됨")
            try await mine.push()
            check(sh("git --git-dir=c-remote.git log -1 --format=%P main", in: work).split(separator: " ").count == 2, "합친 커밋이 올라감")
        }

        // 나중에: 합치기를 그만두면 내 쪽 그대로
        sh("cd c-other && git pull -q && printf 'again' > a.txt && git -c user.name=o -c user.email=o@o commit -qam again && git push -q", in: work)
        try "mine2".write(to: mineDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        sh("cd c-mine && git -c user.name=t -c user.email=t@t commit -qam mine2", in: work)
        do { try await mine.pull() } catch is MergeConflictError {
            await mine.abortMerge()
            let open = await mine.mergeInProgress()
            check(content("a.txt") == "mine2" && !open, "나중에: 내 쪽 그대로 두고 그만둠")
        }
    } catch { check(false, "충돌 시험 실패: \(error)") }

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
