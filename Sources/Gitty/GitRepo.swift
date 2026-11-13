import Foundation

/// 로컬 클론 하나에 대한 git 작업. actor라서 작업이 한 번에 하나씩 순서대로 실행된다.
actor GitRepo {
    let root: URL
    private var identity: (name: String, email: String)?
    private var reporter: ProgressReporter?
    private var lfsChecked: Bool?

    /// GitHub 단일 파일 한도 (100 MiB). 이보다 큰 파일은 Git LFS로 올린다.
    static let lfsThreshold: Int64 = 100 * 1024 * 1024
    /// GitHub LFS 파일 하나 한도 (무료 요금제 2 GB)
    static let lfsMaxSize: Int64 = 2 * 1024 * 1024 * 1024

    init(root: URL) {
        self.root = root
    }

    // MARK: - git 실행

    private static func baseArgs(identity: (name: String, email: String)?) -> [String] {
        var args = ["-c", "core.quotepath=false"]
        if let gh = Shell.ghPath {
            // gh 로그인 정보로 https 인증 (private 레포 push/pull)
            args += ["-c", "credential.helper=!\(gh) auth git-credential"]
        }
        if let identity {
            args += ["-c", "user.name=\(identity.name)", "-c", "user.email=\(identity.email)"]
        }
        return args
    }

    /// 진행률을 받을 곳. 작업마다 AppModel이 바꿔 끼운다.
    func setReporter(_ reporter: ProgressReporter?) {
        self.reporter = reporter
    }

    /// probe: 0이 아닌 종료 코드도 정상적인 "아니오" 답인 명령 (오류로 기록하지 않음)
    /// streaming: git의 진행 출력(push·pull·LFS)을 진행률로 넘긴다
    private func result(_ args: [String], probe: Bool = false, streaming: Bool = false) async -> CommandResult {
        let start = Date()
        let onLine: (@Sendable (String) -> Void)? = streaming ? reporter.map { r in { @Sendable line in r.gitLine(line) } } : nil
        let raw = await Shell.run(Shell.gitPath, Self.baseArgs(identity: identity) + args, cwd: root, onStderrLine: onLine)
        // 오류 메시지에서 진행률 줄은 뺀다
        let r = streaming
            ? CommandResult(status: raw.status, stdout: raw.stdout,
                            stderr: raw.stderr.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                                .filter { !$0.isEmpty && ProgressReporter.parseGit($0) == nil }
                                .joined(separator: "\n"))
            : raw
        let took = String(format: "%.2fs", Date().timeIntervalSince(start))
        let command = "git " + args.joined(separator: " ")
        if r.status == 0 {
            Log.info("git", "\(command) → 성공 (\(took))")
        } else if probe {
            Log.info("git", "\(command) → \(r.status) (\(took))")
        } else {
            Log.error("git", "\(command) → 실패 \(r.status) (\(took))\n\(r.errorText)")
        }
        return r
    }

    @discardableResult
    private func git(_ args: [String], streaming: Bool = false) async throws -> String {
        let r = await result(args, streaming: streaming)
        guard r.status == 0 else { throw GittyError(message: r.errorText) }
        return r.stdout
    }

    // MARK: - 저장소 열기 / 클론

    static func clone(_ spec: String, into parent: URL, reporter: ProgressReporter? = nil) async throws -> URL {
        let spec = spec.trimmed
        guard !spec.isEmpty else { throw GittyError(message: "저장소를 입력하세요.") }

        let remote: String
        if spec.contains("://") || spec.hasPrefix("git@") {
            remote = spec
        } else {
            remote = "https://github.com/\(spec).git"
        }

        // owner/repo 형태로 로컬 폴더 이름 결정
        var cleaned = remote
        if cleaned.hasSuffix(".git") { cleaned.removeLast(4) }
        let parts = Array(cleaned.replacingOccurrences(of: ":", with: "/")
            .split(separator: "/").map(String.init).suffix(2))
        guard parts.count == 2 else { throw GittyError(message: "저장소 형식이 올바르지 않습니다: \(spec)") }
        let dest = parent.appendingPathComponent(parts[0]).appendingPathComponent(parts[1])

        if FileManager.default.fileExists(atPath: dest.appendingPathComponent(".git").path) {
            return dest
        }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        Log.info("clone", "\(remote) → \(dest.path)")
        reporter?.begin("클론 준비 중")
        let r = await Shell.run(Shell.gitPath, baseArgs(identity: nil) + ["clone", "--progress", remote, dest.path],
                                onStderrLine: reporter.map { rep in { @Sendable line in rep.gitLine(line) } })
        guard r.status == 0 else {
            Log.error("clone", "실패 \(r.status)\n\(r.errorText)")
            try? FileManager.default.removeItem(at: dest)
            throw GittyError(message: r.errorText)
        }
        return dest
    }

    func displayName() async -> String {
        let r = await result(["remote", "get-url", "origin"])
        guard r.status == 0 else { return root.lastPathComponent }
        var url = r.stdout.trimmed
        if url.hasSuffix(".git") { url.removeLast(4) }
        let parts = url.replacingOccurrences(of: ":", with: "/").split(separator: "/").suffix(2)
        return parts.joined(separator: "/")
    }

    /// 커밋 작성자 정보가 설정되어 있지 않으면 GitHub 계정(gh)에서 가져온다.
    func prepareIdentity() async {
        let name = await result(["config", "user.name"], probe: true).stdout.trimmed
        let email = await result(["config", "user.email"], probe: true).stdout.trimmed
        if !name.isEmpty && !email.isEmpty { identity = nil; return }

        if let gh = Shell.ghPath {
            let r = await Shell.run(gh, ["api", "user", "--jq", ".login, .id"])
            let lines = r.stdout.split(separator: "\n").map(String.init)
            if r.status == 0, lines.count == 2 {
                identity = (lines[0], "\(lines[1])+\(lines[0])@users.noreply.github.com")
                return
            }
        }
        identity = ("Gitty", "gitty@localhost")
    }

    // MARK: - Git LFS

    func lfsAvailable() async -> Bool {
        if let lfsChecked { return lfsChecked }
        let ok = await result(["lfs", "version"], probe: true).status == 0
        lfsChecked = ok
        return ok
    }

    /// LFS를 쓰는 저장소면 이 클론에 LFS를 켜고 실제 파일을 받는다 (안 그러면 작은 포인터 파일만 보임)
    func prepareLFS() async {
        let attributes = (try? String(contentsOf: root.appendingPathComponent(".gitattributes"), encoding: .utf8)) ?? ""
        guard attributes.contains("filter=lfs") else { return }
        guard await lfsAvailable() else {
            Log.error("lfs", "이 저장소는 Git LFS를 쓰지만 git-lfs가 설치되어 있지 않아요. 큰 파일은 포인터 파일로만 보여요.\n터미널에서 brew install git-lfs 후 다시 열어 주세요.")
            return
        }
        reporter?.begin("LFS 파일 받는 중")
        _ = await result(["lfs", "install", "--local"])
        _ = await result(["lfs", "pull"], streaming: true)
    }

    // MARK: - 동기화

    private func currentBranch() async throws -> String {
        try await git(["symbolic-ref", "--short", "HEAD"]).trimmed
    }

    func pull() async throws {
        let branch = try await currentBranch()
        let check = await result(["ls-remote", "--exit-code", "--heads", "origin", branch], probe: true)
        if check.status == 2 { return }            // 원격에 아직 브랜치 없음 (빈 저장소)
        guard check.status == 0 else { throw GittyError(message: check.errorText) }

        reporter?.begin("원격에서 받는 중")
        let r = await result(["pull", "--progress", "--rebase", "--autostash", "origin", branch], streaming: true)
        if r.status != 0 {
            _ = await result(["rebase", "--abort"])
            throw GittyError(message: "원격 변경사항과 충돌했습니다.\n\(r.errorText)")
        }
    }

    func push() async throws {
        let branch = try await currentBranch()
        reporter?.begin("push 준비 중")
        if await result(["push", "--progress", "-u", "origin", branch], streaming: true).status == 0 { return }
        // 원격이 앞서 있으면 받아서 다시 시도
        try await pull()
        reporter?.begin("push 다시 시도 중")
        try await git(["push", "--progress", "-u", "origin", branch], streaming: true)
    }

    func headHash() async -> String? {
        let r = await result(["rev-parse", "HEAD"], probe: true)
        return r.status == 0 ? r.stdout.trimmed : nil
    }

    func commitCount(from old: String, to new: String) async -> Int {
        Int(await result(["rev-list", "--count", "\(old)..\(new)"], probe: true).stdout.trimmed) ?? 0
    }

    func unpushedCount() async -> Int {
        let r = await result(["rev-list", "--count", "@{u}..HEAD"], probe: true)
        if r.status == 0 { return Int(r.stdout.trimmed) ?? 0 }
        // upstream이 아직 없으면 로컬 커밋 전체가 미전송
        let all = await result(["rev-list", "--count", "HEAD"])
        return all.status == 0 ? Int(all.stdout.trimmed) ?? 0 : 0
    }

    /// 작업 트리의 모든 변경을 커밋하고 push. 변경이 없으면 아무것도 하지 않는다.
    private func commitAndPush(_ message: String) async throws {
        reporter?.begin("커밋 준비 중")
        try await git(["add", "-A"])
        if await result(["diff", "--cached", "--quiet"], probe: true).status == 0 {
            Log.info("commit", "바뀐 내용이 없어 커밋하지 않음: \(message)")
            return
        }
        try await git(["commit", "-q", "-m", message])
        let hash = (try? await git(["rev-parse", "--short", "HEAD"]))?.trimmed ?? "?"
        Log.info("commit", "\(hash) \(message)")
        try await push()
        Log.info("push", "\(hash) push 완료")
    }

    // MARK: - 파일 작업

    func upload(_ sources: [URL], to dir: String) async throws {
        let fm = FileManager.default
        let destDir = url(for: dir)
        Log.info("upload", "시작 → /\(dir)\n" + sources.map { "\($0.path) (\(Log.sizeDescription(of: $0)))" }.joined(separator: "\n"))

        // 100MB 넘는 파일은 Git LFS로
        let large = sources.flatMap { largeFiles(in: $0, destDir: dir) }
        if !large.isEmpty {
            let names = large.map { "\($0.path) (\(ProgressReporter.bytes($0.size)))" }
            if let huge = large.first(where: { $0.size > Self.lfsMaxSize }) {
                Log.error("upload", "2GB 초과로 중단: \(huge.path)")
                throw GittyError(message: "GitHub LFS는 파일 하나에 2GB까지만 받아요:\n\(huge.path) (\(ProgressReporter.bytes(huge.size)))")
            }
            guard await lfsAvailable() else {
                Log.error("upload", "100MB 초과 파일이 있지만 git-lfs가 없어 중단: \(names.joined(separator: ", "))")
                throw GittyError(message: """
                    100MB가 넘는 파일은 Git LFS로 올려야 해요. 이 Mac에 git-lfs가 없어요.
                    터미널에서 brew install git-lfs 를 실행한 뒤 다시 시도해 주세요.

                    \(names.joined(separator: "\n"))
                    """)
            }
            try await git(["lfs", "install", "--local"])
            Log.info("lfs", "LFS로 올릴 파일:\n" + names.joined(separator: "\n"))
        }

        let total = FileOps.totalSize(sources)
        reporter?.begin("복사 중", totalBytes: total)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        for src in sources {
            try copyFiltered(src, to: destDir.appendingPathComponent(src.lastPathComponent))
        }
        for file in large {
            try await git(["lfs", "track", "--filename", file.path])
        }
        let names = sources.map(\.lastPathComponent)
        try await commitAndPush("Upload \(summary(names, in: dir))")
    }

    func delete(_ paths: [String]) async throws {
        for path in paths {
            try FileManager.default.removeItem(at: url(for: path))
        }
        try await commitAndPush("Delete \(summary(paths, in: ""))")
    }

    func rename(_ path: String, to newName: String) async throws {
        let newPath = (path as NSString).deletingLastPathComponent.isEmpty
            ? newName
            : (path as NSString).deletingLastPathComponent + "/" + newName

        let tracked = await result(["ls-files", "--error-unmatch", "--", path], probe: true).status == 0
        if tracked {
            // git mv는 대소문자만 바뀌는 이름 변경도 처리한다
            try await git(["mv", "--", path, newPath])
        } else {
            try FileManager.default.moveItem(at: url(for: path), to: url(for: newPath))
        }
        try await commitAndPush("Rename \(path) → \(newPath)")
    }

    /// 저장소 안에서 항목들을 다른 폴더로 옮긴다 (git mv)
    func move(_ paths: [String], toDir dir: String) async throws {
        let fm = FileManager.default
        var moved: [String] = []
        for path in paths {
            let name = (path as NSString).lastPathComponent
            let newPath = dir.isEmpty ? name : "\(dir)/\(name)"
            if newPath == path { continue }
            if dir == path || dir.hasPrefix(path + "/") {
                throw GittyError(message: "폴더를 자기 자신 안으로 옮길 수 없습니다: \(name)")
            }
            if fm.fileExists(atPath: url(for: newPath).path) {
                throw GittyError(message: "옮길 폴더에 같은 이름이 이미 있습니다: \(newPath)")
            }
            try fm.createDirectory(at: url(for: dir), withIntermediateDirectories: true)
            let tracked = await result(["ls-files", "--error-unmatch", "--", path], probe: true).status == 0
            if tracked {
                try await git(["mv", "--", path, newPath])
            } else {
                try fm.moveItem(at: url(for: path), to: url(for: newPath))
            }
            moved.append(name)
        }
        guard !moved.isEmpty else { return }
        Log.info("move", "/\(dir)(으)로 옮김: \(moved.joined(separator: ", "))")
        try await commitAndPush("Move \(summary(moved, in: "")) → /\(dir)")
    }

    func createFolder(_ path: String) async throws {
        let dir = url(for: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // git은 빈 폴더를 추적하지 않으므로 .gitkeep을 넣는다
        FileManager.default.createFile(atPath: dir.appendingPathComponent(".gitkeep").path, contents: Data())
        try await commitAndPush("Create folder \(path)")
    }

    // MARK: - 헬퍼

    private func url(for relative: String) -> URL {
        relative.isEmpty ? root : root.appendingPathComponent(relative)
    }

    private func summary(_ names: [String], in dir: String) -> String {
        let shown = names.prefix(3).map { dir.isEmpty ? $0 : "\(dir)/\($0)" }.joined(separator: ", ")
        return names.count > 3 ? "\(shown) 외 \(names.count - 3)개" : shown
    }

    private func copyFiltered(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { return }

        if isDir.boolValue {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            for child in try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) {
                let name = child.lastPathComponent
                if name == ".git" || name == ".DS_Store" { continue }
                try copyFiltered(child, to: dst.appendingPathComponent(name))
            }
            // 내용이 없는 폴더는 git이 추적하지 않으므로 남기지 않는다
            if (try? fm.contentsOfDirectory(atPath: dst.path))?.isEmpty == true {
                try? fm.removeItem(at: dst)
            }
        } else {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            let reporter = self.reporter
            try FileOps.copyFile(src, to: dst, progress: reporter.map { r in { r.advance($0) } })
        }
    }

    /// 업로드할 것 중 LFS로 보내야 하는 파일 (저장소 기준 경로, 크기)
    private func largeFiles(in source: URL, destDir: String) -> [(path: String, size: Int64)] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
        func size(_ u: URL) -> Int64 { Int64((try? u.resourceValues(forKeys: keys))?.fileSize ?? 0) }
        let base = destDir.isEmpty ? source.lastPathComponent : "\(destDir)/\(source.lastPathComponent)"

        if (try? source.resourceValues(forKeys: keys))?.isDirectory != true {
            let s = size(source)
            return s > Self.lfsThreshold ? [(base, s)] : []
        }
        var found: [(String, Int64)] = []
        let sourcePath = source.standardizedFileURL.path
        let e = FileManager.default.enumerator(at: source, includingPropertiesForKeys: Array(keys))
        while let u = e?.nextObject() as? URL {
            if u.lastPathComponent == ".git" { e?.skipDescendants(); continue }
            let s = size(u)
            if s > Self.lfsThreshold {
                let relative = String(u.standardizedFileURL.path.dropFirst(sourcePath.count + 1))
                found.append(("\(base)/\(relative)", s))
            }
        }
        return found
    }
}
