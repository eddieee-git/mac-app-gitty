import SwiftUI
import AppKit

/// 새 버전 알림 창
struct UpdateSheet: View {
    let release: Updater.Release
    @State private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Gitty \(release.version)이 나왔어요").font(.title3.bold())
                    Text("지금 쓰는 버전은 \(Updater.currentVersion)이에요.").foregroundStyle(.secondary)
                }
            }

            ScrollView {
                Text(Self.render(release.notes))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(height: 220)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))

            status

            HStack {
                Button("이 버전 건너뛰기") { updater.skip(release) }
                Link("릴리스 페이지", destination: release.pageURL)
                Spacer()
                Button("나중에") { updater.dismissOffer() }
                    .keyboardShortcut(.cancelAction)
                primaryButton
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder private var status: some View {
        switch updater.phase {
        case .downloading(let value):
            ProgressView(value: value) { Text("내려받는 중… \(Int(value * 100))%").font(.caption) }
        case .preparing:
            ProgressView { Text("설치 준비 중…").font(.caption) }
        case .opened:
            Text("dmg를 열었어요. Gitty를 종료한 뒤, 열린 창에서 Gitty를 응용 프로그램 폴더로 끌어다 놓아 덮어쓰세요.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        case .idle, .staged:
            EmptyView()
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch updater.phase {
        case .opened:
            Button("Gitty 종료") { NSApp.terminate(nil) }
                .keyboardShortcut(.defaultAction)
        case .staged:
            Button("다시 시작해서 설치") { updater.restartNow() }
                .keyboardShortcut(.defaultAction)
        case .downloading, .preparing:
            Button("내려받기") {}.disabled(true)
        case .idle, .failed:
            Button("내려받기") { Task { await updater.download(release, install: false) } }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// 릴리스 노트(마크다운)를 간단히 보여 준다. 제목(##)은 굵게.
    static func render(_ markdown: String) -> AttributedString {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        let text = lines.map { line -> String in
            let s = String(line)
            if let range = s.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                return "**\(s[range.upperBound...])**"
            }
            return s
        }.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(markdown)
    }
}

/// 업데이트 알림 창. 알릴 버전이 없으면(나중에·건너뛰기를 눌렀거나 지난번 창이 복원됐으면) 닫힌다.
struct UpdateWindow: View {
    @State private var updater = Updater.shared
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let offer = updater.offer {
                UpdateSheet(release: offer)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .onAppear { if updater.offer == nil { dismissWindow(id: "update") } }
        .onChange(of: updater.offer) { if updater.offer == nil { dismissWindow(id: "update") } }
        .onDisappear { if updater.offer != nil { updater.dismissOffer() } }   // 창을 닫으면 "나중에"
    }
}

/// 자동 설치로 받아 둔 업데이트가 있을 때 창 위쪽에 보이는 띠
struct UpdateBanner: View {
    @State private var updater = Updater.shared

    var body: some View {
        if let staged = updater.staged, updater.phase == .staged {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.app.fill").foregroundStyle(.tint)
                Text("Gitty \(staged.version)을 받아 뒀어요. 종료하면 설치돼요.")
                Spacer()
                Button("지금 다시 시작") { updater.restartNow() }
                    .controlSize(.small)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.tint.opacity(0.12))
        }
    }
}

struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("업데이트 확인…") {
                Task { await Updater.shared.check(manual: true) }
            }
        }
    }
}

/// 설정 창의 업데이트 항목
struct UpdateSettingsSection: View {
    @AppStorage(Updater.autoCheckKey) private var autoCheck = true
    @AppStorage(Updater.autoInstallKey) private var autoInstall = false
    @State private var updater = Updater.shared

    var body: some View {
        Section("업데이트") {
            LabeledContent("지금 버전") {
                HStack {
                    Text(Updater.currentVersion)
                    if updater.checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("지금 확인") { Task { await updater.check(manual: true) } }
                    }
                }
            }
            Toggle("자동으로 업데이트 확인", isOn: $autoCheck)
            Toggle("업데이트를 자동으로 설치", isOn: $autoInstall)
                .disabled(!autoCheck || !updater.canInstallInPlace)
            Text(installHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var installHint: String {
        if !updater.canInstallInPlace {
            return "지금 위치(\(Bundle.main.bundleURL.deletingLastPathComponent().path))에는 바로 설치할 수 없어서, 새 버전이 나오면 알려 주고 dmg를 내려받아 드려요."
        }
        var text = autoInstall
            ? "새 버전을 미리 받아 두었다가 Gitty를 종료할 때 설치해요."
            : "새 버전이 나오면 알려 주고, 원하면 dmg를 내려받아 드려요."
        if let last = updater.lastCheck {
            text += " 마지막 확인: \(last.formatted(date: .abbreviated, time: .shortened))"
        }
        return text
    }
}
