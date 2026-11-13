import SwiftUI
import AppKit

/// 설정 창 (⌘,)
struct SettingsView: View {
    static let autoSyncKey = "autoSyncMinutes"

    @AppStorage(autoSyncKey) private var autoSyncMinutes = 5
    @AppStorage(Log.fileLoggingKey) private var fileLogging = true
    @AppStorage(Loc.languageKey) private var language = "system"
    @AppStorage(GitRepo.lfsOnDemandKey) private var lfsOnDemand = false
    @State private var lfsVersion: String?
    @State private var checkedLFS = false

    var body: some View {
        Form {
            Section(tr("동기화")) {
                Picker(tr("자동 동기화"), selection: $autoSyncMinutes) {
                    Text(tr("끄기")).tag(0)
                    Text(tr("1분마다")).tag(1)
                    Text(tr("5분마다")).tag(5)
                    Text(tr("15분마다")).tag(15)
                    Text(tr("30분마다")).tag(30)
                }
                Text(tr("열려 있는 저장소의 원격을 확인해서, 다른 곳에서 올린 변경을 받아 오고 밀린 push를 보내요."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(tr("큰 파일 (Git LFS)")) {
                LabeledContent("git-lfs") {
                    if !checkedLFS {
                        ProgressView().controlSize(.small)
                    } else if let lfsVersion {
                        Label(lfsVersion, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label(tr("설치 안 됨"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                Text(lfsVersion == nil && checkedLFS
                     ? tr("100MB가 넘는 파일을 올리려면 터미널에서 brew install git-lfs 를 실행하세요.")
                     : tr("100MB가 넘는 파일은 자동으로 Git LFS로 올려요 (파일 하나 2GB까지). GitHub 무료 요금제의 LFS 용량은 1GB예요."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(tr("큰 파일은 열거나 복사할 때만 받기"), isOn: $lfsOnDemand)
                Text(tr("켜면 저장소를 열거나 동기화할 때 큰 파일(LFS)을 다 받지 않아 빠르고 디스크를 아껴요. 아직 받지 않은 파일은 목록에 구름 표시가 붙어요."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(tr("화면")) {
                Picker(tr("언어"), selection: $language) {
                    Text(tr("시스템 설정 따르기")).tag("system")
                    Text("한국어").tag("ko") // no-tr
                    Text("English").tag("en")
                }
                Text(tr("언어를 바꾸면 Gitty를 다시 열어야 적용돼요."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            UpdateSettingsSection()

            Section(tr("기록")) {
                Toggle(tr("작업 기록을 파일로 남기기"), isOn: $fileLogging)
                Text(fileLogging
                     ? tr("올리고 받은 파일 이름과 경로가 ~/Library/Logs/Gitty에 남아요. 문제가 생겼을 때 원인을 찾는 데 써요.")
                     : tr("파일에는 남기지 않아요. 창 아래 진행 로그에는 이번 실행 동안만 보여요."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent(tr("작업 기록 파일")) {
                    HStack {
                        Button(tr("Finder에서 보기")) {
                            NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
                        }
                        Button(tr("지우기"), role: .destructive) { Log.deleteFiles() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .task {
            let r = await Shell.run(Shell.gitPath, ["lfs", "version"])
            lfsVersion = r.status == 0 ? r.stdout.trimmed.components(separatedBy: " ").first : nil
            checkedLFS = true
        }
    }
}
