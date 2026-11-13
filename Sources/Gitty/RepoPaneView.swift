import SwiftUI
import AppKit

/// 오른쪽: Git 저장소
struct RepoPaneView: View {
    static let paneName = "Git 저장소"

    @Environment(AppModel.self) private var model
    @State private var selection = Set<URL>()
    @State private var nameRequest: NameRequest?
    @State private var deleting: [FileItem] = []
    @State private var historyItem: FileItem?
    @State private var pending: PendingTransfer?
    @State private var dropTarget: DropTarget = .none
    @State private var treeDropTarget: DropTarget = .none
    @State private var query = ""
    @State private var results: [FileItem]?
    @State private var searching = false
    @State private var partial = false
    @AppStorage("showRepoTree") private var showTree = true

    private var shownItems: [FileItem] { results ?? model.items }

    private var selectedItems: [FileItem] {
        shownItems.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            HStack(spacing: 6) {
                Breadcrumb(rootLabel: model.repoName, rootIcon: "shippingbox.fill", components: model.path) { keep in
                    model.path = Array(model.path.prefix(keep))
                }
                SearchBox(text: $query, prompt: "저장소에서 검색")
                    .padding(.trailing, 10)
                    .padding(.bottom, 6)
            }
            Divider()

            HSplitView {
                if showTree, let root = model.root {
                    FileDropHost(name: "\(Self.paneName) 트리", target: $treeDropTarget,
                                 accepts: { urls, folder in folder != nil && accepts(urls, folder) },
                                 onDrop: receive) {
                        FolderTree(favorites: model.repoFavorites.roots,
                                   roots: [TreeRoot(url: root, title: model.repoName, icon: "shippingbox")],
                                   current: model.currentDir ?? root,
                                   revision: model.revision,
                                   includeHidden: true,
                                   alwaysHidden: AppModel.repoHidden,
                                   onSelect: go(to:),
                                   favoriteActions: model.repoFavorites.actions,
                                   rootsTitle: "저장소")
                    }
                    .frame(minWidth: 140, idealWidth: 190, maxWidth: 360, maxHeight: .infinity)
                }

                FileDropHost(name: Self.paneName, target: $dropTarget, accepts: accepts, onDrop: receive) {
                    fileTable
                }
                .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: model.path) {
            selection.removeAll()
            query = ""
        }
        .task(id: SearchKey(query: query, dir: model.relativeDir, revision: model.revision)) { await search() }
        .sheet(item: $nameRequest) { NameSheet(request: $0) }
        .sheet(item: $historyItem) { HistorySheet(item: $0) }
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
        .overwriteConfirmation($pending)
    }

    // MARK: - 화면 조각

