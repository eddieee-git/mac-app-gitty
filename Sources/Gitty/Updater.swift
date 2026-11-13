import Foundation
import AppKit
import Observation
import CryptoKit

/// GitHub 릴리스로 새 버전을 확인하고, 내려받거나 설치한다.
///
/// - 기본: 새 버전이 있으면 알려 주고, 원하면 dmg를 내려받아 열어 준다.
/// - 자동 설치(설정에서 켬): 새 버전을 미리 받아 두었다가 Gitty를 종료할 때 바꿔 끼운다.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    static let repo = "eddieee-git/mac-app-gitty"
    static let autoCheckKey = "autoCheckUpdates"
    static let autoInstallKey = "autoInstallUpdates"
    private static let skippedKey = "skippedUpdateVersion"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let checkInterval: TimeInterval = 6 * 60 * 60

    struct Release: Equatable, Identifiable {
        var id: String { version }
        let version: String
        let notes: String
        let dmgURL: URL
        /// dmg의 Ed25519 서명 (릴리스의 <dmg 이름>.sig)
        let signatureURL: URL
        let pageURL: URL
    }

    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case preparing
        /// dmg를 열어 둠 (직접 끌어다 놓아 설치)
        case opened(URL)
        /// 설치 준비 끝 (종료하거나 다시 시작하면 바뀜)
        case staged
        case failed(String)
    }

    /// 지금 보여 줄 새 버전 (업데이트 창)
    var offer: Release?
    /// 자동 설치로 받아 둔 버전
    private(set) var staged: Release?
    private(set) var phase: Phase = .idle
    private(set) var checking = false
    /// 직접 확인했을 때의 결과 ("최신 버전이에요" 등)
    var notice: String?
    private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: lastCheckKey) as? Date

    private var stagedApp: URL?
    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private var autoCheck: Bool { UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true }
    private var autoInstall: Bool { UserDefaults.standard.bool(forKey: Self.autoInstallKey) }

    private static var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gitty/Updates", isDirectory: true)
    }

    // MARK: - 확인

    /// 앱을 켜는 동안 자동으로 확인 (켜자마자, 그 뒤로 6시간마다)
    func startAutomaticChecks() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                if autoCheck { await check(manual: false) }
                try? await Task.sleep(for: .seconds(Self.checkInterval))
            }
        }
    }

    func check(manual: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let release = try await Self.fetchLatest()
            lastCheck = .now
            UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
            let current = Self.currentVersion
            guard Self.isNewer(release.version, than: current) else {
                Log.info("update", "최신 버전이에요 (지금 \(current), 릴리스 \(release.version))")
                if manual { notice = tr("지금 쓰는 \(current)가 최신 버전이에요.") }
                return
            }
            Log.info("update", "새 버전 \(release.version)이 있어요 (지금 \(current))")
            if staged == release { return }  // 이미 받아 둠
            if !manual, UserDefaults.standard.string(forKey: Self.skippedKey) == release.version { return }

            if autoInstall, canInstallInPlace, !manual {
                await download(release, install: true)
            } else {
                offer = release
            }
        } catch {
            Log.error("update", "업데이트 확인 실패: \(error.localizedDescription)")
            if manual { notice = tr("업데이트를 확인하지 못했어요.\n\(error.localizedDescription)") }
        }
    }

    /// 최신 릴리스 정보를 가져온다. GitHub API는 로그인 없이 한 시간에 60번(같은 네트워크 주소 기준)까지만 받아서,
    /// 회사처럼 여러 사람이 한 주소를 쓰면 403이 난다. 그러면 gh 로그인으로, 그것도 안 되면 릴리스 페이지에서 직접 알아낸다.
    /// 어느 길로 받든 dmg는 서명으로 확인하므로 안전하다.
    private static func fetchLatest() async throws -> Release {
        // 시험용으로 다른 주소를 쓸 수 있다 (defaults의 updateFeedURL)
        if let feed = UserDefaults.standard.string(forKey: "updateFeedURL").flatMap(URL.init(string:)) {
            return try await fetchViaAPI(feed)
        }
        var reasons: [String] = []
        do {
            return try await fetchViaAPI(URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        } catch {
            reasons.append("API: \(error.localizedDescription)")
        }
        do {
            let release = try await fetchViaGH()
            Log.info("update", "GitHub API가 막혀 gh 로그인으로 확인함 (\(reasons.joined()))")
            return release
        } catch {
            reasons.append("gh: \(error.localizedDescription)")
        }
        do {
            let release = try await fetchViaReleasePage()
            Log.info("update", "GitHub API가 막혀 릴리스 페이지로 확인함 (\(reasons.joined(separator: " · ")))")
            return release
        } catch {
            reasons.append("page: \(error.localizedDescription)")
        }
        Log.error("update", "업데이트 확인 실패: " + reasons.joined(separator: " · "))
        throw GittyError(message: tr("GitHub에서 업데이트 정보를 받지 못했어요. 잠시 뒤 다시 확인해 주세요."))
    }

    private struct Payload: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let body: String?
        let html_url: URL
        let assets: [Asset]
    }

    /// GitHub API (로그인 없이)
    static func fetchViaAPI(_ feed: URL) async throws -> Release {
        var request = URLRequest(url: feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Gitty/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let limited = http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
            throw GittyError(message: limited ? tr("GitHub 요청 한도에 걸렸어요 (응답 \(http.statusCode))") : tr("GitHub 응답 \(http.statusCode)"))
        }
        return try release(from: JSONDecoder().decode(Payload.self, from: data))
    }

    /// gh 로그인으로 (한 시간에 5000번까지)
    static func fetchViaGH() async throws -> Release {
        guard let gh = Shell.ghPath else { throw GittyError(message: "gh 없음") }
        let r = await Shell.run(gh, ["api", "repos/\(repo)/releases/latest"])
        guard r.status == 0, let data = r.stdout.data(using: .utf8) else { throw GittyError(message: r.errorText) }
        return try release(from: JSONDecoder().decode(Payload.self, from: data))
    }

    /// API 없이: github.com/…/releases/latest 가 최신 태그 페이지로 넘겨 주는 것으로 버전을 알아내고,
    /// 파일은 정해진 주소(releases/download/v버전/Gitty-버전.dmg)에서 받는다. 릴리스 노트는 없다.
    static func fetchViaReleasePage() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://github.com/\(repo)/releases/latest")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let final = response.url, let http = response as? HTTPURLResponse, http.statusCode == 200,
              final.path.contains("/releases/tag/") else {
            throw GittyError(message: "릴리스 페이지 응답 \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let tag = final.lastPathComponent
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let base = "https://github.com/\(repo)/releases/download/\(tag)/Gitty-\(version).dmg"
        return Release(version: version, notes: tr("릴리스 노트는 릴리스 페이지에서 볼 수 있어요."),
                       dmgURL: URL(string: base)!, signatureURL: URL(string: base + ".sig")!, pageURL: final)
    }

    private static func release(from payload: Payload) throws -> Release {
        guard let dmg = payload.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
            throw GittyError(message: tr("릴리스 \(payload.tag_name)에 dmg가 없어요"))
        }
        guard let signature = payload.assets.first(where: { $0.name == dmg.name + ".sig" }) else {
            throw GittyError(message: tr("릴리스 \(payload.tag_name)에 서명 파일이 없어서 받지 않아요"))
        }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return Release(version: version, notes: payload.body ?? "", dmgURL: dmg.browser_download_url,
                       signatureURL: signature.browser_download_url, pageURL: payload.html_url)
    }

    /// "0.1.10" > "0.1.9"
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - 사용자 선택

    func skip(_ release: Release) {
        UserDefaults.standard.set(release.version, forKey: Self.skippedKey)
        Log.info("update", "\(release.version) 건너뛰기")
        dismissOffer()
    }

    func dismissOffer() {
        downloadTask?.cancel()
        offer = nil
        if case .staged = phase { return }
        phase = .idle
    }

    /// 지금 앱이 있는 자리에 새 버전을 바로 넣을 수 있는지 (응용 프로그램 폴더 쓰기 권한 등)
    var canInstallInPlace: Bool {
        let app = Bundle.main.bundleURL
        let fm = FileManager.default
        return app.pathExtension == "app"
            && !app.path.hasPrefix("/Volumes/")
            && fm.isWritableFile(atPath: app.deletingLastPathComponent().path)
            && fm.isWritableFile(atPath: app.path)
    }

    // MARK: - 내려받기

    /// install == false: dmg를 받아서 열어 준다. true: 받은 앱을 설치 준비해 둔다.
    func download(_ release: Release, install: Bool) async {
        if case .downloading = phase { return }
        phase = .downloading(0)
        Log.info("update", "\(release.version) 내려받는 중: \(release.dmgURL.absoluteString)")
        do {
            let dmg = try await fetch(release)
            do {
                try await Self.verifySignature(of: dmg, release: release)
            } catch {
                try? FileManager.default.removeItem(at: dmg)
                throw error
            }
            Log.info("update", "\(release.version) 서명 확인 완료")
            if install {
                phase = .preparing
                stagedApp = try await Self.stage(dmg: dmg, version: release.version)
                staged = release
                phase = .staged
                Log.info("update", "\(release.version) 설치 준비 완료 · 종료하면 설치돼요")
            } else {
                NSWorkspace.shared.open(dmg)
                phase = .opened(dmg)
                Log.info("update", "dmg를 열었어요: \(dmg.path)")
            }
        } catch is CancellationError {
            phase = .idle
        } catch {
            if (error as? URLError)?.code == .cancelled { phase = .idle; return }
            Log.error("update", "업데이트 내려받기 실패: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    private func fetch(_ release: Release) async throws -> URL {
        let dir = Self.cacheDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("Gitty-\(release.version).dmg")
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: release.dmgURL) { location, response, error in
                if let error { continuation.resume(throwing: error); return }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    continuation.resume(throwing: GittyError(message: tr("내려받기 응답 \(http.statusCode)"))); return
                }
                guard let location else {
                    continuation.resume(throwing: GittyError(message: tr("내려받은 파일이 없어요"))); return
                }
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: location, to: dest)
                    continuation.resume(returning: dest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            progressObservation = task.progress.observe(\.fractionCompleted) { progress, _ in
                let value = progress.fractionCompleted
                Task { @MainActor in
                    if case .downloading = Updater.shared.phase { Updater.shared.phase = .downloading(value) }
                }
            }
            downloadTask = task
            task.resume()
        }
    }

    /// 이 앱에 들어 있는 공개 키로 dmg 서명을 확인한다. 서명 키는 릴리스하는 Mac의 키체인에만 있어서,
    /// GitHub 계정이나 릴리스가 털려도 가짜 dmg는 설치되지 않는다.
    nonisolated static var bundledPublicKey: Curve25519.Signing.PublicKey? {
        guard let keyText = Bundle.main.object(forInfoDictionaryKey: "GittyUpdatePublicKey") as? String,
              let keyData = Data(base64Encoded: keyText) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    }

    /// publicKey: 테스트용. 보통은 앱에 들어 있는 키.
    static func verifySignature(of dmg: URL, release: Release,
                                publicKey: Curve25519.Signing.PublicKey? = bundledPublicKey) async throws {
        guard let publicKey else {
            throw GittyError(message: tr("이 앱에는 업데이트 확인용 공개 키가 없어요"))
        }
        var request = URLRequest(url: release.signatureURL)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw GittyError(message: tr("서명 파일 응답 \(http.statusCode)"))
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: text) else {
            throw GittyError(message: tr("서명 파일 형식이 잘못됐어요"))
        }
        let content = try Data(contentsOf: dmg, options: .mappedIfSafe)
        guard publicKey.isValidSignature(signature, for: content) else {
            Log.error("update", "\(release.version) 서명이 맞지 않아 버림: \(release.dmgURL.absoluteString)")
            throw GittyError(message: tr("내려받은 파일의 서명이 맞지 않아요. 변조됐을 수 있어서 설치하지 않았어요."))
        }
    }

    /// dmg 안의 Gitty.app을 꺼내 캐시에 둔다 (확인: 같은 앱인지, 버전이 맞는지)
    private static func stage(dmg: URL, version: String) async throws -> URL {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appendingPathComponent("gitty-update-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = await Shell.run("/usr/bin/hdiutil",
                                     ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        guard attach.status == 0 else { throw GittyError(message: tr("dmg를 열 수 없어요: \(attach.errorText)")) }
        defer {
            Task.detached { _ = await Shell.run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
        }

        let source = mount.appendingPathComponent("Gitty.app")
        guard let info = NSDictionary(contentsOf: source.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw GittyError(message: tr("dmg 안에서 Gitty를 찾지 못했어요"))
        }
        guard info["CFBundleShortVersionString"] as? String == version else {
            throw GittyError(message: tr("dmg 안의 버전이 \(version)이 아니에요"))
        }

        let staged = cacheDir.appendingPathComponent("staged/Gitty.app")
        try? fm.removeItem(at: staged.deletingLastPathComponent())
        try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        let copy = await Shell.run("/usr/bin/ditto", [source.path, staged.path])
        guard copy.status == 0 else { throw GittyError(message: tr("앱을 복사하지 못했어요: \(copy.errorText)")) }
        let verify = await Shell.run("/usr/bin/codesign", ["--verify", "--deep", staged.path])
        guard verify.status == 0 else { throw GittyError(message: tr("새 앱의 서명을 확인하지 못했어요: \(verify.errorText)")) }
        return staged
    }

    // MARK: - 설치

    /// 설치 준비가 됐으면, 이 앱이 끝난 뒤 바꿔 끼우는 스크립트를 띄운다.
    func installStagedOnQuit(relaunch: Bool) {
        guard let stagedApp, let staged, FileManager.default.fileExists(atPath: stagedApp.path) else { return }
        let target = Bundle.main.bundleURL.path
        // no-tr: 셸 스크립트라 번역하지 않는다
        let script = """
        exec >>"$5" 2>&1
        log() { echo "$(date '+%Y-%m-%d %H:%M:%S.000') INFO [update] $1"; }
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.old"
        if mv "$2" "$2.old" && mv "$3" "$2"; then
          rm -rf "$2.old"
          /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
          log "설치 완료: $2"
        else
          rm -rf "$2"; mv "$2.old" "$2"
          log "설치 실패, 이전 버전으로 되돌림"
        fi
        if [ "$4" = 1 ]; then /usr/bin/open "$2"; fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "gitty-update", "\(ProcessInfo.processInfo.processIdentifier)",
                             target, stagedApp.path, relaunch ? "1" : "0", Log.fileURL.path]
        do {
            try process.run()
            Log.info("update", "\(staged.version) 설치 시작 (종료 후 바꿔 끼움\(relaunch ? ", 다시 시작" : ""))")
            self.stagedApp = nil
        } catch {
            Log.error("update", "설치를 시작하지 못했어요: \(error.localizedDescription)")
        }
    }

    func restartNow() {
        installStagedOnQuit(relaunch: true)
        NSApp.terminate(nil)
    }
}
