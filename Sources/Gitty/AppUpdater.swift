// 이 파일은 mac-app/shared/AppUpdater.swift가 원본이에요.
// 앱 저장소에서 직접 고치지 말고, 원본을 고친 뒤 mac-app/scripts/sync-shared.sh로 다섯 앱에 복사해요.

import AppKit
import CryptoKit
import SwiftUI

/// 다섯 앱이 함께 쓰는 업데이트.
///
/// - 자동 확인(기본 켬): 켠 지 15초 뒤, 그 뒤로 한 시간마다, 잠자기에서 깼을 때 "하루가 지났으면" GitHub에 물어요.
/// - 자동 설치(기본 켬): 새 버전을 찾으면 앱을 쓰고 있지 않을 때 알아서 받아 바꿔 넣고 다시 켜요.
/// - 직접 확인("업데이트 확인…")하거나 "새 버전 X 설치…"를 누르면 묻지 않고 바로 설치해요.
/// - 앱 안에서 설치할 수 없을 때(자동 설치를 껐거나, 바꿔 넣을 수 없는 위치이거나, 서명 없는 릴리스)만 창으로 알려요. 자동 확인은 버전마다 한 번만 알려요.
/// - 내려받은 dmg는 Ed25519 `.sig`와 GitHub SHA-256으로 확인하고, 바꿔 넣기 전에 번들 ID·버전·코드 서명도 확인해요.
/// - 받는 주소는 https GitHub만 허용해요.
/// - GitHub API가 막히면(403·429) 릴리스 페이지 주소로 최신 버전을 알아내요.
/// - 샌드박스 앱은 자기 자신을 바꿀 수 없어서, 확인한 dmg를 다운로드 폴더에 받아 열어 줘요(`.openDownloadedDMG`, 지금 쓰는 앱은 없어요).
@MainActor
final class AppUpdater: ObservableObject {

    // MARK: 설정

    enum SignatureFormat: Sendable {
        /// `.sig` = dmg 파일 전체에 대한 서명
        case dmg
        /// `.sig` = "<prefix>:<버전>:<dmg SHA-256>" 문자열에 대한 서명 (옛 Clocky가 쓰던 형식, 지금 쓰는 앱은 없어요)
        case versionedSHA256(prefix: String)
    }

    enum InstallMode: Sendable {
        /// 내려받아 확인한 뒤 지금 앱 자리에 바꿔 넣고 다시 켜요.
        case replaceInPlace
        /// 샌드박스 앱: 확인한 dmg를 다운로드 폴더에 두고 열어요. 끌어다 놓기는 사용자가 해요.
        case openDownloadedDMG
    }

    struct Config {
        /// "Gitty". dmg 안의 앱 이름이자 화면에 보이는 이름.
        var appName: String
        /// "eddieee-git/mac-app-peeky"
        var repo: String
        /// Ed25519 공개 키 (base64, 32바이트)
        var publicKey: String
        var signatureFormat: SignatureFormat = .dmg
        var installMode: InstallMode = .replaceInPlace
        /// 앱 화면이 영어인지. 업데이트 문구 언어를 앱 설정에 맞춰요.
        var isEnglish: () -> Bool
        /// 옛 버전에서 쓰던 "자동 확인" 설정 키. 사용자가 꺼 두었으면 그대로 따라요.
        var legacyAutoCheckKey: String? = nil
        /// 지금 다시 시작해도 되는지(알람이 울리는 중 등). false면 자동 설치를 다음 기회로 미뤄요.
        var canRestartNow: () -> Bool = { true }
        /// 업데이트로 다시 켜진 뒤 한 번 불려요(이전 버전). 권한 다시 확인 같은 일을 해요.
        var didUpdate: (String) -> Void = { _ in }
        var log: (String) -> Void = { _ in }
    }

    struct Release: Equatable, Sendable {
        let version: String
        let dmg: URL?
        let signature: URL?
        let sha256: String?
        let page: URL
        let notes: String
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(String)
        case failed(String)
    }

    static let autoCheckKey = "autoCheckUpdates"
    static let autoInstallKey = "autoInstallUpdates"
    static let lastCheckKey = "lastUpdateCheck"
    /// openDownloadedDMG로 받아 둔 dmg 경로. 새 버전으로 처음 켰을 때 정리하는 데 써요.
    static let downloadedKey = "downloadedUpdate"
    private static let updatedFromKey = "updatedFromVersion"
    static let checkInterval: TimeInterval = 86_400
    nonisolated static let maxDownloadBytes = 300 * 1024 * 1024

