import SwiftUI
import AppKit

/// 왼쪽 내 폴더 | 오른쪽 Git 저장소 — 두 패널 사이로 끌어다 놓아 파일을 주고받는다.
struct BrowserView: View {
    @FocusState private var focusedPane: PaneID?
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showLogPanel") private var showLog = true
    @AppStorage(SettingsView.autoSyncKey) private var autoSyncMinutes = 5

    var body: some View {
        VStack(spacing: 0) {
            VSplitView {
                HSplitView {
                    LocalPaneView(focus: $focusedPane)
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    TransferBar()
                        .frame(minWidth: 40, maxWidth: 40)
                        // 좌우 패널 폭, 아래 진행 로그 높이를 기억
                        .splitAutosave("main.panes", vertical: true)
                        .splitAutosave("main.log", vertical: false)
                    RepoPaneView(focus: $focusedPane)
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
                    Label(tr("저장소 목록"), systemImage: "square.grid.2x2")
                }
                .help(tr("저장소 목록으로"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label(tr("동기화"), systemImage: "arrow.triangle.2.circlepath")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isBusy)
                .help(tr("Git 원격과 동기화 (⌘R)"))
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
                Button(tr("취소")) { model.cancelCurrent() }
                    .controlSize(.small)
                    .disabled(busy == tr("취소하는 중…"))
                    .help(tr("지금 하는 작업을 멈춰요. 커밋 전이면 원래대로 되돌려요."))
            } else {
                if model.pushPending {
                    Image(systemName: "icloud.and.arrow.up").foregroundStyle(.secondary)
                    Text(model.statusMessage + tr(" · 곧 GitHub에 올려요"))
                } else {
                    Image(systemName: model.unpushed > 0 ? "exclamationmark.icloud" : "checkmark.icloud")
                        .foregroundStyle(model.unpushed > 0 ? .orange : .green)
                    Text(model.statusMessage)
                }
            }
            Spacer()
            if let synced = model.lastSynced, !model.isBusy {
                Text(tr("동기화 \(synced.formatted(date: .omitted, time: .shortened))") + (autoSyncMinutes > 0 ? tr(" · \(autoSyncMinutes)분마다") : ""))
                    .foregroundStyle(.secondary)
                    .help(tr("⌘R로 지금 동기화 · 간격은 설정(⌘,)에서"))
            }
            if model.repoStatus.changedCount > 0 && !model.isBusy {
                Text(tr("저장소 폴더에서 고친 파일 \(model.repoStatus.changedCount)개")).foregroundStyle(.orange)
                    .help(model.repoStatus.changedPaths.prefix(15).joined(separator: "\n"))
                Button(tr("올리기")) { Task { await model.commitChanges() } }
                    .controlSize(.small)
            }
            if let undo = model.undoLabel, !model.isBusy {
                Button(tr("되돌리기")) { Task { await model.undoLast() } }
                    .controlSize(.small)
                    .help(tr("마지막 Git 작업 되돌리기: \(undo) (⌥⌘Z)"))
            }
            if model.unpushed > 0 && !model.isBusy && !model.pushPending {
                Text(tr("push 안 된 커밋 \(model.unpushed)개")).foregroundStyle(.orange)
                Button(tr("다시 시도")) { Task { await model.refresh() } }
                    .controlSize(.small)
            }
            Text(tr("가운데 화살표나 끌어다 놓기로 복사해요"))
                .foregroundStyle(.tertiary)
            Toggle(isOn: $showLog) {
                Label(tr("진행 로그"), systemImage: "text.alignleft")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(showLog ? tr("진행 로그 숨기기") : tr("진행 로그 보기"))
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
