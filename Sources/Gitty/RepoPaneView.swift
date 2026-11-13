import SwiftUI
import AppKit

/// 오른쪽: Git 저장소
struct RepoPaneView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<URL>()
    @State private var nameRequest: NameRequest?
    @State private var deleting: [FileItem] = []
    @State private var pendingUpload: PendingTransfer?
    @State private var pendingDownload: PendingTransfer?
    @State private var dropTargeted = false

    private var selectedItems: [FileItem] {
        model.items.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Git · \(model.repoName)", icon: "lock.fill", tint: .orange) {
                Button { sendToLocal(selectedItems, move: false) } label: {
                    Label("내 폴더로 복사", systemImage: "arrow.left.circle.fill")
                }
                .labelStyle(.titleAndIcon)
                .disabled(selection.isEmpty || model.isBusy)
                .help("선택한 항목을 왼쪽 내 폴더로 복사 (다운로드)")

                Divider().frame(height: 16)

                Button { model.path.removeLast() } label: { Label("상위 폴더", systemImage: "chevron.up") }
                    .disabled(model.path.isEmpty)
                    .help("상위 폴더")
                Button { askNewFolder() } label: { Label("새 폴더", systemImage: "folder.badge.plus") }
                    .help("새 폴더")
                Button(action: chooseUpload) { Label("업로드", systemImage: "square.and.arrow.up") }
                    .keyboardShortcut("o", modifiers: .command)
                    .help("파일 선택해서 업로드 (⌘O)")
            }
            .disabled(model.isBusy)

            Breadcrumb(rootLabel: model.repoName, rootIcon: "shippingbox.fill", components: model.path) { keep in
                model.path = Array(model.path.prefix(keep))
            }
            Divider()

            FileTable(items: model.items,
                      selection: $selection,
                      emptyTitle: "빈 폴더입니다",
                      emptyHint: "왼쪽 내 폴더나 Finder에서\n파일을 끌어다 놓으면 업로드됩니다",
                      onOpen: open,
                      onDelete: { deleting = $0 }) { items in
                if items.isEmpty {
                    Button("업로드…", action: chooseUpload)
                    Button("새 폴더…", action: askNewFolder)
                } else {
                    Button("열기") { items.forEach(open) }
                    Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
                    Divider()
                    Button("← 내 폴더로 복사") { sendToLocal(items, move: false) }
                    Button("← 내 폴더로 이동") { sendToLocal(items, move: true) }
                    Divider()
                    Button("이름 변경…") { askRename(items[0]) }
                        .disabled(items.count != 1)
                    Button("삭제…", role: .destructive) { deleting = items }
                }
            }
            .disabled(model.isBusy)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadFileURLs(providers, completion: receive)
            return true
        }
        .overlay {
            if dropTargeted { DropHighlight(text: "놓으면 /\(model.relativeDir) 에 업로드") }
        }
        .onChange(of: model.path) { selection.removeAll() }
        .sheet(item: $nameRequest) { NameSheet(request: $0) }
        .confirmationDialog(deleteTitle,
                            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button("삭제", role: .destructive) {
                let items = deleting
                Task { await model.delete(items) }
            }
        } message: {
            Text(deleting.map(\.name).prefix(10).joined(separator: "\n")
                 + "\n\n삭제 후 바로 커밋·push 됩니다. (git 히스토리에는 남아 있어요)")
        }
        .confirmationDialog("Git 저장소의 같은 이름 항목을 덮어쓸까요?",
                            isPresented: Binding(get: { pendingUpload != nil }, set: { if !$0 { pendingUpload = nil } }),
                            presenting: pendingUpload) { p in
            Button("덮어쓰기", role: .destructive) {
                Task { await model.upload(p.urls, removeLocalAfter: p.move) }
            }
        } message: { p in
            Text(p.conflicts.prefix(10).joined(separator: "\n"))
        }
        .confirmationDialog("내 폴더의 같은 이름 항목을 덮어쓸까요?",
                            isPresented: Binding(get: { pendingDownload != nil }, set: { if !$0 { pendingDownload = nil } }),
                            presenting: pendingDownload) { p in
            Button("덮어쓰기", role: .destructive) {
                Task { await model.copyToLocal(p.urls, removeFromRepo: p.move) }
            }
        } message: { p in
            Text(p.conflicts.prefix(10).joined(separator: "\n") + "\n\n기존 항목은 휴지통으로 이동합니다.")
        }
    }

    // MARK: - 동작

    private var deleteTitle: String {
        deleting.count == 1 ? "‘\(deleting[0].name)’을(를) 삭제할까요?" : "\(deleting.count)개 항목을 삭제할까요?"
    }

    private func open(_ item: FileItem) {
        if item.isDirectory {
            model.path.append(item.name)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func askNewFolder() {
        nameRequest = NameRequest(title: "새 폴더 (Git)", confirm: "만들기", initial: "") { name in
            Task { await model.createFolder(name) }
        }
    }

    private func askRename(_ item: FileItem) {
        nameRequest = NameRequest(title: "이름 변경 (Git)", confirm: "변경", initial: item.name) { name in
            Task { await model.rename(item, to: name) }
        }
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "업로드"
        panel.directoryURL = model.local.dir
        panel.message = "/\(model.relativeDir) 에 업로드할 파일이나 폴더를 선택하세요"
        if panel.runModal() == .OK { receive(panel.urls) }
    }

    /// 오른쪽 → 왼쪽 (내 폴더로)
    private func sendToLocal(_ items: [FileItem], move: Bool) {
        guard !items.isEmpty, !model.isBusy else { return }
        let existing = Set(model.local.items.map(\.name))
        let conflicts = items.map(\.name).filter(existing.contains)
        let urls = items.map(\.url)
        if conflicts.isEmpty {
            Task { await model.copyToLocal(urls, removeFromRepo: move) }
        } else {
            pendingDownload = PendingTransfer(urls: urls, move: move, conflicts: conflicts)
        }
        selection.removeAll()
    }

    /// 왼쪽 패널·Finder에서 떨어뜨린 경우: 업로드 (복사)
    private func receive(_ urls: [URL]) {
        guard !model.isBusy else { return }
        // 저장소 안의 항목을 다시 저장소에 떨어뜨린 경우는 무시
        let external = urls.filter { model.repoRelativePath($0) == nil }
        guard !external.isEmpty else { return }
        let existing = Set(model.items.map(\.name))
        let conflicts = external.map(\.lastPathComponent).filter(existing.contains)
        if conflicts.isEmpty {
            Task { await model.upload(external) }
        } else {
            pendingUpload = PendingTransfer(urls: external, move: false, conflicts: conflicts)
        }
    }
}
