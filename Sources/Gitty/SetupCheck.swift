import SwiftUI
import AppKit

/// 처음 쓸 때 필요한 것(git, GitHub CLI 로그인, Git LFS)이 준비됐는지 확인한다.
struct SetupStatus: Equatable {
    var git = false
    var gh = false
    var ghLoggedIn = false
    var lfs = false

    var ready: Bool { git && gh && ghLoggedIn }

    static func check() async -> SetupStatus {
        var s = SetupStatus()
        // Command Line Tools가 없을 때 /usr/bin/git을 바로 부르면 설치 창이 떠서, 먼저 확인한다
        if await Shell.run("/usr/bin/xcode-select", ["-p"]).status == 0 {
            s.git = await Shell.run(Shell.gitPath, ["--version"]).status == 0
        }
        if let gh = Shell.ghPath {
            s.gh = true
            s.ghLoggedIn = await Shell.run(gh, ["auth", "status", "--hostname", "github.com"]).status == 0
        }
        if s.git {
            s.lfs = await Shell.run(Shell.gitPath, ["lfs", "version"]).status == 0
        }
        Log.info("app", "준비 상태: git \(s.git ? "있음" : "없음") · gh \(s.gh ? (s.ghLoggedIn ? "로그인됨" : "로그인 안 됨") : "없음") · git-lfs \(s.lfs ? "있음" : "없음")")
        return s
    }
}

/// 준비가 안 된 것이 있을 때 첫 화면에 보이는 안내
struct SetupCard: View {
    let status: SetupStatus
    let recheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("시작하기 전에 준비할 것이 있어요", systemImage: "wrench.and.screwdriver")
                .font(.headline)
            row(ok: status.git, title: "git (Command Line Tools)",
                hint: "터미널에서 실행한 뒤 나오는 창에서 설치를 누르세요.", command: "xcode-select --install")
            row(ok: status.gh, title: "GitHub CLI",
                hint: "Homebrew로 설치해요.", command: "brew install gh")
            if status.gh {
                row(ok: status.ghLoggedIn, title: "GitHub 로그인",
                    hint: "터미널에서 실행하고 안내대로 브라우저에서 로그인하세요.", command: "gh auth login")
            }
            row(ok: status.lfs, title: "Git LFS (선택)",
                hint: "100MB가 넘는 파일을 올릴 때만 필요해요.", command: "brew install git-lfs", optional: true)
            HStack {
                Button("터미널 열기") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                }
                Spacer()
                Button("다시 확인", action: recheck)
            }
        }
        .padding(14)
        .frame(maxWidth: 520)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.3)))
    }

    private func row(ok: Bool, title: String, hint: String, command: String, optional: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : (optional ? "minus.circle" : "exclamationmark.circle.fill"))
                .foregroundStyle(ok ? .green : (optional ? .secondary : .orange))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                if !ok {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("명령 복사")
                    }
                }
            }
        }
    }
}
