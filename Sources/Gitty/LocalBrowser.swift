import Foundation
import Observation

/// 왼쪽 "내 폴더" 패널의 상태
@MainActor
@Observable
final class LocalBrowser {
    private static let dirKey = "localDirectory"

    var dir: URL {
        didSet {
            UserDefaults.standard.set(dir.path, forKey: Self.dirKey)
            reload()
        }
    }
    private(set) var items: [FileItem] = []
    /// 폴더를 읽는 중 (Google Drive·네트워크 폴더는 몇 초 걸릴 수 있다)
    private(set) var loading = false
    /// 폴더를 읽지 못한 이유 (권한 등). 읽었으면 nil.
    private(set) var loadError: String?
    @ObservationIgnored private var loadToken = 0
    /// 지금 폴더를 지켜보다 바뀌면 다시 읽는다
    @ObservationIgnored private lazy var watcher = FolderWatcher { [weak self] in
        guard let self, !self.loading else { return }
        self.reload()
    }
    /// 다시 읽을 때마다 올라간다. 폴더 트리가 이 값을 보고 새로 그린다.
    private(set) var revision = 0
    nonisolated static let alwaysHidden: Set<String> = [".DS_Store"]
    var showHidden = false { didSet { reload() } }

    static let home = FileManager.default.homeDirectoryForCurrentUser

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.dirKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        dir = saved ?? Self.home
        reload()
    }

    var canGoUp: Bool { dir.standardizedFileURL.path != "/" }

    /// 경로 표시용: 홈 아래면 "홈 > a > b", 아니면 "/ > a > b"
    var breadcrumb: (root: URL, label: String, icon: String, components: [String]) {
        let path = dir.standardizedFileURL.path
        let homePath = Self.home.standardizedFileURL.path
        if path == homePath || path.hasPrefix(homePath + "/") {
            let rest = String(path.dropFirst(homePath.count)).split(separator: "/").map(String.init)
            return (Self.home, tr("홈"), "house.fill", rest)
        }
        let rest = path.split(separator: "/").map(String.init)
        return (URL(fileURLWithPath: "/"), "Macintosh HD", "internaldrive.fill", rest)
    }

    /// 폴더 내용을 뒤에서 읽는다. 화면은 그동안 멈추지 않는다.
    func reload() {
        loadToken += 1
        let token = loadToken
        let dir = self.dir
        let showHidden = self.showHidden
        let previous = items.first?.url.deletingLastPathComponent().standardizedFileURL.path
        let changedDir = previous != nil && previous != dir.standardizedFileURL.path
        loading = true
        Task {
            let (existing, list, error) = await Task.detached(priority: .userInitiated) {
                var target = dir
                while !FileManager.default.fileExists(atPath: target.path) && target.path != "/" {
                    target = target.deletingLastPathComponent()
                }
                let list = target == dir ? FileItem.list(in: dir, includeHidden: showHidden, alwaysHidden: Self.alwaysHidden) : []
                // 비어 보이면 진짜 비었는지, 읽지 못한 건지 확인
                var failure: String?
                if list.isEmpty, target == dir {
                    do { _ = try FileManager.default.contentsOfDirectory(atPath: dir.path) } catch {
                        let ns = error as NSError
                        let denied = ns.code == NSFileReadNoPermissionError
                            || (ns.underlyingErrors.first as NSError?)?.code == Int(EPERM)
                            || (ns.underlyingErrors.first as NSError?)?.code == Int(EACCES)
                        failure = denied ? "denied" : error.localizedDescription
                        Log.error("local", "폴더를 읽지 못함: \(dir.path)\n\(error.localizedDescription)")
                    }
                }
                return (target, list, failure)
            }.value
            guard token == loadToken else { return }   // 그사이 다른 폴더로 갔음
            if existing != dir { self.dir = existing; return }
            // 바로가기 폴더(Google Drive의 My Drive 등)는 실제 폴더로 옮겨서 경로 표시와 작업이 맞게
            let real = dir.resolvingSymlinksInPath()
            if real.standardizedFileURL.path != dir.standardizedFileURL.path {
                Log.info("local", "바로가기 폴더라 실제 위치로 이동: \(dir.path) → \(real.path)")
                self.dir = real
                return
            }   // 폴더가 사라짐: didSet이 상위 폴더를 다시 읽는다
            items = list
            loadError = error
            loading = false
            revision += 1
            watcher.watch(dir)
        }
        // 오래 걸리면 이전 폴더 내용을 치우고 "불러오는 중"을 보여 준다
        if changedDir {
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                if token == loadToken, loading { items = [] }
            }
        }
    }

    func goUp() {
        guard canGoUp else { return }
        dir = dir.deletingLastPathComponent()
    }

    func rename(_ item: FileItem, to newName: String) throws {
        guard let name = FileOps.validateName(newName), name != item.name else { return }
        try FileOps.rename(item.url, to: name)
        reload()
    }

    func createFolder(_ name: String) throws {
        guard let name = FileOps.validateName(name) else { return }
        let url = dir.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw GittyError(message: tr("같은 이름의 항목이 이미 있습니다: \(name)"))
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        reload()
    }

    func trash(_ items: [FileItem]) throws {
        defer { reload() }
        try FileOps.trash(items.map(\.url))
    }
}
