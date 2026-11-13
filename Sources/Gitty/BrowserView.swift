import SwiftUI
import AppKit

/// 왼쪽 내 폴더 | 오른쪽 Git 저장소 — 두 패널 사이로 끌어다 놓아 파일을 주고받는다.
struct BrowserView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                LocalPaneView()
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                RepoPaneView()
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            statusBar
        }
        .navigationTitle(model.repoName)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.close()
                } label: {
                    Label("저장소 목록", systemImage: "square.grid.2x2")
                }
                .help("저장소 목록으로")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("동기화", systemImage: "arrow.triangle.2.circlepath")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isBusy)
                .help("Git 원격과 동기화 (⌘R)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Finder 등 다른 곳에서 바뀐 내용을 반영
            model.local.reload()
            if !model.isBusy { model.reload() }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let busy = model.busyMessage {
                ProgressView().controlSize(.small)
                Text(busy)
            } else {
                Image(systemName: model.unpushed > 0 ? "exclamationmark.icloud" : "checkmark.icloud")
                    .foregroundStyle(model.unpushed > 0 ? .orange : .green)
                Text(model.statusMessage)
            }
            Spacer()
            if model.unpushed > 0 && !model.isBusy {
                Text("push 안 된 커밋 \(model.unpushed)개").foregroundStyle(.orange)
                Button("다시 시도") { Task { await model.refresh() } }
                    .controlSize(.small)
            }
            Text("항목을 끌어서 반대쪽 패널에 놓으면 복사됩니다")
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
