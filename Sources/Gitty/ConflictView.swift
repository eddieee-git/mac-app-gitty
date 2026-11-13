import SwiftUI

/// 원격과 충돌한 파일마다 무엇을 남길지 고르는 판.
/// 시트로 띄우면 macOS가 앱 종료를 막기 때문에, 창 위에 덮어 보여 준다.
struct ConflictPanel: View {
    let files: [ConflictFile]
    @Environment(AppModel.self) private var model
    @State private var choices: [String: ConflictChoice] = [:]

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Label(tr("다른 곳에서 같은 파일을 바꿨어요"), systemImage: "arrow.triangle.merge")
                    .font(.title3.bold())
                Text(tr("파일마다 남길 쪽을 고르세요. 고르기 전에는 다른 작업을 할 수 없어요."))
                    .foregroundStyle(.secondary)

                HStack {
                    Text(tr("모두")).foregroundStyle(.secondary)
                    Button(tr("내 것")) { setAll(.mine) }
                    Button(tr("원격 것")) { setAll(.theirs) }
                    Button(tr("둘 다")) { setAll(.both) }
                }
                .controlSize(.small)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(files) { file in
                            row(file)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 280)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

                Text(tr("둘 다 남기면 원격 것은 ‘이름 (원격).확장자’로 옆에 저장돼요. 어느 쪽이든 git 기록에는 모두 남아요."))
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button(tr("나중에 (원격 변경 받지 않기)")) { Task { await model.cancelConflicts() } }
                    Spacer()
                    Button(tr("정리하고 올리기")) {
                        var picked: [String: ConflictChoice] = [:]
                        for file in files { picked[file.path] = choices[file.path] ?? .both }
                        Task { await model.resolveConflicts(picked) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 600)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 20)
        }
    }

    private func row(_ file: ConflictFile) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                Text(note(file)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Picker("", selection: Binding(get: { choices[file.path] ?? .both }, set: { choices[file.path] = $0 })) {
                Text(tr("내 것")).tag(ConflictChoice.mine)
                Text(tr("원격 것")).tag(ConflictChoice.theirs)
                Text(tr("둘 다")).tag(ConflictChoice.both)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func note(_ file: ConflictFile) -> String {
        let place = (file.path as NSString).deletingLastPathComponent
        let where_ = place.isEmpty ? "/" : "/\(place)"
        if file.mine == nil { return tr("\(where_) · 이 Mac에서 지웠고, 원격에서 바꿨어요") }
        if file.theirs == nil { return tr("\(where_) · 이 Mac에서 바꿨고, 원격에서 지웠어요") }
        return tr("\(where_) · 양쪽에서 바꿨어요")
    }

    private func setAll(_ choice: ConflictChoice) {
        for file in files { choices[file.path] = choice }
    }
}
