import SwiftUI

/// 파일 하나의 변경 기록. 지난 버전을 열어 보거나 그 버전으로 되돌린다.
struct HistorySheet: View {
    let item: FileItem
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [FileVersion]?
    @State private var selection: FileVersion.ID?
    @State private var confirmRestore: FileVersion?

    private var selected: FileVersion? { versions?.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading) {
                    Text(item.name).font(.title3.bold())
                    Text(tr("변경 기록 · 지난 버전을 열어 보거나 그 버전으로 되돌릴 수 있어요"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Group {
                if let versions {
                    if versions.isEmpty {
                        Text(tr("아직 커밋된 기록이 없어요."))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Table(versions, selection: $selection) {
                            TableColumn(tr("날짜")) { v in
                                HStack(spacing: 4) {
                                    Text(v.date.formatted(date: .abbreviated, time: .shortened))
                                    if v.id == versions.first?.id {
                                        Text(tr("지금")).font(.caption2).padding(.horizontal, 4)
                                            .background(.tint.opacity(0.2), in: Capsule())
                                    }
                                }
                            }
                            .width(min: 130, ideal: 150)
                            TableColumn(tr("내용")) { v in
                                Text(v.message).lineLimit(1).help(v.path == model.repoRelativePath(item.url) ? v.message : tr("\(v.message)\n(그때 이름: \(v.path))"))
                            }
                            TableColumn(tr("올린 사람")) { v in Text(v.author).foregroundStyle(.secondary) }
                                .width(min: 70, ideal: 100)
                        }
                        .contextMenu(forSelectionType: FileVersion.ID.self) { _ in } primaryAction: { ids in
                            if let v = versions.first(where: { ids.contains($0.id) }) { open(v) }
                        }
                    }
                } else {
                    ProgressView(tr("기록을 불러오는 중…")).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 300)

            HStack {
                Button(tr("이 버전 열기")) { if let selected { open(selected) } }
                    .disabled(selected == nil)
                    .help(tr("지금 파일은 그대로 두고, 그 버전을 임시 폴더에 꺼내서 열어요"))
                Button(tr("이 버전으로 되돌리기…")) { confirmRestore = selected }
                    .disabled(selected == nil || selected?.id == versions?.first?.id || model.isBusy)
                Spacer()
                Button(tr("닫기")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .task { versions = await model.history(of: item) }
        .confirmationDialog(tr("‘\(item.name)’을(를) 이 버전으로 되돌릴까요?"),
                            isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }),
                            presenting: confirmRestore) { version in
            Button(tr("되돌리기")) {
                Task {
                    await model.restore(item, to: version)
                    dismiss()
                }
            }
        } message: { version in
            Text(tr("\(version.date.formatted(date: .abbreviated, time: .shortened)) 버전 내용으로 바꿔서 커밋·push해요. 지금 내용도 기록에 남아서 다시 돌아올 수 있어요."))
        }
    }

    private func open(_ version: FileVersion) {
        Task { await model.openVersion(version, of: item) }
    }
}

/// 메뉴 명령이 지금 앞에 있는 창의 AppModel을 쓰도록
private struct AppModelKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelKey.self] }
        set { self[AppModelKey.self] = newValue }
    }
}

/// 편집 메뉴의 "Git 작업 되돌리기"
struct GitCommands: Commands {
    @FocusedValue(\.appModel) private var model

    var body: some Commands {
        CommandGroup(after: .undoRedo) {
            Button(model?.undoLabel.map { tr("Git 작업 되돌리기: \($0)") } ?? tr("Git 작업 되돌리기")) {
                Task { await model?.undoLast() }
            }
            .keyboardShortcut("z", modifiers: [.command, .option])
            .disabled(model?.undoLabel == nil || model?.isBusy == true)
        }
    }
}
