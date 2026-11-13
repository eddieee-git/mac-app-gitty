import Foundation

/// 로컬 클론 하나에 대한 git 작업. actor라서 작업이 한 번에 하나씩 순서대로 실행된다.
actor GitRepo {
    let root: URL
    private var identity: (name: String, email: String)?

    /// GitHub 단일 파일 업로드 한도 (100 MiB)
    static let maxFileSize: Int64 = 100 * 1024 * 1024

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

    private func result(_ args: [String]) async -> CommandResult {
        await Shell.run(Shell.gitPath, Self.baseArgs(identity: identity) + args, cwd: root)
    }

    @discardableResult
    private func git(_ args: [String]) async throws -> String {
        let r = await result(args)
        guard r.status == 0 else { throw GittyError(message: r.errorText) }
        return r.stdout
    }

    // MARK: - 저장소 열기 / 클론

    static func clone(_ spec: String, into parent: URL) async throws -> URL {
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

        let r = await Shell.run(Shell.gitPath, baseArgs(identity: nil) + ["clone", remote, dest.path])
        guard r.status == 0 else {
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
        let name = await result(["config", "user.name"]).stdout.trimmed
        let email = await result(["config", "user.email"]).stdout.trimmed
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

    // MARK: - 동기화

    private func currentBranch() async throws -> String {
        try await git(["symbolic-ref", "--short", "HEAD"]).trimmed
    }

    func pull() async throws {
        let branch = try await currentBranch()
        let check = await result(["ls-remote", "--exit-code", "--heads", "origin", branch])
        if check.status == 2 { return }            // 원격에 아직 브랜치 없음 (빈 저장소)
        guard check.status == 0 else { throw GittyError(message: check.errorText) }

        let r = await result(["pull", "--rebase", "--autostash", "origin", branch])
        if r.status != 0 {
            _ = await result(["rebase", "--abort"])
            throw GittyError(message: "원격 변경사항과 충돌했습니다.\n\(r.errorText)")
        }
    }

    func push() async throws {
        let branch = try await currentBranch()
        if await result(["push", "-u", "origin", branch]).status == 0 { return }
        // 원격이 앞서 있으면 받아서 다시 시도
        try await pull()
        try await git(["push", "-u", "origin", branch])
    }

    func unpushedCount() async -> Int {
        let r = await result(["rev-list", "--count", "@{u}..HEAD"])
        if r.status == 0 { return Int(r.stdout.trimmed) ?? 0 }
        // upstream이 아직 없으면 로컬 커밋 전체가 미전송
        let all = await result(["rev-list", "--count", "HEAD"])
        return all.status == 0 ? Int(all.stdout.trimmed) ?? 0 : 0
    }

    /// 작업 트리의 모든 변경을 커밋하고 push. 변경이 없으면 아무것도 하지 않는다.
    private func commitAndPush(_ message: String) async throws {
        try await git(["add", "-A"])
        if await result(["diff", "--cached", "--quiet"]).status == 0 { return }
        try await git(["commit", "-q", "-m", message])
        try await push()
    }

    // MARK: - 파일 작업

    func upload(_ sources: [URL], to dir: String) async throws {
        let fm = FileManager.default
        let destDir = url(for: dir)

        let tooBig = sources.flatMap { oversizedFiles(in: $0) }
        if !tooBig.isEmpty {
            throw GittyError(message: "GitHub는 100MB가 넘는 파일을 받지 않습니다:\n" + tooBig.joined(separator: "\n"))
        }

        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        for src in sources {
            try copyFiltered(src, to: destDir.appendingPathComponent(src.lastPathComponent))
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

        let tracked = await result(["ls-files", "--error-unmatch", "--", path]).status == 0
        if tracked {
            // git mv는 대소문자만 바뀌는 이름 변경도 처리한다
            try await git(["mv", "--", path, newPath])
        } else {
            try FileManager.default.moveItem(at: url(for: path), to: url(for: newPath))
        }
        try await commitAndPush("Rename \(path) → \(newPath)")
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
            try fm.copyItem(at: src, to: dst)
        }
    }

    private func oversizedFiles(in url: URL) -> [String] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
        func size(_ u: URL) -> Int64 { Int64((try? u.resourceValues(forKeys: keys))?.fileSize ?? 0) }

        if (try? url.resourceValues(forKeys: keys))?.isDirectory != true {
            return size(url) > Self.maxFileSize ? [url.lastPathComponent] : []
        }
        var result: [String] = []
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let u = e?.nextObject() as? URL {
            if u.lastPathComponent == ".git" { e?.skipDescendants(); continue }
            if size(u) > Self.maxFileSize { result.append(u.lastPathComponent) }
        }
        return result
    }
}
