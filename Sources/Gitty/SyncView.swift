import SwiftUI

/// 폴더 맞추기 창: 지금 보고 있는 내 폴더와 Git 폴더를 비교해서 한쪽을 다른 쪽과 같게 만든다
struct SyncSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var direction: FolderSync.Direction = .toRepo
    @State private var plan: FolderSync.Plan?
    @State private var deleteExtra = false

    private var secrets: [String] {
        guard direction == .toRepo, let plan else { return [] }
        return (plan.added + plan.changed).filter { UploadSafety.isSensitive(($0 as NSString).lastPathComponent) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(tr("폴더 맞추기"), systemImage: "arrow.left.arrow.right.circle").font(.title3.bold())
            Picker("", selection: $direction) {
                Text(tr("내 폴더 → Git")).tag(FolderSync.Direction.toRepo)
                Text(tr("Git → 내 폴더")).tag(FolderSync.Direction.toLocal)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(direction == .toRepo ? tr("보내는 쪽: 내 폴더 · \(model.local.dir.lastPathComponent)") : tr("보내는 쪽: Git · /\(model.relativeDir)"))
                Text(direction == .toRepo ? tr("맞출 쪽: Git · /\(model.relativeDir)") : tr("맞출 쪽: 내 폴더 · \(model.local.dir.lastPathComponent)"))
            }
            .font(.callout).foregroundStyle(.secondary)

            Group {
                if let plan {
                    if plan.isEmpty {
                        Label(tr("두 폴더가 같아요. 맞출 게 없어요."), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            group(tr("새로 보낼 파일"), plan.added, "plus.circle.fill", .green)
                            group(tr("내용이 달라 덮어쓸 파일"), plan.changed, "pencil.circle.fill", .orange)
                            group(deleteExtra ? tr("지울 파일") : tr("맞출 쪽에만 있는 파일 (그대로 둠)"), plan.extra,
                                  deleteExtra ? "trash.circle.fill" : "minus.circle", deleteExtra ? .red : .secondary)
                        }
                        .listStyle(.bordered)
                    }
                } else {
                    ProgressView(tr("비교하는 중…")).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 260)

            if plan?.partial == true {
                Label(tr("파일이 너무 많아 일부만 비교했어요. 더 작은 폴더에서 맞춰 보세요."), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !secrets.isEmpty {
                Label(tr("비밀 정보가 들어 있을 수 있는 파일: \(secrets.prefix(3).joined(separator: ", "))\(secrets.count > 3 ? tr(" 외 \(secrets.count - 3)개") : ""). Git에 올라가면 지워도 기록에 남아요."),
                      systemImage: "exclamationmark.shield.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            Toggle(direction == .toRepo ? tr("Git 쪽에만 있는 파일은 지우기") : tr("내 폴더에만 있는 파일은 휴지통으로"), isOn: $deleteExtra)
                .disabled(plan?.extra.isEmpty ?? true)

            HStack {
                Text(direction == .toRepo ? tr("커밋·push까지 해요. 되돌리기(⌥⌘Z)로 되돌릴 수 있어요.") : tr("덮어쓰는 파일의 이전 내용은 휴지통으로 가요."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(secrets.isEmpty ? tr("맞추기") : tr("그래도 맞추기")) {
                    guard let plan else { return }
                    let dir = direction, del = deleteExtra
                    dismiss()
                    Task { await model.runSync(dir, plan: plan, deleteExtra: del) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan == nil || plan!.isEmpty || (plan!.added.isEmpty && plan!.changed.isEmpty && !deleteExtra))
            }
        }
        .padding(20)
        .frame(width: 560)
        .task(id: direction) {
            plan = nil
            plan = await model.syncPlan(direction)
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ paths: [String], _ icon: String, _ color: Color) -> some View {
        if !paths.isEmpty {
            Section(tr("\(title) \(paths.count)개")) {
                ForEach(paths.prefix(200), id: \.self) { path in
                    Label(path, systemImage: icon)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if paths.count > 200 {
                    Text(tr("외 \(paths.count - 200)개")).foregroundStyle(.secondary)
                }
            }
        }
    }
}