    private var header: some View {
        PaneHeader(title: "Git · \(model.repoName)", icon: "lock.fill", tint: .orange) {
            Button { sendToLocal(selectedItems, move: false) } label: {
                Label("내 폴더로 복사", systemImage: "arrow.left.circle.fill")
            }
            .labelStyle(.titleAndIcon)
            .disabled(selection.isEmpty || model.isBusy)
            .help("선택한 항목을 왼쪽 내 폴더로 복사 (다운로드)")

            Divider().frame(height: 16)

            Button { showTree.toggle() } label: { Label("폴더 트리", systemImage: "sidebar.left") }
                .help(showTree ? "폴더 트리 숨기기" : "폴더 트리 보기")
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
    }

    private var fileTable: some View {
        FileTable(pane: Self.paneName,
                  items: shownItems,
                  selection: $selection,
                  emptyTitle: results == nil ? (model.loading ? "불러오는 중…" : "빈 폴더입니다") : (searching ? "찾는 중…" : "검색 결과가 없어요"),
                  emptyHint: results == nil ? "왼쪽 내 폴더나 Finder에서\n파일을 끌어다 놓으면 업로드됩니다" : "하위 폴더까지 이름으로 찾아요",
                  onOpen: open,
                  onDelete: { deleting = $0 }) { items in
            if items.isEmpty {
                Button("업로드…", action: chooseUpload)
                Button("새 폴더…", action: askNewFolder)
            } else {
                Button("열기") { items.forEach(open) }
                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
                if items.count == 1, !items[0].isDirectory {
                    Button("변경 기록…") { historyItem = items[0] }
                }
                if items.count == 1, items[0].isDirectory {
                    if model.repoFavorites.isFavorite(items[0].url) {
                        Button("즐겨찾기에서 제거") { model.repoFavorites.remove(items[0].url) }
                    } else {
                        Button("즐겨찾기에 추가") { model.repoFavorites.add(items[0].url) }
                    }
                }
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
        .overlay(alignment: .top) {
            if let results, !query.isEmpty {
                HStack(spacing: 6) {
                    if searching { ProgressView().controlSize(.mini) }
                    Text(searching ? "찾는 중…" : "‘\(query)’ \(results.count)개\(partial ? " · 일부만 찾았어요 (더 좁은 폴더에서 찾아 보세요)" : " · 하위 폴더 포함")")
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 30)
                .allowsHitTesting(false)
            }
        }
        .overlay {
            switch dropTarget {
            case .none: EmptyView()
            case .here: DropHighlight(text: "놓으면 /\(model.relativeDir) 에 업로드")
            case .folder(let url): DropHighlight(text: "‘\(url.lastPathComponent)’ 폴더에 놓기", full: false)
            }
        }
    }

    // MARK: - 동작

    private var deleteTitle: String {
        deleting.count == 1 ? "‘\(deleting[0].name)’을(를) 삭제할까요?" : "\(deleting.count)개 항목을 삭제할까요?"
    }

    /// 저장소 안의 폴더로 이동
    private func go(to url: URL) {
        if let rel = model.repoRelativePath(url) {
            model.path = rel.split(separator: "/").map(String.init)
        } else {
            model.path = []
        }
    }

    private func open(_ item: FileItem) {
        if item.isDirectory {
            go(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func search() async {
        let text = query.trimmed
        guard !text.isEmpty, let dir = model.currentDir else {
            results = nil
            searching = false
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        searching = true
        if results == nil { results = [] }
        let found = await FileItem.search(text, in: dir, includeHidden: true, alwaysHidden: AppModel.repoHidden)
        guard !Task.isCancelled else { return }
        results = found.items
        partial = found.partial
        searching = false
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
        if panel.runModal() == .OK { receive(panel.urls, folder: nil) }
    }

    /// 오른쪽 → 왼쪽 (내 폴더로)
    private func sendToLocal(_ items: [FileItem], move: Bool) {
        guard !items.isEmpty, !model.isBusy else { return }
        let urls = items.map(\.url)
        let conflicts = items.map(\.name).filter(existingNames(in: model.local.dir).contains)
        let run = { _ = Task { await model.copyToLocal(urls, removeFromRepo: move) } }
        if conflicts.isEmpty {
            run()
        } else {
            Log.info("download", "같은 이름이 있어 덮어쓸지 묻는 중: \(conflicts.joined(separator: ", "))")
            pending = PendingTransfer(title: "내 폴더의 같은 이름 항목을 덮어쓸까요?", conflicts: conflicts,
                                      note: "기존 항목은 휴지통으로 이동합니다.", perform: run)
        }
        selection.removeAll()
    }

    // MARK: - 놓기

    private func isInRepo(_ urls: [URL]) -> Bool {
        urls.allSatisfy { model.repoRelativePath($0) != nil }
    }

    private func accepts(_ urls: [URL], _ folder: URL?) -> Bool {
        if model.isBusy { return false }
        // 저장소 안의 항목은 폴더 위에 놓을 때만 (git mv로 이동)
        if isInRepo(urls) { return folder != nil }
        return true
    }

    /// folder: 놓은 폴더 (nil이면 지금 보고 있는 폴더)
    private func receive(_ urls: [URL], folder: URL?) {
        guard !model.isBusy else {
            Log.error("upload", "다른 작업 중이라 받지 않음")
            model.errorMessage = "다른 작업이 끝난 뒤 다시 시도하세요."
            return
        }
        guard let root = model.root else { return }
        let destURL = folder ?? model.currentDir ?? root
        let destDir = destURL.standardizedFileURL.path == root.standardizedFileURL.path
            ? "" : (model.repoRelativePath(destURL) ?? model.relativeDir)

        if isInRepo(urls) {
            // 저장소 안에서 옮기기
            guard folder != nil else { return }
            Task { await model.moveInRepo(urls, to: destURL) }
            return
        }

        let external = urls.filter { model.repoRelativePath($0) == nil }
        let conflicts = external.map(\.lastPathComponent).filter(existingNames(in: destURL).contains)
        let run = { _ = Task { await model.upload(external, to: destDir) } }
        if conflicts.isEmpty {
            run()
        } else {
            Log.info("upload", "같은 이름이 있어 덮어쓸지 묻는 중: \(conflicts.joined(separator: ", "))")
            pending = PendingTransfer(title: "/\(destDir)에 같은 이름이 있어요. 덮어쓸까요?",
                                      conflicts: conflicts, note: "", perform: run)
        }
    }
}
