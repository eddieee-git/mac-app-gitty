import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var root: URL?
    private(set) var repo: GitRepo?
    private(set) var repoName = ""
    var path: [String] = [] { didSet { reload() } }
    private(set) var items: [FileItem] = []
    /// 폴더를 읽는 중
    private(set) var loading = false
    @ObservationIgnored private var loadToken = 0
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

    /// 커밋은 했고 곧 push할 예정 (연달아 한 작업을 모아 한 번에 올린다)
    private(set) var pushPending = false
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    /// 마지막 작업 뒤 이만큼 기다렸다가 push
    static let pushDelay: Duration = .seconds(2)

    /// 되돌릴 수 있는 Git 작업 (이번에 연 저장소에서 Gitty가 한 것, 최근 것이 끝)
    struct UndoEntry: Equatable {
        let commit: CommitRef
        let label: String
    }
    private(set) var undoStack: [UndoEntry] = []
    var undoLabel: String? { undoStack.last?.label }

    /// 앱 종료 때 남은 push를 마저 하기 위해 (AppDelegate에서 씀)
    static weak var current: AppModel?

    static let reposDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Gitty/Repos", isDirectory: true)

    private let recentsKey = "recentRepos"

    init() {
        Self.current = self
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
        undoStack = []
        repoName = await repo.displayName()
        path = []
        addRecent(url)
        let ok = await perform("원격과 동기화 중…", done: "최신 상태입니다") {
            await repo.prepareIdentity()
            await repo.prepareExcludes()
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
        if pushPending, let repo {
            // 저장소 목록으로 돌아가도 커밋해 둔 것은 마저 올린다
            pushPending = false
            pushTask?.cancel()
            Task.detached { try? await repo.push() }
        }
        repo = nil
        root = nil
        undoStack = []
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

    /// 지금 폴더 내용을 뒤에서 읽는다. 화면은 그동안 멈추지 않는다.
    func reload() {
        guard let root else { items = []; return }
        loadToken += 1
        let token = loadToken
        let path = self.path
        let previous = items.first?.url.deletingLastPathComponent().standardizedFileURL.path
        let target = path.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
        let changedDir = previous != nil && previous != target.standardizedFileURL.path
        loading = true
        Task {
            let (kept, list) = await Task.detached(priority: .userInitiated) {
                // 동기화로 지금 폴더가 사라졌으면 남아 있는 상위 폴더로
                var kept = path
                func url(_ parts: [String]) -> URL { parts.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) } }
                while !kept.isEmpty, !FileManager.default.fileExists(atPath: url(kept).path) { kept.removeLast() }
                let list = kept == path ? FileItem.list(in: url(kept), includeHidden: true, alwaysHidden: Self.repoHidden) : []
                return (kept, list)
            }.value
            guard token == loadToken else { return }
            if kept != path { self.path = kept; return }   // didSet이 상위 폴더를 다시 읽는다
            items = list
            loading = false
            revision += 1
        }
        if changedDir {
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                if token == loadToken, loading { items = [] }
            }
        }
    }

    // MARK: - 작업

    func refresh() async {
        guard let repo else { return }
        cancelScheduledPush()
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
            // 받은 게 있을 때만 LFS 파일을 받는다 (매번 하면 5분마다 원격에 묻게 됨)
            if await repo.headHash() != before { await repo.prepareLFS() }
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
        let ok = await perform("\(urls.count)개 항목 \(verb) 중…", done: "\(urls.count)개 항목을 Git 저장소로 \(verb)했습니다",
                               undoable: true) {
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
        await perform("옮기는 중…", done: "\(paths.count)개 항목을 /\(dir)(으)로 옮겼습니다", undoable: true) {
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
        await perform("삭제하는 중…", done: "\(items.count)개 항목을 삭제했습니다", undoable: true) {
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
        await perform("이름 변경 중…", done: "이름을 \(newName)(으)로 변경했습니다", undoable: true) {
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
        await perform("폴더 만드는 중…", done: "\(name) 폴더를 만들었습니다", undoable: true) {
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
            await perform("내 폴더로 이동 중…", done: "\(urls.count)개 항목을 내 폴더로 이동했습니다", undoable: true) {
                try await repo.delete(repoPaths)
            }
        } else {
            statusMessage = "\(urls.count)개 항목을 내 폴더에 복사했습니다"
        }
    }

    // MARK: - 되돌리기 · 기록

    /// 마지막 Git 작업을 되돌린다 (되돌리는 커밋을 새로 만든다)
    func undoLast() async {
        guard let entry = undoStack.last, let repo else { return }
        let ok = await perform("되돌리는 중…", done: "되돌렸어요: \(entry.label)", pushAfter: true) {
            try await repo.revert(entry.commit)
        }
        if ok { undoStack.removeLast() }
    }

    func history(of item: FileItem) async -> [FileVersion] {
        guard let repo, let path = repoRelativePath(item.url) else { return [] }
        do {
            return try await repo.history(of: path)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// 지난 버전을 임시 폴더에 꺼내서 연다 (지금 파일은 그대로)
    func openVersion(_ version: FileVersion, of item: FileItem) async {
        guard let repo else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Gitty 지난 버전/\(version.shortHash)", isDirectory: true)
        let dest = dir.appendingPathComponent((version.path as NSString).lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try await repo.export(version, to: dest)
            Log.info("history", "\(version.path) \(version.shortHash) 버전 열기")
            NSWorkspace.shared.open(dest)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restore(_ item: FileItem, to version: FileVersion) async {
        guard let repo, let path = repoRelativePath(item.url) else { return }
        let when = version.date.formatted(date: .abbreviated, time: .shortened)
        await perform("지난 버전으로 되돌리는 중…", done: "\(item.name)을(를) \(when) 버전으로 되돌렸습니다", undoable: true) {
            try await repo.restore(path, to: version)
        }
    }

    // MARK: - push 모으기

    /// 작업이 끝날 때마다 불러, 잠깐 기다렸다가 한 번에 push한다. 그사이 다른 작업이 오면 다시 기다린다.
    private func schedulePush() {
        pushPending = true
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pushDelay)
            guard !Task.isCancelled else { return }
            await self?.flushPush()
        }
    }

    private func cancelScheduledPush() {
        pushTask?.cancel()
        pushTask = nil
        pushPending = false
    }

    /// 기다리던 push를 지금 한다. 다른 작업 중이면 끝난 뒤로 미룬다.
    func flushPush() async {
        guard pushPending, let repo else { cancelScheduledPush(); return }
        if isBusy { schedulePush(); return }
        cancelScheduledPush()
        await perform("GitHub에 올리는 중…", done: "") {
            try await repo.push()
        }
    }

    /// 앱을 끝내기 전에: 진행 중인 작업이 끝나길 기다렸다가 남은 push를 한다.
    func finishPendingWork() async {
        for _ in 0..<600 where isBusy { try? await Task.sleep(for: .milliseconds(100)) }
        if pushPending { await flushPush() }
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
    /// pushAfter: 성공하면 잠깐 뒤 push (연달아 한 작업은 한 번에)
    /// undoable: 만든 커밋을 되돌리기 목록에 넣는다 (pushAfter 포함)
    private func perform(_ label: String, done: String, quiet: Bool = false, pushAfter: Bool = false,
                         undoable: Bool = false, _ op: @escaping () async throws -> Void) async -> Bool {
        guard !isBusy else {
            if !quiet { Log.error("작업", "다른 작업 중이라 건너뜀: \(label)") }
            return false
        }
        busyMessage = label
        if !quiet { errorMessage = nil }
        let reporter = startProgress()
        await repo?.setReporter(reporter)
        _ = await repo?.takeLastCommit()
        var ok = false
        if !quiet { Log.info("작업", "\(label) [\(repoName)]") }
        do {
            try await op()
            if !quiet && !done.isEmpty {
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
        if ok && undoable, let commit = await repo?.takeLastCommit() {
            undoStack.append(UndoEntry(commit: commit, label: done))
            if undoStack.count > 50 { undoStack.removeFirst() }
        }
        busyMessage = nil
        if ok && (pushAfter || undoable) { schedulePush() }
        return ok
    }
}
