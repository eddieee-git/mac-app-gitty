import Foundation
import Observation

/// 왼쪽 패널 사이드바의 "즐겨찾기"와 "위치" (Finder 사이드바처럼)
@MainActor
@Observable
final class Places {
    private static let favoritesKey = "favoritePaths"
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// 사용자가 고친 즐겨찾기 (없으면 Finder 기본 구성)
    private(set) var favorites: [URL] = []
    /// 클라우드 드라이브, 외장·네트워크 드라이브, 홈, Macintosh HD
    private(set) var locations: [TreeRoot] = []

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.favoritesKey) {
            favorites = saved.map { URL(fileURLWithPath: $0, isDirectory: true) }
        } else {
            favorites = Self.finderDefaults
        }
        refreshLocations()
    }

    /// Finder 사이드바의 기본 즐겨찾기
    static var finderDefaults: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true), .desktopDirectory, .documentsDirectory,
         .downloadsDirectory, home]
    }

    var favoriteRoots: [TreeRoot] {
        favorites
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { TreeRoot(url: $0, title: Self.displayName($0), icon: Self.icon(for: $0)) }
    }

    func isFavorite(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return favorites.contains { $0.standardizedFileURL.path == path }
    }

    func addFavorite(_ url: URL) {
        guard !isFavorite(url) else { return }
        favorites.append(url)
        save()
        Log.info("app", "즐겨찾기에 추가: \(url.path)")
    }

    func removeFavorite(_ url: URL) {
        let path = url.standardizedFileURL.path
        favorites.removeAll { $0.standardizedFileURL.path == path }
        save()
    }

    func moveFavorites(from source: IndexSet, to destination: Int) {
        // 화면에는 존재하는 항목만 보이므로 그 순서를 기준으로 옮긴다
        var visible = favorites.filter { FileManager.default.fileExists(atPath: $0.path) }
        visible.move(fromOffsets: source, toOffset: destination)
        let missing = favorites.filter { !FileManager.default.fileExists(atPath: $0.path) }
        favorites = visible + missing
        save()
    }

    func resetFavorites() {
        favorites = Self.finderDefaults
        save()
    }

    private func save() {
        UserDefaults.standard.set(favorites.map(\.path), forKey: Self.favoritesKey)
    }

    // MARK: - 위치

    func refreshLocations() {
        var roots: [TreeRoot] = []
        let fm = FileManager.default

        // iCloud Drive
        let iCloud = Self.home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fm.fileExists(atPath: iCloud.path) {
            roots.append(TreeRoot(url: iCloud, title: "iCloud Drive", icon: "icloud"))
        }

        // Google Drive, Dropbox, OneDrive, Box 등 (~/Library/CloudStorage)
        let cloudDir = Self.home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let clouds = (try? fm.contentsOfDirectory(at: cloudDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for url in clouds.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            roots.append(TreeRoot(url: url, title: Self.cloudName(url.lastPathComponent), icon: "cloud"))
        }

        roots.append(TreeRoot(url: Self.home, title: Self.displayName(Self.home), icon: "house"))

        // 외장·네트워크 드라이브, 예전 방식 Google Drive(/Volumes/GoogleDrive)
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey],
                                           options: [.skipHiddenVolumes]) ?? []
        for url in volumes where url.path != "/" {
            let name = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
                ?? url.lastPathComponent
            let isDrive = name.localizedCaseInsensitiveContains("google")
            roots.append(TreeRoot(url: url, title: name, icon: isDrive ? "cloud" : "externaldrive"))
        }

        let disk = URL(fileURLWithPath: "/", isDirectory: true)
        let diskName = (try? disk.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "Macintosh HD"
        roots.append(TreeRoot(url: disk, title: diskName, icon: "internaldrive"))

        locations = roots
    }

    /// "GoogleDrive-me@gmail.com" → "Google Drive (me@gmail.com)"
    static func cloudName(_ folder: String) -> String {
        let parts = folder.split(separator: "-", maxSplits: 1).map(String.init)
        let provider: String
        switch parts[0].lowercased() {
        case "googledrive": provider = "Google Drive"
        case "onedrive": provider = "OneDrive"
        case "dropbox": provider = "Dropbox"
        case "box": provider = "Box"
        default: provider = parts[0]
        }
        return parts.count > 1 ? "\(provider) (\(parts[1]))" : provider
    }

    /// Finder에 보이는 이름 (예: Desktop → 데스크탑, Applications → 응용 프로그램)
    static func displayName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
    }

    static func icon(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        switch path {
        case "/Applications": return "square.grid.2x2"
        case URL.desktopDirectory.standardizedFileURL.path: return "menubar.dock.rectangle"
        case URL.documentsDirectory.standardizedFileURL.path: return "doc"
        case URL.downloadsDirectory.standardizedFileURL.path: return "arrow.down.circle"
        case home.standardizedFileURL.path: return "house"
        default:
            if path.contains("/Library/CloudStorage/") { return "cloud" }
            return "folder"
        }
    }
}

/// Git 패널의 즐겨찾기. 저장소마다 따로, 저장소 기준 경로로 저장한다.
@MainActor
@Observable
final class RepoFavorites {
    private static let key = "repoFavorites"   // [저장소 경로: [폴더 상대 경로]]
    private(set) var root: URL?
    private(set) var paths: [String] = []

    func load(root: URL?) {
        self.root = root
        guard let root else { paths = []; return }
        let all = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
        paths = all[root.standardizedFileURL.path] ?? []
    }

    /// 지금도 있는 폴더만 (다른 곳에서 지워졌거나 이름이 바뀌었으면 숨긴다)
    var roots: [TreeRoot] {
        guard let root else { return [] }
        return paths.compactMap { rel in
            let url = root.appendingPathComponent(rel, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return TreeRoot(url: url, title: (rel as NSString).lastPathComponent, icon: "folder")
        }
    }

    var actions: FavoriteActions {
        FavoriteActions(isFavorite: isFavorite, add: add, remove: remove, move: move,
                        resetLabel: "즐겨찾기 모두 지우기", reset: clear)
    }

    private func relative(_ url: URL) -> String? {
        guard let root else { return nil }
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : nil
    }

    func isFavorite(_ url: URL) -> Bool {
        relative(url).map(paths.contains) ?? false
    }

    func add(_ url: URL) {
        guard let rel = relative(url), !paths.contains(rel) else { return }
        paths.append(rel)
        save()
        Log.info("app", "Git 즐겨찾기에 추가: /\(rel)")
    }

    func remove(_ url: URL) {
        guard let rel = relative(url) else { return }
        paths.removeAll { $0 == rel }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        // 화면에는 지금 있는 폴더만 보이므로 그 순서를 기준으로 옮긴다
        guard let root else { return }
        var visible = paths.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        visible.move(fromOffsets: source, toOffset: destination)
        paths = visible + paths.filter { !visible.contains($0) }
        save()
    }

    func clear() {
        paths = []
        save()
    }

    private func save() {
        guard let root else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
        all[root.standardizedFileURL.path] = paths
        UserDefaults.standard.set(all, forKey: Self.key)
    }
}
