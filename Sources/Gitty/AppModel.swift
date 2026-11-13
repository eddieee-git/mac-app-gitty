import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var root: URL?
    private(set) var repo: GitRepo?
    private(set) var repoName = ""
    var path: [String] = [] { didSet { reload() } }
    private(set) var items: [FileItem] = []
    /// 다시 읽을 때마다 올라간다. 폴더 트리가 이 값을 보고 새로 그린다.
    private(set) var revision = 0
    nonisolated static let repoHidden: Set<String> = [".git", ".DS_Store", ".gitkeep"]
    private(set) var busyMessage: String?
    /// 지금 작업의 진행률 (복사 %, push % 등)
    private(set) var progress: TransferProgress?
    private var progressToken: UUID?
    private(set) var statusMessage = ""
    var errorMessage: String?
    private(set) var unpushed = 0
    /// 마지막으로 원격과 맞춘 시각
    private(set) var lastSynced: Date?
    private(set) var recents: [URL] = []
    /// 왼쪽 "내 폴더" 패널
    let local = LocalBrowser()
    /// 왼쪽 사이드바의 즐겨찾기와 위치
    let places = Places()
    /// 오른쪽 Git 패널의 즐겨찾기 (저장소마다 따로)
    let repoFavorites = RepoFavorites()

    var isBusy: Bool { busyMessage != nil }

    static let reposDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Gitty/Repos", isDirectory: true)

    private let recentsKey = "recentRepos"

    init() {
        recents = (UserDefaults.standard.stringArray(forKey: recentsKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".git").path) }
    }

    var currentDir: URL? {
        path.reduce(root) { $0?.appendingPathComponent($1, isDirectory: true) }
    }

    var relativeDir: String { path.joined(separator: "/") }

    func relativePath(of item: FileItem) -> String {
        relativeDir.isEmpty ? item.name : "\(relativeDir)/\(item.name)"
    }

    // MARK: - 저장소

    func open(_ url: URL) async {
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else {
            errorMessage = "Git 저장소 폴더가 아닙니다: \(url.path)"
            return
        }
        let repo = GitRepo(root: url)
        Log.info("repo", "열기: \(url.path)")
        self.repo = repo
        root = url
        repoFavorites.load(root: url)
        repoName = await repo.displayName()
        path = []
        addRecent(url)
        let ok = await perform("원격과 동기화 중…", done: "최신 상태입니다") {
            await repo.prepareIdentity()
            try await repo.pull()
            await repo.prepareLFS()
        }
        if ok { lastSynced = Date() }
    }

    func clone(_ spec: String) async {
        busyMessage = "클론하는 중…"
        let reporter = startProgress()
        defer { busyMessage = nil; endProgress() }
        do {
            let url = try await GitRepo.clone(spec, into: Self.reposDirectory, reporter: reporter)
            busyMessage = nil
            endProgress()
            await open(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func close() {
        repo = nil
        root = nil
        repoFavorites.load(root: nil)
        items = []
        statusMessage = ""
        unpushed = 0
        lastSynced = nil
    }

    func removeRecent(_ url: URL) {
        recents.removeAll { $0 == url }
        UserDefaults.standard.set(recents.map(\.path), forKey: recentsKey)
    }

    private func addRecent(_ url: URL) {
        recents.removeAll { $0 == url }
        recents.insert(url, at: 0)
        recents = Array(recents.prefix(10))
        UserDefaults.standard.set(recents.map(\.path), forKey: recentsKey)
    }

    // MARK: - 목록

    func reload() {
        guard let root else { items = []; return }
        // 동기화로 현재 폴더가 사라졌으면 존재하는 상위 폴더로 이동
        while !path.isEmpty, let dir = currentDir, !FileManager.default.fileExists(atPath: dir.path) {
            path.removeLast()
        }
        let dir = currentDir ?? root
        items = FileItem.list(in: dir, includeHidden: true, alwaysHidden: Self.repoHidden)
        revision += 1
    }

    // MARK: - 작업

    func refresh() async {
        guard let repo else { return }
        let ok = await perform("원격과 동기화 중…", done: "최신 상태입니다") {
            try await repo.pull()
            try await repo.push()   // 이전에 실패한 push가 있으면 함께 전송
            await repo.prepareLFS()
        }
        if ok { lastSynced = Date() }
    }

    /// 몇 분마다 조용히 원격을 확인한다. 받은 변경이 있을 때만 기록·표시한다.
    func autoSync() async {
        guard let repo, !isBusy else { return }
        let before = await repo.headHash()
        let pending = unpushed
        let ok = await perform("자동 동기화 중…", done: "", quiet: true) {
            try await repo.pull()
            if pending > 0 { try await repo.push() }
            await repo.prepareLFS()
        }
        guard ok else { return }
        lastSynced = Date()
        let after = await repo.headHash()
        if let before, let after, before != after {
            let count = await repo.commitCount(from: before, to: after)
            let time = Date().formatted(date: .omitted, time: .shortened)
            statusMessage = "원격 변경 \(count)개를 받았어요 (\(time))"
            Log.info("자동 동기화", "원격 변경 \(count)개를 받았어요 [\(repoName)]")
        }
    }

    /// removeLocalAfter: 업로드(커밋·push) 성공 후 원본을 휴지통으로 보내 "이동"이 되게 한다.
    /// dir: 저장소 안의 올릴 폴더 (nil이면 지금 보고 있는 폴더)
    func upload(_ urls: [URL], removeLocalAfter: Bool = false, to targetDir: String? = nil) async {
        guard let repo, !urls.isEmpty else { return }
        let dir = targetDir ?? relativeDir
        let verb = removeLocalAfter ? "이동" : "업로드"
        let ok = await perform("\(urls.count)개 항목 \(verb) 중…", done: "\(urls.count)개 항목을 Git 저장소로 \(verb)했습니다") {
            try await repo.upload(urls, to: dir)
        }
        if ok && removeLocalAfter {
            do {
                try FileOps.trash(urls)
                Log.info("upload", "이동이라 원본을 휴지통으로 보냄: \(urls.map(\.lastPathComponent).joined(separator: ", "))")
            } catch {
                Log.error("upload", "원본을 휴지통으로 보내지 못함: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
        local.reload()
    }

    /// 저장소 안에서 다른 폴더로 옮기기 (git mv)
    func moveInRepo(_ urls: [URL], to folder: URL) async {
        guard let repo, let dir = folder == root ? "" : repoRelativePath(folder) else { return }
        let paths = urls.compactMap(repoRelativePath)
        guard !paths.isEmpty else { return }
        await perform("옮기는 중…", done: "\(paths.count)개 항목을 /\(dir)(으)로 옮겼습니다") {
            try await repo.move(paths, toDir: dir)
        }
    }

    /// 내 폴더 안에서 다른 폴더로 옮기기
    func moveLocal(_ urls: [URL], into folder: URL) {
        do {
            try FileOps.move(urls, into: folder)
            Log.info("move", "내 폴더 안에서 \(folder.path)(으)로 옮김: \(urls.map(\.lastPathComponent).joined(separator: ", "))")
            statusMessage = "\(urls.count)개 항목을 \(folder.lastPathComponent)(으)로 옮겼습니다"
        } catch {
            Log.error("move", error.localizedDescription)
            errorMessage = error.localizedDescription
        }
        local.reload()
    }

    func delete(_ items: [FileItem]) async {
        guard let repo, !items.isEmpty else { return }
        let paths = items.compactMap { repoRelativePath($0.url) }
        await perform("삭제하는 중…", done: "\(items.count)개 항목을 삭제했습니다") {
            try await repo.delete(paths)
        }
    }

    func rename(_ item: FileItem, to newName: String) async {
        guard let repo else { return }
        let newName = newName.trimmed
        guard !newName.isEmpty, newName != item.name else { return }
        guard !newName.contains("/"), newName != ".", newName != ".." else {
            errorMessage = "이름에 / 를 사용할 수 없습니다."
            return
        }
        let siblings = existingNames(in: item.url.deletingLastPathComponent())
        if siblings.contains(where: { $0.lowercased() == newName.lowercased() && $0.lowercased() != item.name.lowercased() }) {
            errorMessage = "같은 이름의 항목이 이미 있습니다: \(newName)"
            return
        }
        guard let path = repoRelativePath(item.url) else { return }
        await perform("이름 변경 중…", done: "이름을 \(newName)(으)로 변경했습니다") {
            try await repo.rename(path, to: newName)
        }
    }

    func createFolder(_ name: String) async {
        guard let repo else { return }
        let name = name.trimmed
        guard !name.isEmpty, !name.contains("/") else { return }
        if items.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            errorMessage = "같은 이름의 항목이 이미 있습니다: \(name)"
            return
        }
        let path = relativeDir.isEmpty ? name : "\(relativeDir)/\(name)"
        await perform("폴더 만드는 중…", done: "\(name) 폴더를 만들었습니다") {
            try await repo.createFolder(path)
        }
    }

    // MARK: - 내 폴더 ↔ Git 저장소

    /// 저장소 안의 파일 URL → 저장소 기준 상대 경로 (저장소 밖이면 nil)
    func repoRelativePath(_ url: URL) -> String? {
        guard let root else { return nil }
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : nil
    }

    /// 항목들을 왼쪽 "내 폴더"로 복사. removeFromRepo면 저장소에서 삭제(커밋·push)까지 해서 이동이 된다.
    func copyToLocal(_ urls: [URL], removeFromRepo: Bool, into folder: URL? = nil) async {
        guard !urls.isEmpty, !isBusy else { return }
        Log.info("download", "내 폴더(\((folder ?? local.dir).path))로 \(removeFromRepo ? "이동" : "복사")\n" + urls.map(\.path).joined(separator: "\n"))
        let dest = folder ?? local.dir
        // Google Drive처럼 온라인 전용 파일은 받는 데 오래 걸릴 수 있어 화면이 멈추지 않게 백그라운드에서 복사
        busyMessage = "내 폴더로 복사 중…"
        let reporter = startProgress()
        reporter.begin("내 폴더로 복사 중", totalBytes: FileOps.totalSize(urls))
        defer { endProgress() }
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileOps.copy(urls, into: dest, progress: { reporter.advance($0) })
            }.value
        } catch {
            busyMessage = nil
            Log.error("download", error.localizedDescription)
            errorMessage = error.localizedDescription
            local.reload()
            return
        }
        busyMessage = nil
        endProgress()
        local.reload()
        Log.info("download", "복사 완료: \(urls.map(\.lastPathComponent).joined(separator: ", "))")

        let repoPaths = urls.compactMap(repoRelativePath)
        if removeFromRepo, let repo, !repoPaths.isEmpty {
            await perform("내 폴더로 이동 중…", done: "\(urls.count)개 항목을 내 폴더로 이동했습니다") {
                try await repo.delete(repoPaths)
            }
        } else {
            statusMessage = "\(urls.count)개 항목을 내 폴더에 복사했습니다"
        }
    }

    // MARK: - 진행률

    /// 새 진행률 수신기를 만든다. 이전 작업에서 늦게 도착한 값은 무시한다.
    private func startProgress() -> ProgressReporter {
        let token = UUID()
        progressToken = token
        progress = nil
        return ProgressReporter { [weak self] value in
            Task { @MainActor in
                guard let self, self.progressToken == token else { return }
                self.progress = value
            }
        }
    }

    private func endProgress() {
        progressToken = nil
        progress = nil
    }

    /// quiet: 자동 동기화처럼 조용히 — 시작·완료를 기록하지 않고, 실패해도 창을 띄우지 않는다
    @discardableResult
    private func perform(_ label: String, done: String, quiet: Bool = false,
                         _ op: @escaping () async throws -> Void) async -> Bool {
        guard !isBusy else {
            if !quiet { Log.error("작업", "다른 작업 중이라 건너뜀: \(label)") }
            return false
        }
        busyMessage = label
        if !quiet { errorMessage = nil }
        let reporter = startProgress()
        await repo?.setReporter(reporter)
        var ok = false
        if !quiet { Log.info("작업", "\(label) [\(repoName)]") }
        do {
            try await op()
            if !quiet {
                statusMessage = done
                Log.info("작업", "완료: \(done)")
            }
            ok = true
        } catch {
            if quiet {
                Log.error("자동 동기화", error.localizedDescription)
                statusMessage = "자동 동기화 실패 (작업 기록 참고)"
            } else {
                statusMessage = "작업 실패"
                errorMessage = error.localizedDescription
                Log.error("작업", "실패: \(label)\n\(error.localizedDescription)")
            }
        }
        await repo?.setReporter(nil)
        endProgress()
        reload()
        unpushed = await repo?.unpushedCount() ?? 0
        busyMessage = nil
        return ok
    }
}
