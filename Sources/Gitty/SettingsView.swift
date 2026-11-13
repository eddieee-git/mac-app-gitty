import SwiftUI
import AppKit

/// 설정 창 (⌘,)
struct SettingsView: View {
    static let autoSyncKey = "autoSyncMinutes"

    @AppStorage(autoSyncKey) private var autoSyncMinutes = 5
    @State private var lfsVersion: String?
    @State private var checkedLFS = false

    var body: some View {
        Form {
            Section("동기화") {
                Picker("자동 동기화", selection: $autoSyncMinutes) {
                    Text("끄기").tag(0)
                    Text("1분마다").tag(1)
                    Text("5분마다").tag(5)
                    Text("15분마다").tag(15)
                    Text("30분마다").tag(30)
                }
                Text("열려 있는 저장소의 원격을 확인해서, 다른 곳에서 올린 변경을 받아 오고 밀린 push를 보내요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("큰 파일 (Git LFS)") {
                LabeledContent("git-lfs") {
                    if !checkedLFS {
                        ProgressView().controlSize(.small)
                    } else if let lfsVersion {
                        Label(lfsVersion, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("설치 안 됨", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                Text(lfsVersion == nil && checkedLFS
                     ? "100MB가 넘는 파일을 올리려면 터미널에서 brew install git-lfs 를 실행하세요."
                     : "100MB가 넘는 파일은 자동으로 Git LFS로 올려요 (파일 하나 2GB까지). GitHub 무료 요금제의 LFS 용량은 1GB예요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            UpdateSettingsSection()

            Section("기록") {
                LabeledContent("작업 기록 파일") {
                    Button("Finder에서 보기") {
                        NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
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
