import SwiftUI

/// 두 패널 사이의 복사 버튼. 화살표 방향이 곧 복사 방향이다.
///   → : 왼쪽(내 폴더)에서 고른 것을 지금 보고 있는 Git 폴더로 (커밋·push)
///   ← : 오른쪽(Git)에서 고른 것을 지금 보고 있는 내 폴더로
struct TransferBar: View {
    @Environment(AppModel.self) private var model
    @State private var pending: PendingTransfer?
    @State private var syncing = false

    private var toRepo: [URL] { Array(model.localSelection) }
    private var toLocal: [URL] { Array(model.repoSelection) }

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            TransferButton(systemImage: "arrowtriangle.right.fill", label: tr("Git으로 복사"),
                           enabled: !toRepo.isEmpty && !model.isBusy && model.conflicts == nil) {
                send(model.uploadPlan(toRepo)) { model.localSelection.removeAll() }
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .help(toRepo.isEmpty
                  ? tr("왼쪽에서 항목을 고르면 Git으로 복사할 수 있어요 (⌥⌘→)")
                  : tr("\(toRepo.count)개를 Git의 /\(model.relativeDir)(으)로 복사 (⌥⌘→)"))

            TransferButton(systemImage: "arrowtriangle.left.fill", label: tr("내 폴더로 복사"),
                           enabled: !toLocal.isEmpty && !model.isBusy) {
                send(model.downloadPlan(toLocal)) { model.repoSelection.removeAll() }
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .help(toLocal.isEmpty
                  ? tr("오른쪽에서 항목을 고르면 내 폴더로 복사할 수 있어요 (⌥⌘←)")
                  : tr("\(toLocal.count)개를 내 폴더(\(model.local.dir.lastPathComponent))로 복사 (⌥⌘←)"))

            Divider().frame(width: 20)

            Button { syncing = true } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .overlay(Circle().strokeBorder(Color.orange.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .disabled(model.isBusy || model.conflicts != nil || model.root == nil)
            .help(tr("폴더 맞추기: 지금 보고 있는 두 폴더를 비교해서 한쪽을 다른 쪽과 같게"))
            .accessibilityLabel(tr("폴더 맞추기"))
            Spacer()
        }
        .frame(width: 40)
        .frame(maxHeight: .infinity)
        .background(.background.secondary)
        .overwriteConfirmation($pending)
        .sheet(isPresented: $syncing) { SyncSheet() }
    }

    private func send(_ plan: AppModel.TransferPlan?, clear: () -> Void) {
        guard let plan else { return }
        pending = PendingTransfer.start(plan)
        clear()
    }
}

private struct TransferButton: View {
    let systemImage: String
    let label: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(TransferButtonStyle(enabled: enabled))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// 늘 주황색으로 보인다. 고른 항목이 있으면 꽉 찬 주황 동그라미, 없으면 주황 테두리.
private struct TransferButtonStyle: ButtonStyle {
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? Color.white : Color.orange)
            .background(Circle().fill(enabled ? Color.orange.opacity(configuration.isPressed ? 0.75 : 1) : Color.orange.opacity(0.12)))
            .overlay(Circle().strokeBorder(Color.orange, lineWidth: enabled ? 0 : 1.5))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: enabled)
    }
}
