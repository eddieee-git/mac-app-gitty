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
    private(set) var busyMessage: String?
    private(set) var statusMessage = ""
    var errorMessage: String?
    private(set) var unpushed = 0
    private(set) var recents: [URL] = []
    /// 왼쪽 "내 폴더" 패널
    let local = LocalBrowser()

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
        self.repo = repo
        root = url
        repoName = await repo.displayName()
        path = []
        addRecent(url)
        await perform("원격과 동기화 중…", done: "최신 상태입니다") {
            await repo.prepareIdentity()
            try await repo.pull()
        }
    }

    func clone(_ spec: String) async {
        busyMessage = "클론하는 중…"
        defer { busyMessage = nil }
        do {
            let url = try await GitRepo.clone(spec, into: Self.reposDirectory)
            busyMessage = nil
            await open(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func close() {
        repo = nil
        root = nil
        items = []
        statusMessage = ""
        unpushed = 0
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
        let hidden: Set<String> = [".git", ".DS_Store", ".gitkeep"]
        items = FileItem.list(in: dir) { hidden.contains($0) }
    }

    // MARK: - 작업

    func refresh() async {
        guard let repo else { return }
        await perform("원격과 동기화 중…", done: "최신 상태입니다") {
            try await repo.pull()
            try await repo.push()   // 이전에 실패한 push가 있으면 함께 전송
        }
    }

    /// removeLocalAfter: 업로드(커밋·push) 성공 후 원본을 휴지통으로 보내 "이동"이 되게 한다.
    func upload(_ urls: [URL], removeLocalAfter: Bool = false) async {
        guard let repo, !urls.isEmpty else { return }
        let dir = relativeDir
        let verb = removeLocalAfter ? "이동" : "업로드"
        let ok = await perform("\(urls.count)개 항목 \(verb) 중…", done: "\(urls.count)개 항목을 Git 저장소로 \(verb)했습니다") {
            try await repo.upload(urls, to: dir)
        }
        if ok && removeLocalAfter {
            do { try FileOps.trash(urls) } catch { errorMessage = error.localizedDescription }
        }
        local.reload()
    }

    func delete(_ items: [FileItem]) async {
        guard let repo, !items.isEmpty else { return }
        let paths = items.map(relativePath(of:))
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
        if items.contains(where: { $0.name.lowercased() == newName.lowercased() && $0.id != item.id }) {
            errorMessage = "같은 이름의 항목이 이미 있습니다: \(newName)"
            return
        }
        let path = relativePath(of: item)
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
    func copyToLocal(_ urls: [URL], removeFromRepo: Bool) async {
        guard !urls.isEmpty, !isBusy else { return }
        do {
            try FileOps.copy(urls, into: local.dir)
        } catch {
            errorMessage = error.localizedDescription
            local.reload()
            return
        }
        local.reload()

        let repoPaths = urls.compactMap(repoRelativePath)
        if removeFromRepo, let repo, !repoPaths.isEmpty {
            await perform("내 폴더로 이동 중…", done: "\(urls.count)개 항목을 내 폴더로 이동했습니다") {
                try await repo.delete(repoPaths)
            }
        } else {
            statusMessage = "\(urls.count)개 항목을 내 폴더에 복사했습니다"
        }
    }

    @discardableResult
    private func perform(_ label: String, done: String, _ op: @escaping () async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        busyMessage = label
        errorMessage = nil
        var ok = false
        do {
            try await op()
            statusMessage = done
            ok = true
        } catch {
            statusMessage = "작업 실패"
            errorMessage = error.localizedDescription
        }
        reload()
        unpushed = await repo?.unpushedCount() ?? 0
        busyMessage = nil
        return ok
    }
}
