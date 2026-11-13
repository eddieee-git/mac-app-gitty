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
        .defaultSize(width: 1200, height: 700)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
        .frame(minWidth: 780, minHeight: 460)
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
