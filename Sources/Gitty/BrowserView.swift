import SwiftUI
import AppKit

/// 왼쪽 내 폴더 | 오른쪽 Git 저장소 — 두 패널 사이로 끌어다 놓아 파일을 주고받는다.
struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showLogPanel") private var showLog = true
    @AppStorage(SettingsView.autoSyncKey) private var autoSyncMinutes = 5

    var body: some View {
        VStack(spacing: 0) {
            VSplitView {
                HSplitView {
                    LocalPaneView()
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    RepoPaneView()
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minHeight: 260, maxHeight: .infinity)
                if showLog {
                    LogPanel()
                        .frame(minHeight: 90, idealHeight: 170, maxHeight: .infinity)
                }
            }
            Divider()
            statusBar
        }
        .overlay {
            if let conflicts = model.conflicts, !model.isBusy {
                ConflictPanel(files: conflicts)
            }
        }
        .navigationTitle(model.repoName)
        // 자동 동기화: 간격이 바뀌면 새로 시작
        .task(id: autoSyncMinutes) {
            guard autoSyncMinutes > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(autoSyncMinutes * 60))
                if Task.isCancelled { break }
                await model.autoSync()
            }
        }
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
                if let p = model.progress, let fraction = p.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 140)
                    Text("\(p.phase) \(Int(fraction * 100))%")
                        .monospacedDigit()
                    if !p.detail.isEmpty {
                        Text(p.detail).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    ProgressView().controlSize(.small)
                    Text(model.progress?.phase ?? busy)
                }
            } else {
                if model.pushPending {
                    Image(systemName: "icloud.and.arrow.up").foregroundStyle(.secondary)
                    Text(model.statusMessage + " · 곧 GitHub에 올려요")
                } else {
                    Image(systemName: model.unpushed > 0 ? "exclamationmark.icloud" : "checkmark.icloud")
                        .foregroundStyle(model.unpushed > 0 ? .orange : .green)
                    Text(model.statusMessage)
                }
            }
            Spacer()
            if let synced = model.lastSynced, !model.isBusy {
                Text("동기화 \(synced.formatted(date: .omitted, time: .shortened))" + (autoSyncMinutes > 0 ? " · \(autoSyncMinutes)분마다" : ""))
                    .foregroundStyle(.secondary)
                    .help("⌘R로 지금 동기화 · 간격은 설정(⌘,)에서")
            }
            if let undo = model.undoLabel, !model.isBusy {
                Button("되돌리기") { Task { await model.undoLast() } }
                    .controlSize(.small)
                    .help("마지막 Git 작업 되돌리기: \(undo) (⌥⌘Z)")
            }
            if model.unpushed > 0 && !model.isBusy && !model.pushPending {
                Text("push 안 된 커밋 \(model.unpushed)개").foregroundStyle(.orange)
                Button("다시 시도") { Task { await model.refresh() } }
                    .controlSize(.small)
            }
            Text("항목을 끌어서 반대쪽 패널에 놓으면 복사됩니다")
                .foregroundStyle(.tertiary)
            Toggle(isOn: $showLog) {
                Label("진행 로그", systemImage: "text.alignleft")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(showLog ? "진행 로그 숨기기" : "진행 로그 보기")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
