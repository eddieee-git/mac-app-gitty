import SwiftUI
import AppKit
import Quartz

@main
struct GittyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 창(탭)마다 저장소를 따로 연다. ⌘T로 새 탭, ⌘N으로 새 창.
        WindowGroup("Gitty", id: "main") {
            MainWindow()
        }
        .defaultSize(width: 1320, height: 800)
        .commands {
            UpdateCommands()
            TabCommands()
            GitCommands()
            LogCommands()
        }

        Window(tr("Gitty 작업 기록"), id: "log") {
            LogView()
        }
        .defaultSize(width: 820, height: 480)

        Settings {
            SettingsView()
        }
    }
}

struct LogCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button(tr("작업 기록 보기")) { openWindow(id: "log") }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button(tr("로그 파일 Finder에서 보기")) {
                NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        Log.info("app", "Gitty \(version) 시작 · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
                 + " · git \(FileManager.default.isExecutableFile(atPath: Shell.gitPath) ? "있음" : "없음")"
                 + " · gh \(Shell.ghPath ?? "없음")")
        // `swift run`으로 실행해도 일반 앱처럼 Dock/메뉴바에 나타나도록
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.global(qos: .utility).async { AppModel.cleanOldVersionFiles() }
        AppUpdater.shared.start()
    }

    /// 커밋해 두고 아직 올리지 않은 게 있으면 마저 올린 뒤 끝낸다
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let waiting = MainActor.assumeIsolated { AppModel.live.filter { $0.pushPending || $0.isBusy } }
        guard !waiting.isEmpty else { return .terminateNow }
        Log.info("app", "종료 전에 남은 작업을 마치는 중 (창 \(waiting.count)개)")
        Task { @MainActor in
            for model in waiting { await model.finishPendingWork() }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Quick Look 미리 보기 창이 응답 체인에서 데이터 소스를 찾을 때 여기까지 온다
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { QuickLook.shared.attach(panel) }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}

/// 창 하나 = 저장소 하나. 창마다 자기 AppModel을 가진다.
struct MainWindow: View {
    /// 창이 처음 나타날 때 한 번만 만든다 (@State 초기값은 SwiftUI가 여러 번 계산할 수 있어서)
    @State private var model: AppModel?
    /// 창(탭)마다 열어 둔 저장소와 폴더. 다시 켜면 macOS가 창을 되살리면서 이 값도 돌려준다.
    @SceneStorage("gitty.repo") private var savedRepo = ""
    @SceneStorage("gitty.repoPath") private var savedPath = ""
    /// 창을 되살리지 않는 설정이면 첫 창에서만 마지막으로 연 저장소를 연다 (새 탭은 빈 화면)
    @MainActor private static var restoredOnce = false
    private static let lastRepoKey = "lastOpenRepo"
    private static let lastPathKey = "lastOpenRepoPath"

    var body: some View {
        Group {
            if let model {
                ContentView()
                    .environment(model)
                    .focusedSceneValue(\.appModel, model)
                    .onChange(of: model.root) { remember(model) }
                    .onChange(of: model.path) { remember(model) }
            } else {
                Color.clear.frame(minWidth: 880, minHeight: 520)
            }
        }
        .onAppear {
            guard model == nil else { return }
            let m = AppModel()
            model = m
            restore(into: m)
        }
        .background(WindowTabbing())
    }

    private func restore(into model: AppModel) {
        var repo = savedRepo, path = savedPath
        if repo.isEmpty && !Self.restoredOnce {
            repo = UserDefaults.standard.string(forKey: Self.lastRepoKey) ?? ""
            path = UserDefaults.standard.string(forKey: Self.lastPathKey) ?? ""
        }
        Self.restoredOnce = true
        guard !repo.isEmpty, FileManager.default.fileExists(atPath: repo + "/.git") else { return }
        Log.info("repo", "지난번에 열어 둔 저장소 다시 열기: \(repo)" + (path.isEmpty ? "" : " /\(path)"))
        Task {
            await model.open(URL(fileURLWithPath: repo, isDirectory: true))
            guard model.root != nil, !path.isEmpty else { return }
            let parts = path.split(separator: "/").map(String.init)
            // 그사이 지워진 폴더면 남아 있는 위 폴더까지만
            model.path = parts
        }
    }

    /// 지금 연 저장소와 폴더를 기억한다. 저장소 목록으로 돌아가면 지운다(다음에 켤 때 목록부터).
    private func remember(_ model: AppModel) {
        savedRepo = model.root?.path ?? ""
        savedPath = model.root == nil ? "" : model.relativeDir
        UserDefaults.standard.set(savedRepo, forKey: Self.lastRepoKey)
        UserDefaults.standard.set(savedPath, forKey: Self.lastPathKey)
    }
}

/// 새 창을 지금 창의 탭으로 붙인다 (Finder처럼)
private struct WindowTabbing: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.tabbingMode = .preferred
            view.window?.tabbingIdentifier = "gitty.main"
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct TabCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(tr("새 탭")) { openWindow(id: "main") }
                .keyboardShortcut("t", modifiers: .command)
            Button(tr("새 창")) {
                // 탭으로 붙지 않게 잠시 끄고 연다
                let previous = NSWindow.allowsAutomaticWindowTabbing
                NSWindow.allowsAutomaticWindowTabbing = false
                openWindow(id: "main")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSWindow.allowsAutomaticWindowTabbing = previous }
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 0) {
            UpdateBanner()
            if model.root == nil {
                WelcomeView()
            } else {
                BrowserView()
            }
        }
        .frame(minWidth: 880, minHeight: 520)
        .alert(tr("알려 드려요"), isPresented: Binding(
            get: { model.infoMessage != nil },
            set: { if !$0 { model.infoMessage = nil } })
        ) {
            Button(tr("확인")) {}
        } message: {
            Text(model.infoMessage ?? "")
        }
        // 커밋 메시지 쓰기 (설정에서 켰을 때). 창을 닫으면 취소.
        .sheet(item: Binding(get: { model.messageRequest },
                             set: { if $0 == nil, let r = model.messageRequest { r.reply(nil) } })) { request in
            CommitMessageSheet(request: request)
        }
        .alert(tr("오류"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button(tr("확인")) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
