import SwiftUI
import AppKit

/// 왼쪽: 내 Mac의 폴더
struct LocalPaneView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<URL>()
    @State private var nameRequest: NameRequest?
    @State private var pending: PendingTransfer?
    @State private var dropTargeted = false

    private var local: LocalBrowser { model.local }

    private var selectedItems: [FileItem] {
        local.items.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "내 폴더", icon: "desktopcomputer", tint: .primary) {
                Menu {
                    place("홈", LocalBrowser.home)
                    place("데스크탑", .desktopDirectory)
                    place("문서", .documentsDirectory)
                    place("다운로드", .downloadsDirectory)
                    Divider()
                    Button("다른 폴더 선택…", action: chooseFolder)
                } label: {
                    Label("위치", systemImage: "star")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("자주 쓰는 위치")

                Button { local.goUp() } label: { Label("상위 폴더", systemImage: "chevron.up") }
                    .disabled(!local.canGoUp)
                    .help("상위 폴더")
                Button { askNewFolder() } label: { Label("새 폴더", systemImage: "folder.badge.plus") }
                    .help("새 폴더")
                Button { local.reload() } label: { Label("새로고침", systemImage: "arrow.clockwise") }
                    .help("새로고침")

                Divider().frame(height: 16)

                Button { sendToRepo(selectedItems, move: false) } label: {
                    Label("Git으로 복사", systemImage: "arrow.right.circle.fill")
                }
                .labelStyle(.titleAndIcon)
                .disabled(selection.isEmpty || model.isBusy)
                .help("선택한 항목을 오른쪽 Git 폴더로 복사 (업로드)")
            }

            let crumb = local.breadcrumb
            Breadcrumb(rootLabel: crumb.label, rootIcon: crumb.icon, components: crumb.components) { keep in
                local.dir = crumb.components.prefix(keep).reduce(crumb.root) {
                    $0.appendingPathComponent($1, isDirectory: true)
                }
            }
            Divider()

            FileTable(items: local.items,
                      selection: $selection,
                      emptyTitle: "빈 폴더입니다",
                      emptyHint: "오른쪽 Git 폴더의 파일을\n여기로 끌어다 놓으면 내려받습니다",
                      onOpen: open,
                      onDelete: trash) { items in
                if items.isEmpty {
                    Button("새 폴더…", action: askNewFolder)
                    Toggle("숨김 파일 보기", isOn: Binding(get: { local.showHidden }, set: { local.showHidden = $0 }))
                } else {
                    Button("열기") { items.forEach(open) }
                    Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
                    Divider()
                    Button("Git 저장소로 복사 →") { sendToRepo(items, move: false) }
                    Button("Git 저장소로 이동 →") { sendToRepo(items, move: true) }
                    Divider()
                    Button("이름 변경…") { askRename(items[0]) }
                        .disabled(items.count != 1)
                    Button("휴지통으로 이동") { trash(items) }
                }
            }
            .disabled(model.isBusy)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadFileURLs(providers, completion: receive)
            return true
        }
        .overlay { if dropTargeted { DropHighlight(text: "놓으면 여기로 복사") } }
        .onChange(of: local.dir) { selection.removeAll() }
        .sheet(item: $nameRequest) { NameSheet(request: $0) }
        .confirmationDialog("같은 이름의 항목을 덮어쓸까요?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { p in
            Button("덮어쓰기", role: .destructive) { run(p) }
        } message: { p in
            Text(p.conflicts.prefix(10).joined(separator: "\n"))
        }
    }

    // MARK: - 동작

    private func place(_ title: String, _ url: URL) -> some View {
        Button(title) { local.dir = url }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = local.dir
        if panel.runModal() == .OK, let url = panel.url { local.dir = url }
    }

    private func open(_ item: FileItem) {
        if item.isDirectory {
            local.dir = item.url
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func trash(_ items: [FileItem]) {
        do { try local.trash(items) } catch { model.errorMessage = error.localizedDescription }
    }

    private func askNewFolder() {
        nameRequest = NameRequest(title: "새 폴더", confirm: "만들기", initial: "새 폴더") { name in
            do { try local.createFolder(name) } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func askRename(_ item: FileItem) {
        nameRequest = NameRequest(title: "이름 변경", confirm: "변경", initial: item.name) { name in
            do { try local.rename(item, to: name) } catch { model.errorMessage = error.localizedDescription }
        }
    }

    /// 왼쪽 → 오른쪽 (Git 저장소 현재 폴더로)
    private func sendToRepo(_ items: [FileItem], move: Bool) {
        guard !items.isEmpty, !model.isBusy else { return }
        let existing = Set(model.items.map(\.name))
        let conflicts = items.map(\.name).filter(existing.contains)
        let urls = items.map(\.url)
        if conflicts.isEmpty {
            Task { await model.upload(urls, removeLocalAfter: move) }
        } else {
            pending = PendingTransfer(urls: urls, move: move, conflicts: conflicts)
        }
        selection.removeAll()
    }

    /// 다른 곳(오른쪽 Git 패널, Finder)에서 이 패널로 떨어뜨린 경우: 복사
    private func receive(_ urls: [URL]) {
        let here = local.dir.standardizedFileURL.path
        let incoming = urls.filter { $0.deletingLastPathComponent().standardizedFileURL.path != here }
        guard !incoming.isEmpty, !model.isBusy else { return }
        let existing = Set(local.items.map(\.name))
        let conflicts = incoming.map(\.lastPathComponent).filter(existing.contains)
        if conflicts.isEmpty {
            Task { await model.copyToLocal(incoming, removeFromRepo: false) }
        } else {
            pending = PendingTransfer(urls: incoming, move: false, conflicts: conflicts)
        }
    }

    private func run(_ p: PendingTransfer) {
        // pending은 두 경우에서 생긴다: Git으로 보내기(로컬 항목) / 이 패널로 받기(외부 항목)
        let isLocalSource = p.urls.allSatisfy {
            $0.deletingLastPathComponent().standardizedFileURL.path == local.dir.standardizedFileURL.path
        }
        if isLocalSource {
            Task { await model.upload(p.urls, removeLocalAfter: p.move) }
        } else {
            Task { await model.copyToLocal(p.urls, removeFromRepo: p.move) }
        }
    }
}
