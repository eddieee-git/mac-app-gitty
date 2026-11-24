import SwiftUI
import AppKit

// 저장소 용량, Git 휴지통, 새 저장소, 커밋 메시지, 브랜치 고르기 화면

/// 상태 표시줄의 저장소 크기 (GitHub 권장 1GB 기준 막대)
struct RepoSizeMeter: View {
    let size: RepoSize

    var body: some View {
        HStack(spacing: 6) {
            meter(icon: "internaldrive", value: size.git, ratio: size.gitRatio)
            if size.lfs > 0 { meter(icon: "icloud", value: size.lfs, ratio: size.lfsRatio) }
        }
        .help(tr("저장소 \(AppModel.bytes(size.git)) / 권장 1 GB · LFS \(AppModel.bytes(size.lfs)) / 무료 1 GB\nGit은 지운 파일도 기록에 남겨서 지워도 크기가 줄지 않아요."))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("저장소 크기 \(AppModel.bytes(size.git)), LFS \(AppModel.bytes(size.lfs))"))
    }

    private func meter(icon: String, value: Int64, ratio: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(AppModel.bytes(value)).monospacedDigit().foregroundStyle(ratio >= 0.8 ? Color.orange : .secondary)
            ProgressView(value: min(ratio, 1))
                .tint(ratio >= 0.8 ? .orange : .accentColor)
                .frame(width: 36)
        }
    }
}

/// 커밋 메시지 쓰기 (설정에서 켰을 때 커밋 전에)
struct CommitMessageSheet: View {
    let request: AppModel.MessageRequest
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("커밋 메시지")).font(.headline)
            Text(request.summary).font(.callout).foregroundStyle(.secondary)
            TextField(tr("무엇을 바꿨는지 짧게"), text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit { request.reply(text) }
            HStack {
                Text(tr("설정에서 끌 수 있어요")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("취소")) { request.reply(nil) }.keyboardShortcut(.cancelAction)
                Button(tr("올리기")) { request.reply(text) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { text = request.suggestion }
    }
}

/// Git 휴지통: 기록에 남은 지운 파일을 골라 되살린다
struct TrashSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var files: [DeletedFile]?
    @State private var selection = Set<DeletedFile.ID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(tr("Git 휴지통"), systemImage: "trash").font(.title3.bold())
            Text(tr("지운 파일도 Git 기록에 남아 있어요. 골라서 원래 자리에 되살릴 수 있어요."))
                .font(.callout).foregroundStyle(.secondary)
            Group {
                if let files {
                    if files.isEmpty {
                        Text(tr("지운 파일이 없어요.")).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Table(files, selection: $selection) {
                            TableColumn(tr("이름")) { f in
                                Label(f.name, systemImage: "doc").lineLimit(1)
                            }
                            TableColumn(tr("있던 곳")) { f in Text(f.folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                                .width(min: 80, ideal: 140)
                            TableColumn(tr("지운 때")) { f in Text(f.date.formatted(.relative(presentation: .named))).foregroundStyle(.secondary) }
                                .width(min: 80, ideal: 110)
                        }
                        .contextMenu(forSelectionType: DeletedFile.ID.self) { _ in } primaryAction: { ids in restore(ids) }
                    }
                } else {
                    ProgressView(tr("기록을 불러오는 중…")).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 300)
            HStack {
                Spacer()
                Button(tr("닫기")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(selection.count > 1 ? tr("\(selection.count)개 되살리기") : tr("되살리기")) { restore(selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600)
        .task { files = await model.deletedFiles() }
    }

    private func restore(_ ids: Set<DeletedFile.ID>) {
        let picked = (files ?? []).filter { ids.contains($0.id) }
        guard !picked.isEmpty else { return }
        dismiss()
        Task { await model.restoreDeleted(picked) }
    }
}

/// 첫 화면의 새 저장소 만들기
struct NewRepoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isPrivate = true

    private var valid: Bool {
        !name.isEmpty && name.range(of: #"^[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("새 저장소 만들기")).font(.title3.bold())
            LabeledContent(tr("이름")) {
                TextField("my-files", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
            }
            if !name.isEmpty && !valid {
                Text(tr("영문, 숫자, - _ . 만 쓸 수 있어요")).font(.caption).foregroundStyle(.red)
            }
            LabeledContent(tr("공개 범위")) {
                Picker("", selection: $isPrivate) {
                    Text(tr("비공개")).tag(true)
                    Text(tr("공개")).tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
            Text(isPrivate ? tr("나만(그리고 초대한 사람만) 볼 수 있어요.") : tr("누구나 볼 수 있어요. 비밀 정보는 올리지 마세요."))
                .font(.caption).foregroundStyle(isPrivate ? Color.secondary : Color.orange)
            HStack {
                Spacer()
                Button(tr("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("만들고 열기"), action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func create() {
        guard valid else { return }
        let n = name, p = isPrivate
        dismiss()
        Task { await model.createRepository(name: n, isPrivate: p) }
    }
}

/// Git 패널 경로 줄 왼쪽의 브랜치 고르기
struct BranchMenu: View {
    @Environment(AppModel.self) private var model
    @State private var nameRequest: NameRequest?

    var body: some View {
        Menu {
            ForEach(model.branches, id: \.self) { name in
                Button {
                    Task { await model.switchBranch(name, create: false) }
                } label: {
                    if name == model.branch { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            Divider()
            Button(tr("새 브랜치…")) {
                nameRequest = NameRequest(title: tr("새 브랜치"), confirm: tr("만들기"), initial: "") { name in
                    let clean = name.trimmed.replacingOccurrences(of: " ", with: "-")
                    guard !clean.isEmpty else { return }
                    Task { await model.switchBranch(clean, create: true) }
                }
            }
            Button(tr("목록 새로고침")) { Task { await model.loadBranches() } }
        } label: {
            Label(model.branch.isEmpty ? "…" : model.branch, systemImage: "arrow.triangle.branch")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.conflicts != nil)
        .help(tr("브랜치 바꾸기 · 지금: \(model.branch)"))
        .sheet(item: $nameRequest) { NameSheet(request: $0) }
    }
}
