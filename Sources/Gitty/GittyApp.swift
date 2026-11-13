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

        // 업데이트 알림은 시트가 아니라 따로 띄운다: 시트가 떠 있으면 macOS가 앱 종료(로그아웃·재시동 포함)를 막는다
        Window(tr("Gitty 업데이트"), id: "update") {
            UpdateWindow()
        }
        .windowResizability(.contentSize)

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
        Updater.shared.startAutomaticChecks()
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
        // 자동 설치로 받아 둔 새 버전이 있으면 종료 뒤에 바꿔 끼운다
        MainActor.assumeIsolated { Updater.shared.installStagedOnQuit(relaunch: false) }
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

    var body: some View {
        Group {
            if let model {
                ContentView()
                    .environment(model)
                    .focusedSceneValue(\.appModel, model)
            } else {
                Color.clear.frame(minWidth: 880, minHeight: 520)
            }
        }
        .onAppear { if model == nil { model = AppModel() } }
        .background(WindowTabbing())
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
    @State private var updater = Updater.shared
    @Environment(\.openWindow) private var openWindow

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
        .onChange(of: updater.offer) {
            if updater.offer != nil { openWindow(id: "update") }
        }
        .alert(tr("업데이트"), isPresented: Binding(
            get: { updater.notice != nil },
            set: { if !$0 { updater.notice = nil } })
        ) {
            Button(tr("확인")) {}
        } message: {
            Text(updater.notice ?? "")
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
