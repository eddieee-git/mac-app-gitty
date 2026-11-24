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
    /// 저장소에서 지금 보고 있는 폴더를 지켜본다 (Finder 등에서 바꾼 것 반영). Git 작업 중에는 작업이 끝나며 다시 읽는다.
    @ObservationIgnored private lazy var watcher = FolderWatcher { [weak self] in
        guard let self, !self.isBusy, !self.loading else { return }
        self.statusDirty = true
        self.reload()
    }
    /// 파일 상태(git status)를 다시 검사해야 하는지. 폴더만 옮겨 다닐 때는 저장소 전체를 다시 검사하지 않는다
    /// (큰 저장소에서 폴더를 열 때마다 몇 초씩 걸리므로). 파일이 바뀌었을 법할 때만 켠다.
    @ObservationIgnored private var statusDirty = true

    /// Finder 등 다른 곳에서 저장소 파일을 고쳤을 수 있을 때 (앱으로 돌아왔을 때 등)
    func markStatusDirty() { statusDirty = true }
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

    /// 지금 작업이 끝나길 기다리는 작업 수 (바쁠 때 거절하지 않고 줄을 세운다)
    private(set) var queued = 0
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 다른 작업 중이면 차례가 올 때까지 기다린다. 돌아오면 "바쁨"이 이미 이 작업 몫으로 잡혀 있다.
    private func waitTurn() async {
        guard isBusy else { return }
        queued += 1
        await withCheckedContinuation { waiters.append($0) }
        queued -= 1
    }

    /// 작업이 끝났을 때: 기다리는 작업이 있으면 바쁨을 놓지 않고 바로 넘겨준다 (그사이 다른 것이 끼어들지 않게)
    private func finishTurn() {
        if waiters.isEmpty {
            busyMessage = nil
        } else {
            busyMessage = tr("다음 작업 준비 중…")
            waiters.removeFirst().resume()
        }
    }

    /// 커밋은 했고 곧 push할 예정 (연달아 한 작업을 모아 한 번에 올린다)
    private(set) var pushPending = false
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    /// 마지막 작업 뒤 이만큼 기다렸다가 push
    static let pushDelay: Duration = .seconds(2)

    /// 되돌릴 수 있는 Git 작업 (이번에 연 저장소에서 Gitty가 한 것, 최근 것이 끝)
    struct UndoEntry: Equatable {
        /// Git 작업이면 되돌릴 커밋, 내 폴더 작업이면 nil
        var commit: CommitRef?
        /// 내 폴더 작업: 되돌릴 때 to → from으로 옮긴다
        var moves: [FileMove] = []
        let label: String
    }
    private(set) var undoStack: [UndoEntry] = []

    /// 양쪽 패널에서 고른 항목 (가운데 복사 버튼이 쓴다)
    var localSelection = Set<URL>()
    /// 저장소 크기 (상태 표시줄)
    private(set) var repoSize: RepoSize?
    @ObservationIgnored private var sizeWarned = false
    /// 알려 드릴 것 (오류가 아닌 안내 창)
    var infoMessage: String?
    /// 지금 브랜치와 고를 수 있는 브랜치들
    private(set) var branch = ""
    private(set) var branches: [String] = []
    /// 커밋 메시지를 직접 쓸 때 화면에 띄우는 요청
    struct MessageRequest: Identifiable {
        let id = UUID()
        let summary: String
        let suggestion: String
        let reply: (String?) -> Void
    }
    var messageRequest: MessageRequest?
    static let askMessageKey = "askCommitMessage"
    /// Git 쪽 파일 상태 (고침·새 파일·올리기 전·안 받음)
    private(set) var repoStatus = RepoStatus()
    /// GitHub 웹 주소와 브랜치 (링크용)
    @ObservationIgnored private var web: (url: String, branch: String)?
    /// 열린 저장소가 공개인지 (gh로 확인, 모르면 nil)
    private(set) var repoIsPublic: Bool?
    /// 이번에 연 동안 공개 저장소 경고를 이미 했는지
    @ObservationIgnored private var publicWarned = false
    var repoSelection = Set<URL>()

    /// 원격과 충돌해서 사용자가 골라야 하는 파일 (합치기가 열려 있는 동안)
    private(set) var conflicts: [ConflictFile]?
    var undoLabel: String? { undoStack.last?.label }

    /// 앱 종료 때 남은 push를 마저 하기 위해 (AppDelegate에서 씀)
    /// 열려 있는 모든 창의 AppModel (종료 전에 남은 push를 마치려고)
    private static let liveTable = NSHashTable<AppModel>.weakObjects()
    static var live: [AppModel] { liveTable.allObjects }

    static let reposDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Gitty/Repos", isDirectory: true)

    private let recentsKey = "recentRepos"

    init() {
        Self.liveTable.add(self)
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
            errorMessage = tr("Git 저장소 폴더가 아니에요: \(url.path)")
            return
        }
        // 같은 저장소를 여러 탭에서 열어도 git 작업이 겹치지 않게 하나를 함께 쓴다
        let repo = GitRepo.shared(for: url)
        Log.info("repo", "열기: \(url.path)")
        self.repo = repo
        root = url
        repoFavorites.load(root: url)
        undoStack = []
        conflicts = nil
        repoIsPublic = nil
        repoSize = nil
        sizeWarned = false
        branch = ""
        branches = []
        publicWarned = false
        repoName = await repo.displayName()
        Task { await checkVisibility(of: url) }
        web = await repo.webBase()
        path = []
        addRecent(url)
        // 지난번에 충돌을 풀다 말고 닫았으면 그것부터
        if await repo.mergeInProgress() {
            await repo.prepareIdentity()
            let files = await repo.conflicts()
            if !files.isEmpty {
                conflicts = files
                statusMessage = tr("원격과 충돌한 파일이 있어요")
                return
            }
        }
        let ok = await perform(tr("원격과 동기화 중…"), done: tr("최신 상태예요")) {
            await repo.prepareIdentity()
            await repo.prepareExcludes()
            try await repo.pull()
            await repo.prepareLFS()
        }
        if ok { lastSynced = Date() }
        Task { await checkGitHubLogin() }
        Task { await refreshSize(); await loadBranches() }
    }

    /// 저장소를 열 때 gh 로그인이 살아 있는지 미리 본다. push가 실패하고 나서야 알게 되지 않게.
    private func checkGitHubLogin() async {
        guard let gh = Shell.ghPath else {
            errorMessage = tr("GitHub CLI(gh)가 없어서 GitHub에 올릴 수 없어요. 터미널에서 brew install gh 후 gh auth login 을 실행해 주세요.")
            return
        }
        let r = await Shell.run(gh, ["auth", "status", "--hostname", "github.com"])
        guard r.status != 0 else { return }
        let text = (r.stdout + r.stderr).lowercased()
        // 오프라인이라 확인을 못 한 것은 알리지 않는다
        if text.contains("not logged") || text.contains("invalid") || text.contains("expired") {
            Log.error("repo", "gh 로그인 확인 실패\n\(r.errorText)")
            errorMessage = tr("GitHub 로그인이 풀렸어요. 터미널에서 gh auth login 을 실행한 뒤 다시 시도해 주세요.")
        }
    }

    /// 상태 표시줄의 취소 단추
    func cancelCurrent() {
        guard isBusy else { return }
        Cancellation.request()
        busyMessage = tr("취소하는 중…")
    }

    func clone(_ spec: String) async {
        await waitTurn()
        busyMessage = tr("클론하는 중…")
        Cancellation.reset()
        let reporter = startProgress()
        var released = false
        defer { if !released { finishTurn() }; endProgress() }
        do {
            let url = try await GitRepo.clone(spec, into: Self.reposDirectory, reporter: reporter)
            released = true
            finishTurn()
            endProgress()
            await open(url)
        } catch {
            if Cancellation.isRequested {
                statusMessage = tr("클론을 취소했어요")
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func close() {
        watcher.stop()
        if pushPending, let repo {
            // 저장소 목록으로 돌아가도 커밋해 둔 것은 마저 올린다
            pushPending = false
            pushTask?.cancel()
            Task.detached { try? await repo.push() }
        }
        repo = nil
        root = nil
        repoSelection = []
        undoStack = []
        conflicts = nil
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
            if !isBusy && statusDirty { Task { await refreshStatus() } }
            watcher.watch(kept.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) })
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
        let ok = await perform(tr("원격과 동기화 중…"), done: tr("최신 상태예요")) {
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
        let ok = await perform(tr("자동 동기화 중…"), done: "", quiet: true) {
            try await repo.pull()
            if pending > 0 { try await repo.push() }
            // 받은 게 있을 때만 LFS 파일을 받는다 (매번 하면 5분마다 원격에 묻게 됨)
            if await repo.headHash() != before { await repo.prepareLFS() }
        }
        guard ok else { return }
        lastSynced = Date()
        if let root { await checkVisibility(of: root) }   // 그사이 공개로 바뀌었는지
        let after = await repo.headHash()
        if let before, let after, before != after {
            let count = await repo.commitCount(from: before, to: after)
            let time = Date().formatted(date: .omitted, time: .shortened)
            statusMessage = tr("원격 변경 \(count)개를 받았어요 (\(time))")
            Log.info("자동 동기화", "원격 변경 \(count)개를 받았어요 [\(repoName)]")
        }
    }

    /// removeLocalAfter: 업로드(커밋·push) 성공 후 원본을 휴지통으로 보내 "이동"이 되게 한다.
    /// dir: 저장소 안의 올릴 폴더 (nil이면 지금 보고 있는 폴더)
    func upload(_ urls: [URL], removeLocalAfter: Bool = false, to targetDir: String? = nil) async {
        guard let repo, !urls.isEmpty else { return }
        let dir = targetDir ?? relativeDir
        let n = urls.count
        let label = removeLocalAfter ? tr("\(n)개 항목 이동 중…") : tr("\(n)개 항목 업로드 중…")
        let done = removeLocalAfter ? tr("\(n)개 항목을 Git 저장소로 이동했어요") : tr("\(n)개 항목을 Git 저장소로 업로드했어요")
        let ok = await perform(label, done: done,
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
        await perform(tr("옮기는 중…"), done: tr("\(paths.count)개 항목을 /\(dir)(으)로 옮겼어요"), undoable: true) {
            try await repo.move(paths, toDir: dir)
        }
    }

    /// 내 폴더 안에서 다른 폴더로 옮기기
    func moveLocal(_ urls: [URL], into folder: URL) {
        do {
            let moves = try FileOps.move(urls, into: folder)
            recordLocalUndo(tr("\(urls.count)개 항목을 \(folder.lastPathComponent)(으)로 옮겼어요"), moves: moves)
            Log.info("move", "내 폴더 안에서 \(folder.path)(으)로 옮김: \(urls.map(\.lastPathComponent).joined(separator: ", "))")
            statusMessage = tr("\(urls.count)개 항목을 \(folder.lastPathComponent)(으)로 옮겼어요")
        } catch {
            Log.error("move", error.localizedDescription)
            errorMessage = error.localizedDescription
        }
        local.reload()
    }

    func delete(_ items: [FileItem]) async {
        guard let repo, !items.isEmpty else { return }
        let paths = items.compactMap { repoRelativePath($0.url) }
        await perform(tr("삭제하는 중…"), done: tr("\(items.count)개 항목을 삭제했어요"), undoable: true) {
            try await repo.delete(paths)
        }
    }

    func rename(_ item: FileItem, to newName: String) async {
        guard let repo else { return }
        let newName = newName.trimmed
        guard !newName.isEmpty, newName != item.name else { return }
        guard !newName.contains("/"), newName != ".", newName != ".." else {
            errorMessage = tr("이름에 / 를 사용할 수 없어요.")
            return
        }
        let siblings = existingNames(in: item.url.deletingLastPathComponent())
        if siblings.contains(where: { $0.lowercased() == newName.lowercased() && $0.lowercased() != item.name.lowercased() }) {
            errorMessage = tr("같은 이름의 항목이 이미 있어요: \(newName)")
            return
        }
        guard let path = repoRelativePath(item.url) else { return }
        await perform(tr("이름 변경 중…"), done: tr("이름을 ‘\(newName)’(으)로 바꿨어요"), undoable: true) {
            try await repo.rename(path, to: newName)
        }
    }

    func createFolder(_ name: String) async {
        guard let repo else { return }
        let name = name.trimmed
        guard !name.isEmpty, !name.contains("/") else { return }
        if items.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            errorMessage = tr("같은 이름의 항목이 이미 있어요: \(name)")
            return
        }
        let path = relativeDir.isEmpty ? name : "\(relativeDir)/\(name)"
        await perform(tr("폴더 만드는 중…"), done: tr("‘\(name)’ 폴더를 만들었어요"), undoable: true) {
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
        guard !urls.isEmpty else { return }
        await waitTurn()
        Log.info("download", "내 폴더(\((folder ?? local.dir).path))로 \(removeFromRepo ? "이동" : "복사")\n" + urls.map(\.path).joined(separator: "\n"))
        let dest = folder ?? local.dir
        // Google Drive처럼 온라인 전용 파일은 받는 데 오래 걸릴 수 있어 화면이 멈추지 않게 백그라운드에서 복사
        busyMessage = tr("내 폴더로 복사 중…")
        Cancellation.reset()
        let reporter = startProgress()
        reporter.begin(tr("내 폴더로 복사 중"), totalBytes: FileOps.totalSize(urls))
        defer { endProgress() }
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileOps.copy(urls, into: dest, progress: { reporter.advance($0) })
            }.value
        } catch is CancellationError {
            finishTurn()
            statusMessage = tr("취소했어요")
            Log.info("download", "내려받기 취소")
            local.reload()
            return
        } catch {
            finishTurn()
            Log.error("download", error.localizedDescription)
            errorMessage = error.localizedDescription
            local.reload()
            return
        }
        finishTurn()
        endProgress()
        local.reload()
        Log.info("download", "복사 완료: \(urls.map(\.lastPathComponent).joined(separator: ", "))")

        let repoPaths = urls.compactMap(repoRelativePath)
        if removeFromRepo, let repo, !repoPaths.isEmpty {
            await perform(tr("내 폴더로 이동 중…"), done: tr("\(urls.count)개 항목을 내 폴더로 이동했어요"), undoable: true) {
                try await repo.delete(repoPaths)
            }
        } else {
            statusMessage = tr("\(urls.count)개 항목을 내 폴더에 복사했어요")
        }
    }

    // MARK: - 되돌리기 · 기록

    /// 마지막 Git 작업을 되돌린다 (되돌리는 커밋을 새로 만든다)
    func undoLast() async {
        guard let entry = undoStack.last else { return }
        guard let commit = entry.commit else {
            undoLocal(entry)
            return
        }
        guard let repo else { return }
        let ok = await perform(tr("되돌리는 중…"), done: tr("되돌렸어요: \(entry.label)"), pushAfter: true) {
            try await repo.revert(commit)
        }
        if ok { undoStack.removeLast() }
    }

    /// 내 폴더 쪽 작업(휴지통, 옮기기, 이름 바꾸기)을 기록해 둔다
    func recordLocalUndo(_ label: String, moves: [FileMove]) {
        guard !moves.isEmpty else { return }
        undoStack.append(UndoEntry(commit: nil, moves: moves, label: label))
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    /// 옮긴 것을 원래 자리로 (나중에 한 것부터)
    private func undoLocal(_ entry: UndoEntry) {
        let fm = FileManager.default
        do {
            for move in entry.moves.reversed() {
                if fm.fileExists(atPath: move.from.path) {
                    throw GittyError(message: tr("원래 자리에 같은 이름이 이미 있어서 되돌릴 수 없어요: \(move.from.lastPathComponent)"))
                }
                guard fm.fileExists(atPath: move.to.path) else {
                    throw GittyError(message: tr("되돌릴 항목을 찾을 수 없어요 (휴지통을 비웠을 수 있어요): \(move.to.lastPathComponent)"))
                }
                try fm.createDirectory(at: move.from.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: move.to, to: move.from)
            }
            undoStack.removeLast()
            statusMessage = tr("되돌렸어요: \(entry.label)")
            Log.info("local", "되돌림: \(entry.label)")
        } catch {
            errorMessage = error.localizedDescription
        }
        local.reload()
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

    /// "이 버전 열기"로 꺼낸 임시 파일 중 하루가 지난 것을 지운다 (앱을 켤 때)
    nonisolated static func cleanOldVersionFiles() {
        let fm = FileManager.default
        let names = Set(["Gitty 지난 버전", "Gitty past versions", tr("Gitty 지난 버전/{}").components(separatedBy: "/").first ?? ""]) // no-tr
        for name in names where !name.isEmpty {
            let dir = fm.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for item in items {
                let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if Date().timeIntervalSince(date) > 24 * 3600 { try? fm.removeItem(at: item) }
            }
        }
    }

    /// 지난 버전을 임시 폴더에 꺼내서 연다 (지금 파일은 그대로)
    func openVersion(_ version: FileVersion, of item: FileItem) async {
        guard let repo else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(tr("Gitty 지난 버전/\(version.shortHash)"), isDirectory: true)
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
        await perform(tr("지난 버전으로 되돌리는 중…"), done: tr("\(item.name)을(를) \(when) 버전으로 되돌렸어요"), undoable: true) {
            try await repo.restore(path, to: version)
        }
    }

    // MARK: - 충돌

    /// 고른 대로 충돌을 풀고 올린다
    func resolveConflicts(_ choices: [String: ConflictChoice]) async {
        guard let repo, conflicts != nil else { return }
        let count = choices.count
        conflicts = nil
        let ok = await perform(tr("충돌 정리하는 중…"), done: tr("충돌한 파일 \(count)개를 정리했어요"), allowDuringConflict: true) {
            try await repo.resolveConflicts(choices)
            await repo.prepareLFS()
            try await repo.push()
        }
        if ok { lastSynced = Date() }
    }

    /// 충돌을 풀지 않고 원격 변경 받기를 그만둔다. 다음 동기화 때 다시 묻는다.
    func cancelConflicts() async {
        guard let repo else { return }
        await repo.abortMerge()
        conflicts = nil
        statusMessage = tr("원격 변경을 받지 않았어요. 동기화하면 다시 물어요")
        reload()
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
        if conflicts != nil { cancelScheduledPush(); return }   // 충돌을 정리하면서 함께 올린다
        cancelScheduledPush()
        await perform(tr("GitHub에 올리는 중…"), done: "") {
            try await repo.push()
        }
    }

    /// 앱을 끝내기 전에: 진행 중인 작업이 끝나길 기다렸다가 남은 push를 한다.
    func finishPendingWork() async {
        for _ in 0..<600 where isBusy { try? await Task.sleep(for: .milliseconds(100)) }
        if pushPending { await flushPush() }
    }

    /// gh로 저장소가 공개인지 확인한다 (원격이 GitHub일 때만)
    private func checkVisibility(of url: URL) async {
        guard let gh = Shell.ghPath, repoName.contains("/") else { return }
        let r = await Shell.run(gh, ["repo", "view", repoName, "--json", "visibility", "-q", ".visibility"], cwd: url)
        guard root == url, r.status == 0 else { return }
        let isPublic = r.stdout.trimmed.uppercased() == "PUBLIC"
        if repoIsPublic == false && isPublic {
            // 비공개였다가 공개로 바뀌었으면 다음 업로드 때 다시 확인한다
            publicWarned = false
            statusMessage = tr("‘\(repoName)’이(가) 공개 저장소로 바뀌었어요. 올릴 때 다시 확인해요.")
            Log.info("repo", "\(repoName): 비공개 → 공개로 바뀜")
        }
        if repoIsPublic != isPublic { Log.info("repo", "\(repoName): \(isPublic ? "공개" : "비공개") 저장소") }
        repoIsPublic = isPublic
    }

    /// "큰 파일 필요할 때 받기"일 때: 열거나 복사하기 전에 그 파일들의 실제 내용을 받는다
    func materialize(_ urls: [URL]) async -> Bool {
        guard let repo, UserDefaults.standard.bool(forKey: GitRepo.lfsOnDemandKey) else { return true }
        var files: [String] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
                while let u = e?.nextObject() as? URL { if let p = repoRelativePath(u), GitRepo.isLFSPointer(u) { files.append(p) } }
            } else if let p = repoRelativePath(url), GitRepo.isLFSPointer(url) {
                files.append(p)
            }
        }
        guard !files.isEmpty else { return true }
        return await perform(tr("큰 파일 받는 중…"), done: tr("큰 파일 \(files.count)개를 받았어요")) {
            try await repo.materialize(files)
        }
    }

    // MARK: - 크기 · 휴지통 · 브랜치 · 메시지 · 새 저장소

    func refreshSize() async {
        guard let repo else { return }
        let size = await repo.size()
        guard root != nil else { return }
        repoSize = size
        if size.nearLimit && !sizeWarned {
            sizeWarned = true
            Log.info("repo", "저장소 크기 경고: git \(size.git) B, LFS \(size.lfs) B")
            infoMessage = tr("저장소가 GitHub 권장 크기에 가까워졌어요. 저장소 \(Self.bytes(size.git)) / 1 GB, LFS \(Self.bytes(size.lfs)) / 1 GB.\n\nGit은 지운 파일도 기록에 남겨서 지워도 크기가 줄지 않아요. 큰 파일이 많다면 새 저장소로 나누는 걸 생각해 보세요.")
        }
    }

    nonisolated static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    func deletedFiles() async -> [DeletedFile] {
        await repo?.deletedFiles() ?? []
    }

    func restoreDeleted(_ files: [DeletedFile]) async {
        guard let repo, !files.isEmpty else { return }
        await perform(tr("되살리는 중…"), done: tr("\(files.count)개 파일을 되살렸어요"), undoable: true) {
            try await repo.restoreDeleted(files)
        }
    }

    func loadBranches() async {
        guard let repo else { return }
        let info = await repo.branches()
        guard root != nil else { return }
        branch = info.current
        branches = info.all
    }

    /// 브랜치를 바꾼다 (create면 새로 만든다). 올리지 않은 커밋은 먼저 올린다.
    func switchBranch(_ name: String, create: Bool) async {
        guard let repo, name != branch || create else { return }
        if pushPending { await flushPush() }
        let ok = await perform(create ? tr("‘\(name)’ 브랜치 만드는 중…") : tr("‘\(name)’ 브랜치로 바꾸는 중…"),
                               done: create ? tr("‘\(name)’ 브랜치를 만들었어요") : tr("‘\(name)’ 브랜치로 바꿨어요")) {
            try await repo.switchBranch(name, create: create)
        }
        if ok {
            undoStack = []
            path = []
            if create { schedulePush() }   // 새 브랜치를 GitHub에도 만든다
        }
        await loadBranches()
    }

    /// 커밋 메시지 창을 띄우고 답을 기다린다 (nil = 취소)
    private func askMessage(summary: String, suggestion: String) async -> String? {
        await withCheckedContinuation { continuation in
            messageRequest = MessageRequest(summary: summary, suggestion: suggestion) { [weak self] answer in
                self?.messageRequest = nil
                continuation.resume(returning: answer)
            }
        }
    }

    /// GitHub에 새 저장소를 만들고 바로 연다
    func createRepository(name: String, isPrivate: Bool) async {
        await waitTurn()
        busyMessage = tr("‘\(name)’ 저장소 만드는 중…")
        do {
            let spec = try await GitRepo.createRepo(name: name, isPrivate: isPrivate)
            finishTurn()
            await clone(spec)
        } catch {
            finishTurn()
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 파일 상태 · 링크

    func refreshStatus() async {
        guard let repo else { repoStatus = RepoStatus(); return }
        statusDirty = false
        let s = await repo.status()
        if s != repoStatus { repoStatus = s }
    }

    func badge(for item: FileItem) -> FileBadge? {
        guard let path = repoRelativePath(item.url) else { return nil }
        return repoStatus.badge(for: path, isDirectory: item.isDirectory)
    }

    /// 저장소 폴더에서 직접 고친 것을 올린다 (paths가 nil이면 바뀐 것 모두)
    func commitChanges(_ items: [FileItem]? = nil) async {
        guard let repo else { return }
        let all = repoStatus.changedPaths
        let paths: [String]
        if let items {
            let picked = items.compactMap { repoRelativePath($0.url) }
            paths = all.filter { p in picked.contains { p == $0 || p.hasPrefix($0 + "/") } }
        } else {
            paths = all
        }
        guard !paths.isEmpty else { return }
        await perform(tr("바뀐 내용 올리는 중…"), done: tr("바뀐 파일 \(paths.count)개를 올렸어요"), undoable: true) {
            try await repo.commitChanges(paths)
        }
    }

    /// GitHub에서 그 파일·폴더를 보는 주소
    func webURL(for item: FileItem) -> URL? {
        guard let web, let path = repoRelativePath(item.url) ?? (item.url == root ? "" : nil) else { return nil }
        let kind = item.isDirectory ? "tree" : "blob"
        let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return URL(string: "\(web.url)/\(kind)/\(web.branch)/\(encoded)")
    }

    // MARK: - 폴더 맞추기

    /// 지금 보고 있는 두 폴더를 비교한다 (뒤에서)
    func syncPlan(_ direction: FolderSync.Direction) async -> FolderSync.Plan? {
        guard let repoDir = currentDir else { return nil }
        let localDir = local.dir
        return await Task.detached(priority: .userInitiated) {
            direction == .toRepo ? FolderSync.compare(from: localDir, to: repoDir)
                                 : FolderSync.compare(from: repoDir, to: localDir)
        }.value
    }

    /// 비교한 대로 맞춘다. deleteExtra면 받는 쪽에만 있는 파일을 지운다 (내 폴더 쪽은 휴지통으로).
    func runSync(_ direction: FolderSync.Direction, plan: FolderSync.Plan, deleteExtra: Bool) async {
        guard let repo, let repoDir = currentDir else { return }
        let send = plan.added + plan.changed
        let deletes = deleteExtra ? plan.extra : []
        let localDir = local.dir
        let dir = relativeDir
        Log.info("sync", "\(direction == .toRepo ? "내 폴더 → Git" : "Git → 내 폴더") 맞추기: 보냄 \(send.count), 지움 \(deletes.count)\n내 폴더: \(localDir.path)\nGit: /\(dir)")
        switch direction {
        case .toRepo:
            await perform(tr("폴더 맞추는 중…"), done: tr("Git 폴더를 내 폴더와 같게 맞췄어요 (\(send.count)개 올림, \(deletes.count)개 지움)"),
                          undoable: true) {
                try await repo.syncIn(from: localDir, files: send, deletes: deletes, dir: dir)
            }
        case .toLocal:
            guard await materialize(send.map { repoDir.appendingPathComponent($0) }) else { return }
            await perform(tr("폴더 맞추는 중…"), done: tr("내 폴더를 Git 폴더와 같게 맞췄어요 (\(send.count)개 받음, \(deletes.count)개 휴지통)")) {
                try await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    for rel in send {
                        try Cancellation.check()
                        let dst = localDir.appendingPathComponent(rel)
                        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if fm.fileExists(atPath: dst.path) { try fm.trashItem(at: dst, resultingItemURL: nil) }
                        try FileOps.copyFile(repoDir.appendingPathComponent(rel), to: dst, progress: nil)
                    }
                    if !deletes.isEmpty { try FileOps.trash(deletes.map { localDir.appendingPathComponent($0) }) }
                }.value
            }
            local.reload()
        }
    }

    // MARK: - 복사 계획 (같은 이름이 있으면 덮어쓸지 먼저 묻는다)

    struct TransferPlan {
        let title: String
        let conflicts: [String]
        let note: String
        var confirm = tr("덮어쓰기")
        /// 비밀 파일·공개 저장소처럼 같은 이름이 없어도 꼭 물어봐야 하는 경우
        var mustAsk = false
        let run: () -> Void
    }

    /// 왼쪽(내 폴더) → Git 폴더로 복사. toDir: 저장소 안의 폴더 (nil이면 지금 보고 있는 폴더)
    /// 같은 이름, 비밀 정보일 수 있는 파일, 공개 저장소면 먼저 묻는다.
    func uploadPlan(_ urls: [URL], removeLocalAfter: Bool = false, toDir: String? = nil) -> TransferPlan? {
        guard !urls.isEmpty, let root else { return nil }
        let dir = toDir ?? relativeDir
        let destURL = dir.isEmpty ? root : root.appendingPathComponent(dir, isDirectory: true)
        let names = existingNames(in: destURL)
        let conflicts = urls.map(\.lastPathComponent).filter(names.contains)
        let secrets = UploadSafety.findings(in: urls)
        let askPublic = repoIsPublic == true && !publicWarned
        let run = {
            if askPublic { self.publicWarned = true }
            Task { await self.upload(urls, removeLocalAfter: removeLocalAfter, to: dir) }
        }
        let publicLine = repoIsPublic == true ? tr("‘\(repoName)’은(는) 공개 저장소라 누구나 볼 수 있어요.") : ""
        if !secrets.isEmpty {
            Log.info("upload", "비밀 정보일 수 있는 파일이 있어 묻는 중: \(secrets.joined(separator: ", "))")
            let list = secrets.prefix(10).joined(separator: "\n") + (secrets.count > 10 ? tr("\n외 \(secrets.count - 10)개") : "")
            var note = tr("Git에 올라간 파일은 나중에 지워도 기록에 남아요. 비밀번호·키가 들어 있으면 올리지 마세요.")
                + "\n" + tr("이미 올린 적이 있다면 그 키는 폐기하고 새로 만드세요. 지우기만으로는 기록에서 사라지지 않아요.")
            if !publicLine.isEmpty { note += "\n" + publicLine }
            if !conflicts.isEmpty { note += tr("\n같은 이름이 있는 \(conflicts.count)개는 덮어써요.") }
            return TransferPlan(title: tr("비밀 정보가 들어 있을 수 있는 파일이 있어요"), conflicts: [list], note: note,
                                confirm: tr("그래도 올리기"), mustAsk: true, run: run)
        }
        if askPublic {
            let note = tr("이번에 연 동안은 다시 묻지 않아요.") + (conflicts.isEmpty ? "" : tr("\n같은 이름이 있는 \(conflicts.count)개는 덮어써요."))
            return TransferPlan(title: tr("공개 저장소에 올릴까요?"), conflicts: [publicLine], note: note,
                                confirm: tr("올리기"), mustAsk: true, run: run)
        }
        return TransferPlan(title: tr("Git 저장소의 같은 이름 항목을 덮어쓸까요?"), conflicts: conflicts, note: "", run: run)
    }

    /// 오른쪽(Git) → 지금 보고 있는 내 폴더로 복사
    func downloadPlan(_ urls: [URL], removeFromRepo: Bool = false) -> TransferPlan? {
        guard !urls.isEmpty else { return nil }
        let names = existingNames(in: local.dir)
        return TransferPlan(title: tr("내 폴더의 같은 이름 항목을 덮어쓸까요?"),
                            conflicts: urls.map(\.lastPathComponent).filter(names.contains),
                            note: tr("기존 항목은 휴지통으로 이동해요."),
                            run: { Task {
                                guard await self.materialize(urls) else { return }
                                await self.copyToLocal(urls, removeFromRepo: removeFromRepo)
                            } })
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
                         undoable: Bool = false, allowDuringConflict: Bool = false,
                         _ op: @escaping () async throws -> Void) async -> Bool {
        // 설정에서 켰으면 커밋을 만드는 작업 전에 메시지를 받는다 (취소하면 하지 않는다)
        if undoable && !quiet && UserDefaults.standard.bool(forKey: Self.askMessageKey) {
            guard let message = await askMessage(summary: label, suggestion: done) else {
                statusMessage = tr("취소했어요")
                return false
            }
            await repo?.setNextMessage(message)
        }
        var waited = false
        if isBusy {
            // 자동 동기화처럼 조용한 작업은 기다리지 않고 다음 차례로 넘긴다
            if quiet { return false }
            Log.info("작업", "다른 작업이 끝나길 기다림: \(label)")
            await waitTurn()
            waited = true
        }
        if conflicts != nil && !allowDuringConflict {
            if !quiet { errorMessage = tr("먼저 원격과 충돌한 파일을 정리해 주세요.") }
            if waited { finishTurn() }   // 넘겨받은 차례를 다음 작업에 돌려준다
            return false
        }
        busyMessage = label
        let started = Date()
        Cancellation.reset()
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
        } catch is CancellationError {
            statusMessage = tr("취소했어요")
            Log.info("작업", "취소됨: \(label)")
        } catch let conflict as MergeConflictError {
            conflicts = conflict.files
            statusMessage = tr("원격과 충돌한 파일이 있어요")
        } catch {
            if GitErrors.isOffline(error) {
                // 오프라인은 창을 띄우지 않는다. 커밋은 남아 있고, 연결되면 자동 동기화·다시 시도로 올라간다.
                Log.error(quiet ? "자동 동기화" : "작업", "오프라인: \(label)\n\(error.localizedDescription)")
                statusMessage = tr("오프라인이에요 · 연결되면 올려요")
            } else if quiet {
                Log.error("자동 동기화", error.localizedDescription)
                statusMessage = tr("자동 동기화 실패 (작업 기록 참고)")
            } else {
                statusMessage = tr("작업 실패")
                errorMessage = error.localizedDescription
                Log.error("작업", "실패: \(label)\n\(error.localizedDescription)")
            }
        }
        await repo?.setReporter(nil)
        endProgress()
        reload()
        unpushed = await repo?.unpushedCount() ?? 0
        if !quiet && ok { Task { await refreshSize() } }
        await refreshStatus()
        if ok && undoable, let commit = await repo?.takeLastCommit() {
            undoStack.append(UndoEntry(commit: commit, label: done))
            if undoStack.count > 50 { undoStack.removeFirst() }
        }
        finishTurn()
        if !quiet {
            Notifier.taskFinished(ok ? tr("Gitty · 끝났어요") : tr("Gitty · 실패했어요"),
                                  body: ok ? (done.isEmpty ? label : done) : (errorMessage ?? statusMessage),
                                  seconds: Date().timeIntervalSince(started))
        }
        if ok && (pushAfter || undoable) { schedulePush() }
        return ok
    }
}