    let config: Config

    @Published private(set) var state: State = .idle { didSet { refreshMenuItems() } }
    @Published private(set) var lastCheck: Date?
    /// 방금 업데이트로 다시 켜졌으면 이전 버전.
    @Published private(set) var updatedFrom: String?

    @Published var autoCheck: Bool {
        didSet {
            UserDefaults.standard.set(autoCheck, forKey: Self.autoCheckKey)
            if autoCheck { checkIfDue() }
        }
    }
    @Published var autoInstall: Bool {
        didSet {
            UserDefaults.standard.set(autoInstall, forKey: Self.autoInstallKey)
            installIfAllowed()
        }
    }

    var currentVersion: String {
        #if DEBUG
        if let version = UserDefaults.standard.string(forKey: "debugAppVersion") { return version }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    var available: Release? { if case .available(let r) = state { return r } else { return nil } }
    var isBusy: Bool {
        switch state { case .checking, .installing: return true; default: return false }
    }
    /// 앱 안에서 바꿔 넣을 수 있는지. 샌드박스 앱이거나, dmg 안·격리된 위치에서 실행 중이면 안 돼요.
    var canInstallInPlace: Bool {
        if case .openDownloadedDMG = config.installMode { return false }
        return Self.canReplace(Bundle.main.bundleURL)
    }

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private let menuItems = NSHashTable<NSMenuItem>.weakObjects()

    init(_ config: Config) {
        self.config = config
        let defaults = UserDefaults.standard
        if let value = defaults.object(forKey: Self.autoCheckKey) as? Bool {
            autoCheck = value
        } else if let key = config.legacyAutoCheckKey, let value = defaults.object(forKey: key) as? Bool {
            autoCheck = value
        } else {
            autoCheck = true
        }
        autoInstall = defaults.object(forKey: Self.autoInstallKey) as? Bool ?? true
        lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    /// 앱이 켜질 때 메인 스레드에서 한 번 불러요.
    nonisolated func start() {
        MainActor.assumeIsolated { startOnMain() }
    }

    private func startOnMain() {
        announceIfUpdated()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkIfDue() }
        timer?.invalidate()
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkIfDue()
                self?.installIfAllowed()
            }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        // 앱을 쓰다가 다른 앱으로 넘어가면, 찾아 둔 새 버전을 그때 설치해요.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.installIfAllowed() }
        }
    }

    // MARK: 확인

    /// 자동 확인이 켜져 있고 마지막 확인에서 하루가 지났으면 조용히 확인해요.
    func checkIfDue() {
        guard autoCheck, !isBusy else { return }
        if let lastCheck, lastCheck <= Date(), Date().timeIntervalSince(lastCheck) < Self.checkInterval { return }
        Task { await check(userInitiated: false) }
    }

    /// "지금 확인" — 새 버전이 있으면 바로 설치하고, 없으면 최신이라고 창으로 알려요.
    func checkNow() {
        if let available { return installOrOffer(available) }
        guard !isBusy else { return }
        Task { await check(userInitiated: true) }
    }

    /// 메뉴 항목과 설정의 버튼이 부르는 것: 새 버전이 있으면 바로 설치하고, 없으면 지금 확인해요.
    @objc func menuAction() {
        if let available { installOrOffer(available) } else { checkNow() }
    }

    /// 앱 안에서 설치할 수 있는 릴리스인지(dmg와 서명이 있고, 지금 자리에서 바꿔 넣거나 받아 열 수 있음).
    private func canInstall(_ release: Release) -> Bool {
        guard release.dmg != nil, release.signature != nil else { return false }
        if case .openDownloadedDMG = config.installMode { return true }
        return Self.canReplace(Bundle.main.bundleURL)
    }

    /// 사용자가 직접 고른 설치: 할 수 있으면 묻지 않고 바로 하고, 할 수 없으면 까닭과 릴리스 페이지를 알려요.
    private func installOrOffer(_ release: Release) {
        if canInstall(release) {
            Task { await install(release, userInitiated: true) }
        } else {
            offer(release)
        }
    }

    /// 자동 확인에서 찾았지만 알아서 설치하지 않을 때: 그 버전은 한 번만 창으로 알려요.
    private func offerOnce(_ release: Release) {
        let key = "offeredUpdateVersion"
        guard UserDefaults.standard.string(forKey: key) != release.version else { return }
        UserDefaults.standard.set(release.version, forKey: key)
        offer(release)
    }

    private func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        let previous = state
        state = .checking
        do {
            let release = try await Self.fetchLatest(apiURL: apiURL, repo: config.repo, appName: config.appName)
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
            guard Self.isNewer(release.version, than: currentVersion) else {
                state = .upToDate
                if userInitiated { showUpToDate() }
                return
            }
            config.log("update: found \(release.version)")
            state = .available(release)
            if userInitiated {
                installOrOffer(release)
            } else if autoInstall, canInstallInPlace, canInstall(release) {
                installIfAllowed()   // 앱을 쓰는 중이면 한 시간마다 다시 봐요
            } else {
                offerOnce(release)
            }
        } catch {
            config.log("update check failed: \(error.localizedDescription)")
            // 자동 확인이 실패했을 때는 이미 찾아 둔 새 버전을 잃지 않게 해요. 한 시간 뒤 다시 시도해요.
            // 릴리스가 없거나 저장소가 비공개면 404예요. 고장이 아니라서 쉬운 말로 보여 줘요.
            let message = error.localizedDescription.contains("(404)")
                ? text("아직 내려받을 수 있는 버전이 없어요", "No version is available to download yet")
                : error.localizedDescription
            if !userInitiated, case .available = previous { state = previous } else { state = .failed(message) }
            if userInitiated { showError(text("업데이트를 확인하지 못했어요", "Couldn't check for updates"), error) }
        }
    }

    private var apiURL: URL {
        #if DEBUG
        if let text = UserDefaults.standard.string(forKey: "debugUpdateURL"), let url = URL(string: text) { return url }
        #endif
        return URL(string: "https://api.github.com/repos/\(config.repo)/releases/latest")!
    }

    private var publicKey: String {
        #if DEBUG
        if let key = UserDefaults.standard.string(forKey: "debugUpdatePublicKey") { return key }
        #endif
        return config.publicKey
    }

    /// 자동 설치는 앱을 쓰고 있지 않을 때(앞에 있지 않을 때)만 해요. 아니면 한 시간 뒤 다시 봐요.
    private func installIfAllowed() {
        guard autoInstall, let available, canInstallInPlace, !NSApp.isActive, config.canRestartNow() else { return }
        Task { await install(available, userInitiated: false) }
    }

    // MARK: 메뉴 항목

    /// 메뉴바 메뉴(또는 앱 메뉴)에 넣을 업데이트 항목. 상태에 따라 글자가 저절로 바뀌어요. 메인 스레드에서 불러요.
    nonisolated func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(menuAction), keyEquivalent: "")
        item.target = self
        MainActor.assumeIsolated {
            menuItems.add(item)
            refresh(item)
        }
        return item
    }

    var menuTitle: String {
        switch state {
        case .available(let r):
            return canInstallInPlace ? text("새 버전 %@ 설치…", "Install Version %@…", r.version)
                                     : text("새 버전 %@ 받기…", "Get Version %@…", r.version)
        case .installing(let v): return text("새 버전 %@ 내려받는 중…", "Downloading Version %@…", v)
        case .checking: return text("업데이트 확인하는 중…", "Checking for Updates…")
        default: return text("업데이트 확인…", "Check for Updates…")
        }
    }

    private func refreshMenuItems() { menuItems.allObjects.forEach(refresh) }

    private func refresh(_ item: NSMenuItem) {
        item.title = menuTitle
        item.isEnabled = !isBusy
        item.image = available == nil ? nil : NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
    }

    /// 설정 화면에 보일 상태 한 줄.
    var statusText: String {
        switch state {
        case .checking: return text("확인하는 중…", "Checking…")
        case .available(let r): return text("새 버전 %@가 있어요", "Version %@ is available", r.version)
        case .installing(let v): return text("%@ 내려받는 중…", "Downloading %@…", v)
        case .failed(let message): return message
        case .upToDate, .idle:
            if let updatedFrom, updatedFrom != currentVersion {
                return text("%@에서 %@로 업데이트했어요", "Updated from %@ to %@", updatedFrom, currentVersion)
            }
            guard let lastCheck else { return text("하루에 한 번 GitHub에서 새 버전을 확인해요", "Checks GitHub for a new version once a day") }
            let when = lastCheck.formatted(date: .abbreviated, time: .shortened)
            return text("최신 버전이에요 · 마지막 확인 %@", "Up to date · last checked %@", when)
        }
    }

    // MARK: 창

    private func offer(_ release: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = text("새 버전 %@ %@", "%@ %@ is available", config.appName, release.version)
        var info = text("지금 쓰는 버전은 %@예요.", "You have %@.", currentVersion)
        if !release.notes.isEmpty { info += "\n\n" + release.notes }
        let signed = release.dmg != nil && release.signature != nil
        let installable: Bool
        let actionTitle: String
        switch config.installMode {
        case .replaceInPlace:
            installable = signed && Self.canReplace(Bundle.main.bundleURL)
            actionTitle = text("설치하고 다시 시작", "Install and Relaunch")
            if signed && !installable {
                info += "\n\n" + text("%@를 응용 프로그램 폴더로 옮기면 앱 안에서 바로 설치할 수 있어요.",
                                      "Move %@ to the Applications folder to install updates from inside the app.", config.appName)
            }
        case .openDownloadedDMG:
            installable = signed
            actionTitle = text("내려받아 열기", "Download and Open")
        }
        if release.dmg != nil && !signed {
            info += "\n\n" + text("이 릴리스에는 서명 파일이 없어서 앱 안에서 받지 않아요.",
                                  "This release has no signature file, so it can't be downloaded from inside the app.")
        }
        alert.informativeText = info
        alert.addButton(withTitle: installable ? actionTitle : text("릴리스 페이지 열기", "Open Release Page"))
        alert.addButton(withTitle: text("나중에", "Later"))
        if installable { alert.addButton(withTitle: text("릴리스 페이지 열기", "Open Release Page")) }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if installable { Task { await install(release, userInitiated: true) } } else { NSWorkspace.shared.open(release.page) }
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(release.page)
        default:
            break
        }
    }

    private func showUpToDate() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = text("최신 버전이에요", "You're up to date")
        alert.informativeText = text("지금 쓰는 %@ %@가 가장 새 버전이에요.", "%@ %@ is the latest version.", config.appName, currentVersion)
        alert.runModal()
    }

    private func showError(_ title: String, _ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: text("릴리스 페이지 열기", "Open Release Page"))
        alert.addButton(withTitle: text("닫기", "Close"))
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(releasesPage) }
    }

    /// 받은 dmg를 연 뒤 할 일을 알려 줘요. 실행 중인 앱은 덮어쓸 수 없으므로 먼저 끝내요.
    private func explainDownloaded(_ file: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = text("새 %@를 열었어요", "Opened the new %@", config.appName)
        alert.informativeText = text("%@를 종료한 뒤, 열린 창에서 %@를 응용 프로그램 폴더로 끌어다 놓아 바꾸고 다시 여세요. 설정과 데이터는 그대로 남아요.\n\n받은 파일: %@",
                                     "Quit %@, drag %@ from the opened window into Applications to replace it, then open it again. Your settings and data stay.\n\nDownloaded file: %@",
                                     config.appName, config.appName, file.path)
        alert.addButton(withTitle: text("%@ 종료", "Quit %@", config.appName))
        alert.addButton(withTitle: text("나중에", "Later"))
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }

    var releasesPage: URL { URL(string: "https://github.com/\(config.repo)/releases/latest")! }

    // MARK: 설치

    private func install(_ release: Release, userInitiated: Bool) async {
        if case .installing = state { return }
        let previous = state
        state = .installing(release.version)
        config.log("update: installing \(release.version)")
        let name = config.appName, key = publicKey, format = config.signatureFormat
        let identifier = Bundle.main.bundleIdentifier ?? ""
        let t = Messages(english: config.isEnglish())
        do {
            switch config.installMode {
            case .replaceInPlace:
                let app = Bundle.main.bundleURL
                guard Self.canReplace(app) else {
                    throw Failure(t("이 위치에서는 바꿔 넣을 수 없어요. %@를 응용 프로그램 폴더로 옮겨 주세요.",
                                    "Can't replace the app here. Move %@ to the Applications folder.", name))
                }
                let staged = try await Task.detached(priority: .userInitiated) {
                    let dmg = try await Self.downloadVerified(release, publicKey: key, format: format, messages: t)
                    defer { try? FileManager.default.removeItem(at: dmg) }
                    return try Self.stage(dmg: dmg, release: release, appName: name, identifier: identifier,
                                          replacing: app, messages: t)
                }.value
                UserDefaults.standard.set(currentVersion, forKey: Self.updatedFromKey)
                Self.swapAndRelaunch(staged: staged.app, work: staged.work, destination: app)
            case .openDownloadedDMG:
                let file = try await Task.detached(priority: .userInitiated) {
                    let dmg = try await Self.downloadVerified(release, publicKey: key, format: format, messages: t)
                    return try Self.moveToDownloads(dmg, appName: name, version: release.version)
                }.value
                UserDefaults.standard.set(file.path, forKey: Self.downloadedKey)
                state = previous
                NSWorkspace.shared.open(file)
                explainDownloaded(file)
            }
        } catch {
            config.log("update failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            if userInitiated { showError(text("업데이트하지 못했어요", "Couldn't update"), error) }
        }
    }

    private func announceIfUpdated() {
        let defaults = UserDefaults.standard
        guard let from = defaults.string(forKey: Self.updatedFromKey) else { return }
        defaults.removeObject(forKey: Self.updatedFromKey)
        updatedFrom = from
        state = .upToDate
        config.log("update: updated from \(from) to \(currentVersion)")
        if from != currentVersion { config.didUpdate(from) }
    }

    // MARK: - 네트워크와 파일 (메인 스레드 밖)

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// 백그라운드 작업에서 쓰는 문구 (메인 액터 밖이라 미리 언어를 정해 넘겨요).
    struct Messages: Sendable {
        let english: Bool
        func callAsFunction(_ ko: String, _ en: String, _ args: CVarArg...) -> String {
            String(format: english ? en : ko, arguments: args)
        }
    }

    nonisolated static func fetchLatest(apiURL: URL, repo: String, appName: String) async throws -> Release {
        var request = URLRequest(url: apiURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(appName, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200:
            guard let release = parse(data, appName: appName) else { throw Failure("GitHub response unreadable") }
            return release
        case 403, 429:
            // 로그인 없이 묻는 요청은 같은 네트워크 주소에서 한 시간에 60번까지만 받아 줘요(회사 네트워크).
            return try await fetchFromReleasePage(repo: repo, appName: appName)
        case 404:
            throw Failure("No releases yet (404)")
        default:
            throw Failure("GitHub HTTP \(code)")
        }
    }

    /// API 대신 github.com/…/releases/latest가 넘겨주는 주소(…/tag/vX.Y.Z)에서 버전을 알아내요.
    nonisolated static func fetchFromReleasePage(repo: String, appName: String) async throws -> Release {
        var request = URLRequest(url: URL(string: "https://github.com/\(repo)/releases/latest")!, timeoutInterval: 20)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let final = response.url, final.path.contains("/releases/tag/") else { throw Failure("GitHub release page unreadable") }
        let tag = final.lastPathComponent
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let base = "https://github.com/\(repo)/releases/download/\(tag)/\(appName)-\(version).dmg"
        return Release(version: version, dmg: URL(string: base), signature: URL(string: base + ".sig"),
                       sha256: nil, page: final, notes: "")
    }

    /// GitHub 릴리스 응답에서 버전, dmg와 그 `.sig`, SHA-256, 노트 앞부분을 읽어요.
    /// dmg는 `<앱>-<버전>.dmg`를 먼저, 없으면 `.sig`가 함께 있는 첫 dmg를 골라요.
    nonisolated static func parse(_ data: Data, appName: String) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        let assets = (json["assets"] as? [[String: Any]] ?? []).filter { $0["name"] is String }
        func name(_ asset: [String: Any]) -> String { asset["name"] as? String ?? "" }
        func asset(_ wanted: String) -> [String: Any]? { assets.first { name($0) == wanted } }
        let dmgs = assets.filter { name($0).lowercased().hasSuffix(".dmg") }
        let dmg = asset("\(appName)-\(version).dmg")
            ?? dmgs.first { asset(name($0) + ".sig") != nil }
            ?? dmgs.first
        let sig = dmg.flatMap { asset(name($0) + ".sig") }
        var sha: String?
        if let digest = dmg?["digest"] as? String, digest.hasPrefix("sha256:") { sha = String(digest.dropFirst(7)).lowercased() }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com")!
        return Release(version: version,
                       dmg: (dmg?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                       signature: (sig?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                       sha256: sha, page: page, notes: shortNotes(json["body"] as? String ?? ""))
    }

    /// 릴리스 노트의 첫 문단만, 마크다운 기호를 빼고 (알림 창에 넣을 만큼).
    nonisolated static func shortNotes(_ body: String) -> String {
        let paragraphs = body.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n\n")
        let first = paragraphs.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        var text = first.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        while text.hasPrefix("#") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }

    /// "0.10.0"이 "0.9.1"보다 새 것이라고 판단하도록 숫자 단위로 비교해요. "-beta" 같은 꼬리는 무시해요.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            let core = text.split(separator: "-").first.map(String.init) ?? text
            return core.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// 받는 주소는 https GitHub만 (DEBUG에서는 이 Mac 안의 시험 서버도).
    nonisolated static func isAllowedDownload(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased() else { return false }
        #if DEBUG
        if (scheme == "http" || scheme == "https") && (host == "localhost" || host == "127.0.0.1") { return true }
        #endif
        return scheme == "https" && (host == "github.com" || host.hasSuffix(".githubusercontent.com"))
    }

    nonisolated static func canReplace(_ app: URL) -> Bool {
        let fm = FileManager.default
        let path = app.standardizedFileURL.path
        return path.hasSuffix(".app") && !path.hasPrefix("/Volumes/") && !path.contains("/AppTranslocation/")
            && fm.isWritableFile(atPath: app.deletingLastPathComponent().path)
            && fm.isWritableFile(atPath: path)
    }

    /// `.sig` 내용(base64)이 맞는 서명인지.
    nonisolated static func isSigned(dmg: Data, sha256: String, version: String, signature: Data,
                                     publicKey: String, format: SignatureFormat) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let raw = Data(base64Encoded: String(decoding: signature, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        switch format {
        case .dmg: return key.isValidSignature(raw, for: dmg)
        case .versionedSHA256(let prefix): return key.isValidSignature(raw, for: Data("\(prefix):\(version):\(sha256)".utf8))
        }
    }

    nonisolated static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// dmg와 `.sig`를 받아 SHA-256과 서명을 확인해요. 확인한 dmg의 임시 위치를 돌려줘요.
    nonisolated private static func downloadVerified(_ release: Release, publicKey: String, format: SignatureFormat,
                                                     messages t: Messages) async throws -> URL {
        guard let dmgURL = release.dmg, let signatureURL = release.signature else {
            throw Failure(t("이 릴리스에는 자동으로 설치할 파일이 없어요.", "This release has no file that can be installed automatically."))
        }
        guard isAllowedDownload(dmgURL), isAllowedDownload(signatureURL) else {
            throw Failure(t("받는 주소가 GitHub가 아니에요.", "The download address isn't GitHub."))
        }
        let (signature, sigResponse) = try await URLSession.shared.data(from: signatureURL)
        if let http = sigResponse as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure(t("서명 파일을 내려받지 못했어요 (HTTP %ld)", "Couldn't download the signature (HTTP %ld)", http.statusCode))
        }
        let (downloaded, response) = try await URLSession.shared.download(from: dmgURL)
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString).dmg")
        try fm.moveItem(at: downloaded, to: file)
        var ok = false
        defer { if !ok { try? fm.removeItem(at: file) } }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure(t("내려받지 못했어요 (HTTP %ld)", "Download failed (HTTP %ld)", http.statusCode))
        }
        if let final = response.url, !isAllowedDownload(final) {
            throw Failure(t("받는 주소가 GitHub가 아니에요.", "The download address isn't GitHub."))
        }
        let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size > 0, size <= maxDownloadBytes else {
            throw Failure(t("내려받은 파일 크기가 이상해요. 설치하지 않았어요.", "The downloaded file has an unexpected size. Nothing was installed."))
        }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let actual = sha256(of: data)
        if let expected = release.sha256, actual != expected {
            throw Failure(t("내려받은 파일이 릴리스와 달라요. 설치하지 않았어요.", "The download doesn't match the release. Nothing was installed."))
        }
        guard isSigned(dmg: data, sha256: actual, version: release.version, signature: signature,
                       publicKey: publicKey, format: format) else {
            throw Failure(t("업데이트 서명이 맞지 않아요. 설치하지 않았어요.", "The update signature doesn't match. Nothing was installed."))
        }
        ok = true
        return file
    }

    /// 확인한 dmg에서 새 앱을 꺼내, 지금 앱과 같은 디스크의 작업 폴더에 둬요.
    nonisolated private static func stage(dmg: URL, release: Release, appName: String, identifier: String,
                                          replacing app: URL, messages t: Messages) throws -> (app: URL, work: URL) {
        let fm = FileManager.default
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        var success = false
        defer { if !success { try? fm.removeItem(at: work) } }
        let mount = work.appendingPathComponent("mnt")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-quiet", "-mountpoint", mount.path],
                failure: t("dmg를 열지 못했어요.", "Couldn't open the dmg."))
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"], failure: "") }

        let new = mount.appendingPathComponent("\(appName).app")
        let info = NSDictionary(contentsOf: new.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == identifier,
              info?["CFBundleShortVersionString"] as? String == release.version else {
            throw Failure(t("dmg 안의 앱이 %@ %@가 아니에요.", "The app in the dmg isn't %@ %@.", appName, release.version))
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=identifier \"\(identifier)\"", new.path],
                failure: t("새 앱의 코드 서명을 확인하지 못했어요.", "Couldn't verify the new app's code signature."))

        let staged = work.appendingPathComponent("\(appName).app")
        try run("/usr/bin/ditto", [new.path, staged.path], failure: t("새 앱을 복사하지 못했어요.", "Couldn't copy the new app."))
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path], failure: "")
        success = true
        return (staged, work)
    }

    /// 확인한 dmg를 다운로드 폴더에 "<앱> <버전>.dmg"로 옮겨요. 같은 이름이 있으면 번호를 붙여요.
    nonisolated private static func moveToDownloads(_ dmg: URL, appName: String, version: String, folder: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let folder = folder ?? fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var target = folder.appendingPathComponent("\(appName) \(version).dmg")
        var number = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(appName) \(version) (\(number)).dmg")
            number += 1
        }
        try fm.moveItem(at: dmg, to: target)
        return target
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String], failure: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw Failure(failure) }
    }

    /// 앱이 끝나기를 기다렸다가 옛 앱을 치우고 새 앱을 놓은 뒤 열어요. 옮기다 실패하면 옛 앱을 되돌려요.
    private static func swapAndRelaunch(staged: URL, work: URL, destination: URL) {
        let script = """
        while kill -0 "$0" 2>/dev/null; do sleep 0.2; done
        backup="$3/previous.app"
        if /bin/mv "$2" "$backup"; then
            if /bin/mv "$1" "$2"; then /bin/rm -rf "$3"; else /bin/mv "$backup" "$2"; fi
        fi
        /usr/bin/open "$2"
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, String(ProcessInfo.processInfo.processIdentifier),
                          staged.path, destination.standardizedFileURL.path, work.path]
        do {
            try task.run()
        } catch {
            try? FileManager.default.removeItem(at: work)
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: 자체 점검

    /// 각 앱의 test가 불러요. 실패한 항목 이름을 돌려줘요(비어 있으면 통과).
    nonisolated static func selfTest(appName: String, publicKey: String, format: SignatureFormat) -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ name: String) { if !ok { failures.append(name) } }

        expect(isNewer("0.10.0", than: "0.9.1"), "0.10.0 > 0.9.1")
        expect(isNewer("1.0", than: "0.9.9"), "1.0 > 0.9.9")
        expect(!isNewer("0.1.0", than: "0.1"), "0.1.0 == 0.1")
        expect(!isNewer("0.1.0", than: "0.2.0"), "0.1.0 < 0.2.0")
        expect(!isNewer("0.3.0-beta", than: "0.3.0"), "꼬리 무시")

        let json = """
        {"tag_name":"v0.9.0","html_url":"https://github.com/x/y/releases/tag/v0.9.0","body":"## **첫** 문단\\n\\n둘째 문단","assets":[
          {"name":"\(appName).dmg","browser_download_url":"https://github.com/x/y/releases/download/v0.9.0/\(appName).dmg"},
          {"name":"\(appName)-0.9.0.dmg","browser_download_url":"https://github.com/x/y/releases/download/v0.9.0/\(appName)-0.9.0.dmg","digest":"sha256:ABC"},
          {"name":"\(appName)-0.9.0.dmg.sig","browser_download_url":"https://github.com/x/y/releases/download/v0.9.0/\(appName)-0.9.0.dmg.sig"}]}
        """
        let release = parse(Data(json.utf8), appName: appName)
        expect(release?.version == "0.9.0", "태그에서 v를 뗀 버전")
        expect(release?.dmg?.lastPathComponent == "\(appName)-0.9.0.dmg", "버전 붙은 dmg를 먼저")
        expect(release?.signature?.lastPathComponent == "\(appName)-0.9.0.dmg.sig", "서명 파일 주소")
        expect(release?.sha256 == "abc", "SHA-256 소문자")
        expect(release?.notes == "첫 문단", "릴리스 노트 첫 문단, 기호 없이")
        expect(parse(Data(#"{"tag_name":"v1.0"}"#.utf8), appName: appName)?.dmg == nil, "dmg 없는 릴리스")

        expect(isAllowedDownload(URL(string: "https://github.com/a/b/releases/download/v1/x.dmg")!), "github.com 허용")
        expect(isAllowedDownload(URL(string: "https://release-assets.githubusercontent.com/x")!), "githubusercontent 허용")
        expect(!isAllowedDownload(URL(string: "http://github.com/a.dmg")!), "http 거부")
        expect(!isAllowedDownload(URL(string: "https://github.com.evil.example/a.dmg")!), "비슷한 주소 거부")
        expect(!isAllowedDownload(URL(string: "https://evilgithubusercontent.com/a.dmg")!), "점 없는 꼬리 거부")

        let key = Curve25519.Signing.PrivateKey()
        let testKey = key.publicKey.rawRepresentation.base64EncodedString()
        let dmg = Data("dmg".utf8), sha = sha256(of: dmg)
        for f in [SignatureFormat.dmg, .versionedSHA256(prefix: "test-release")] {
            let message: Data
            switch f {
            case .dmg: message = dmg
            case .versionedSHA256(let prefix): message = Data("\(prefix):0.9.0:\(sha)".utf8)
            }
            let sig = Data(((try? key.signature(for: message)) ?? Data()).base64EncodedString().utf8)
            expect(isSigned(dmg: dmg, sha256: sha, version: "0.9.0", signature: sig, publicKey: testKey, format: f), "맞는 서명 통과")
            expect(!isSigned(dmg: Data("x".utf8), sha256: sha256(of: Data("x".utf8)), version: "0.9.0", signature: sig,
                             publicKey: testKey, format: f), "다른 파일 거부")
            expect(!isSigned(dmg: dmg, sha256: sha, version: "0.9.0", signature: sig, publicKey: publicKey, format: f), "다른 키 거부")
            expect(!isSigned(dmg: dmg, sha256: sha, version: "0.9.0", signature: Data("not base64".utf8),
                             publicKey: testKey, format: f), "깨진 서명 거부")
        }
        if case .versionedSHA256(let prefix) = SignatureFormat.versionedSHA256(prefix: "test-release") {
            let sig = Data(((try? key.signature(for: Data("\(prefix):0.2.9:\(sha)".utf8))) ?? Data()).base64EncodedString().utf8)
            expect(!isSigned(dmg: dmg, sha256: sha, version: "0.9.0", signature: sig, publicKey: testKey,
                             format: .versionedSHA256(prefix: prefix)), "옛 버전 서명을 새 버전에 붙이면 거부")
        }
        expect(Data(base64Encoded: publicKey)?.count == 32, "앱에 넣은 공개 키 형식")
        expect(!canReplace(URL(fileURLWithPath: "/Volumes/\(appName)/\(appName).app")), "dmg 안에서는 바꿔 넣지 않음")
        return failures
    }

    // MARK: 문구

    func text(_ ko: String, _ en: String, _ args: CVarArg...) -> String {
        String(format: config.isEnglish() ? en : ko, arguments: args)
    }
}

/// 설정 창에 그대로 넣는 업데이트 섹션.
struct AppUpdaterSection: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Section(updater.text("업데이트", "Updates")) {
            Toggle(updater.text("새 버전 자동으로 확인", "Check for new versions automatically"), isOn: $updater.autoCheck)
            if case .replaceInPlace = updater.config.installMode {
                Toggle(updater.text("새 버전 자동으로 설치", "Install new versions automatically"), isOn: $updater.autoInstall)
                    .disabled(!updater.autoCheck || !updater.canInstallInPlace)
            }
            HStack {
                Text(updater.statusText)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button(updater.available == nil ? updater.text("지금 확인", "Check Now")
                : (updater.canInstallInPlace ? updater.text("설치", "Install") : updater.text("받기…", "Get…"))) {
                    updater.menuAction()
                }
                .disabled(updater.isBusy)
            }
            Text(updater.text("버전 %@ · GitHub에 최신 버전 번호만 물어봐요.", "Version %@ · Only asks GitHub for the latest version number.", updater.currentVersion))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
