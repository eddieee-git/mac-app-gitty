import Foundation
import Observation

/// 왼쪽 패널 사이드바의 "즐겨찾기"와 "위치" (Finder 사이드바처럼)
@MainActor
@Observable
final class Places {
    private static let favoritesKey = "favoritePaths"
    nonisolated static let home = FileManager.default.homeDirectoryForCurrentUser

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
        searchMyDrivesWithSpotlight()
    }

    /// Finder 사이드바의 기본 즐겨찾기
    static var finderDefaults: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true), .desktopDirectory, .documentsDirectory,
         .downloadsDirectory, home]
    }

    var favoriteRoots: [TreeRoot] {
        favorites
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { url in
                if let title = myDriveTitles[url.standardizedFileURL.path] {
                    return TreeRoot(url: url, title: title, icon: "externaldrive.badge.icloud")
                }
                return TreeRoot(url: url, title: Self.displayName(url), icon: Self.icon(for: url))
            }
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

        // Google Drive의 "내 드라이브"는 맨 위에 따로 (안쪽 깊이 있거나, 미러링이면 아예 다른 폴더에 있어서 찾기 어렵다)
        let myDrives = Self.googleMyDrives(extra: foundMyDrives)
        myDriveTitles = Dictionary(myDrives.map { ($0.url.standardizedFileURL.path, $0.title) }, uniquingKeysWith: { a, _ in a })
        for drive in myDrives {
            roots.append(TreeRoot(url: drive.url, title: drive.title, icon: "externaldrive.badge.icloud"))
        }

        // Google Drive(공유 드라이브 등), Dropbox, OneDrive, Box (~/Library/CloudStorage)
        let cloudDir = Self.home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let clouds = (try? fm.contentsOfDirectory(at: cloudDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for url in clouds.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            roots.append(TreeRoot(url: url, title: Self.cloudName(url.lastPathComponent), icon: "cloud"))
        }
        addMyDrivesToFavoritesOnce(myDrives.map(\.url))
        if myDrives.map(\.url) != loggedMyDrives {
            loggedMyDrives = myDrives.map(\.url)
            Log.info("app", "클라우드 폴더: " + (clouds.map(\.lastPathComponent).joined(separator: ", ").nilIfEmpty ?? "없음")
                     + " · 내 드라이브: " + (myDrives.map(\.url.path).joined(separator: ", ").nilIfEmpty ?? "못 찾음"))
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

    // MARK: - Google Drive "내 드라이브"

    private static let myDriveNames: Set<String> = ["My Drive", "내 드라이브"] // no-tr
    private static let addedKey = "autoAddedFavoritePaths"
    /// Spotlight로 찾은 미러링 폴더 (홈 바로 아래가 아닌 곳에 둔 경우)
    private var foundMyDrives: [URL] = []
    /// 찾은 내 드라이브 경로 → 보여 줄 이름 (즐겨찾기에서도 같은 이름으로)
    private var myDriveTitles: [String: String] = [:]
    @ObservationIgnored private var loggedMyDrives: [URL]?
    @ObservationIgnored private var searchedSpotlight = false

    /// Google Drive 데스크톱의 "내 드라이브" 폴더들.
    /// - 스트리밍(기본): ~/Library/CloudStorage/GoogleDrive-이메일/내 드라이브
    /// - 미러링: 사용자가 고른 폴더 (기본 ~/My Drive). 이때 CloudStorage에는 공유 드라이브만 남는다.
    static func googleMyDrives(extra: [URL] = [], home: URL = Places.home) -> [(url: URL, title: String)] {
        let fm = FileManager.default
        func real(_ u: URL) -> URL { u.resolvingSymlinksInPath().standardizedFileURL }
        func isDir(_ u: URL) -> Bool {
            var d: ObjCBool = false
            return fm.fileExists(atPath: real(u).path, isDirectory: &d) && d.boolValue
        }
        func isMyDrive(_ u: URL) -> Bool {
            myDriveNames.contains(u.lastPathComponent) || myDriveNames.contains(fm.displayName(atPath: u.path))
        }
        func hasVisibleItems(_ u: URL) -> Bool {
            ((try? fm.contentsOfDirectory(atPath: real(u).path)) ?? []).contains { !$0.hasPrefix(".") && $0 != "Icon\r" }
        }
        func email(of account: URL) -> String? {
            account.lastPathComponent.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init)
        }

        let cloudDir = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let accounts = ((try? fm.contentsOfDirectory(at: cloudDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.lowercased().hasPrefix("googledrive") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let accountPaths = Set(accounts.map { real($0).path })

        // 계정 폴더 안의 내 드라이브. 미러링이면 이것이 ~/My Drive를 가리키는 바로가기다.
        var streaming: [(URL, String)] = []
        for account in accounts {
            let children = (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? []
            for child in children where isMyDrive(child) && isDir(child) {
                streaming.append((real(child), email(of: account).map { tr("내 드라이브 (\($0))") } ?? tr("내 드라이브")))
            }
        }
        // 미러링: 홈 바로 아래(기본 위치)와 Spotlight로 찾은 곳
        var mirrored: [(URL, String)] = []
        let homeCandidates = ["My Drive", "내 드라이브", "Google Drive"].map { home.appendingPathComponent($0, isDirectory: true) } // no-tr
        for url in homeCandidates + extra where isDir(url) {
            let path = real(url).path
            if accountPaths.contains(path) { continue }   // ~/Google Drive → 계정 폴더 바로가기는 내 드라이브가 아님
            if (streaming + mirrored).contains(where: { $0.0.path == path }) { continue }
            mirrored.append((real(url), tr("내 드라이브")))
        }
        // 미러링인데 CloudStorage 쪽이 진짜 빈 폴더면 빼고, 계정 이름은 미러링 폴더에 붙인다
        if !mirrored.isEmpty {
            streaming.removeAll { !hasVisibleItems($0.0) }
            if streaming.isEmpty, mirrored.count == 1, accounts.count == 1, let mail = email(of: accounts[0]) {
                mirrored[0].1 = tr("내 드라이브 (\(mail))")
            }
        }
        return streaming + mirrored
    }

    /// 미러링 폴더를 홈 밖이나 깊은 곳에 둔 경우를 위해 Spotlight로 한 번 찾아본다 (뒤에서)
    func searchMyDrivesWithSpotlight() {
        guard !searchedSpotlight else { return }
        searchedSpotlight = true
        Task {
            let r = await Shell.run("/usr/bin/mdfind", ["-onlyin", Self.home.path,
                "(kMDItemFSName == 'My Drive' || kMDItemFSName == '내 드라이브') && kMDItemContentType == 'public.folder'"]) // no-tr
            let urls = r.stdout.split(separator: "\n").map { URL(fileURLWithPath: String($0), isDirectory: true) }
                .filter { !$0.path.contains("/Library/") && !$0.path.contains("/.Trash/") }
            guard !urls.isEmpty else { return }
            foundMyDrives = urls
            refreshLocations()
        }
    }

    /// 찾은 "내 드라이브"를 즐겨찾기에 한 번만 넣는다. 사용자가 빼면 다시 넣지 않는다.
    /// 예전에 자동으로 넣은 것 중 지금은 내 드라이브가 아닌 것(미러링이라 비어 있는 CloudStorage 쪽)은 뺀다.
    private func addMyDrivesToFavoritesOnce(_ urls: [URL]) {
        var added = Set(UserDefaults.standard.stringArray(forKey: Self.addedKey) ?? [])
        var changed = false
        let current = Set(urls.map(\.path))
        // 예전 버전이 자동으로 넣었지만 지금 찾은 내 드라이브가 아닌 것(바로가기·빈 폴더)은 뺀다
        for path in added where !current.contains(path) && !urls.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if isFavorite(url) {
                favorites.removeAll { $0.standardizedFileURL.path == url.standardizedFileURL.path }
                changed = true
                Log.info("app", "예전에 자동으로 넣은 즐겨찾기를 뺌 (실제 내 드라이브를 대신 씀): \(path)")
            }
        }
        for url in urls where !added.contains(url.path) {
            added.insert(url.path)
            if !isFavorite(url) {
                favorites.append(url)
                changed = true
                Log.info("app", "Google Drive 내 드라이브를 즐겨찾기에 추가: \(url.path)")
            }
        }
        UserDefaults.standard.set(Array(added), forKey: Self.addedKey)
        if changed { save() }
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
        // 계정 폴더 안의 내 드라이브는 이메일까지 보여서 여러 계정을 구분한다
        if myDriveNames.contains(url.lastPathComponent),
           let account = url.deletingLastPathComponent().lastPathComponent.split(separator: "-", maxSplits: 1).dropFirst().first,
           url.deletingLastPathComponent().lastPathComponent.lowercased().hasPrefix("googledrive") {
            return tr("내 드라이브 (\(account))")
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    static func icon(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        if myDriveNames.contains(url.lastPathComponent) { return "externaldrive.badge.icloud" }
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
                        resetLabel: tr("즐겨찾기 모두 지우기"), reset: clear)
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
