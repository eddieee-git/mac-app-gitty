import SwiftUI
import AppKit

@main
struct GittyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Gitty", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1320, height: 800)
        .commands { LogCommands() }

        Window("Gitty 작업 기록", id: "log") {
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
            Button("작업 기록 보기") { openWindow(id: "log") }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("로그 파일 Finder에서 보기") {
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.root == nil {
                WelcomeView()
            } else {
                BrowserView()
            }
        }
        .frame(minWidth: 880, minHeight: 520)
        .alert("오류", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("확인") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
