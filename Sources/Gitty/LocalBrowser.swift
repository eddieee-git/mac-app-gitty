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
            return (Self.home, "홈", "house.fill", rest)
        }
        let rest = path.split(separator: "/").map(String.init)
        return (URL(fileURLWithPath: "/"), "Macintosh HD", "internaldrive.fill", rest)
    }

    func reload() {
        var target = dir
        while !FileManager.default.fileExists(atPath: target.path) && target.path != "/" {
            target = target.deletingLastPathComponent()
        }
        if target != dir { dir = target; return }   // didSet이 다시 reload
        items = FileItem.list(in: dir, includeHidden: showHidden, alwaysHidden: Self.alwaysHidden)
        revision += 1
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
            throw GittyError(message: "같은 이름의 항목이 이미 있습니다: \(name)")
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        reload()
    }

    func trash(_ items: [FileItem]) throws {
        defer { reload() }
        try FileOps.trash(items.map(\.url))
    }
}
