import SwiftUI
import AppKit

/// 오른쪽: Git 저장소
struct RepoPaneView: View {
    static let paneName = tr("Git 저장소")

    @Environment(AppModel.self) private var model
    var focus: FocusState<PaneID?>.Binding
    /// 고른 항목은 AppModel에 둔다 (가운데 복사 버튼이 함께 쓴다)
    private var selection: Set<URL> {
        get { model.repoSelection }
        nonmutating set { model.repoSelection = newValue }
    }
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
    @AppStorage("repoIcons") private var icons = false
    @AppStorage("showRepoTree") private var showTree = true
    @AppStorage("repoStacked") private var stacked = false

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
                SearchBox(text: $query, prompt: tr("저장소에서 검색"))
                    .padding(.trailing, 10)
                    .padding(.bottom, 6)
            }
            Divider()

            TreeListSplit(stacked: stacked, showTree: showTree && model.root != nil, autosave: "repo.tree") {
                if let root = model.root {
                    FileDropHost(name: tr("\(Self.paneName) 트리"), target: $treeDropTarget,
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
                                   rootsTitle: tr("저장소"))
                    }
                }
            } list: {
                FileDropHost(name: Self.paneName, target: $dropTarget, accepts: accepts, onDrop: receive) {
                    fileTable
                }
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
            Button(tr("삭제"), role: .destructive) {
                let items = deleting
                Task { await model.delete(items) }
            }
        } message: {
            Text(deleting.map(\.name).prefix(10).joined(separator: "\n")
                 + tr("\n\n삭제 후 바로 커밋·push 됩니다. (git 히스토리에는 남아 있어요)"))
        }
        .overwriteConfirmation($pending)
    }

    // MARK: - 화면 조각

    private var header: some View {
        PaneHeader(title: "Git · \(model.repoName)", icon: "lock.fill", tint: .orange) {
            Button { showTree.toggle() } label: { Label(tr("폴더 트리"), systemImage: "sidebar.left") }
                .help(showTree ? tr("폴더 트리 숨기기") : tr("폴더 트리 보기"))
            LayoutToggleButton(stacked: $stacked)
                .disabled(!showTree)
            ViewModeButton(icons: $icons)
            Button { model.path.removeLast() } label: { Label(tr("상위 폴더"), systemImage: "chevron.up") }
                .disabled(model.path.isEmpty)
                .help(tr("상위 폴더"))
            Button { askNewFolder() } label: { Label(tr("새 폴더"), systemImage: "folder.badge.plus") }
                .help(tr("새 폴더"))
            Button(action: chooseUpload) { Label(tr("업로드"), systemImage: "square.and.arrow.up") }
                .keyboardShortcut("o", modifiers: .command)
                .help(tr("파일 선택해서 업로드 (⌘O)"))
        }
        .disabled(model.isBusy)
    }

    private var fileTable: some View {
        FileTable(pane: Self.paneName,
                  items: shownItems,
                  selection: Bindable(model).repoSelection,
                  emptyTitle: results == nil ? (model.loading ? tr("불러오는 중…") : tr("빈 폴더입니다")) : (searching ? tr("찾는 중…") : tr("검색 결과가 없어요")),
                  emptyHint: results == nil ? tr("왼쪽 내 폴더나 Finder에서\n파일을 끌어다 놓으면 업로드됩니다") : tr("하위 폴더까지 이름으로 찾아요"),
                  onOpen: open,
                  onDelete: { deleting = $0 },
                  focus: focus, paneID: .repo, onParent: { if !model.path.isEmpty { model.path.removeLast() } },
                  badge: model.badge(for:), icons: icons) { items in
            if items.isEmpty {
                Button(tr("업로드…"), action: chooseUpload)
                Button(tr("새 폴더…"), action: askNewFolder)
            } else {
                Button(tr("열기")) { items.forEach(open) }
                Button(tr("미리 보기")) { QuickLook.shared.toggle(items.map(\.url)) }
                    .keyboardShortcut(.space, modifiers: [])
                Button(tr("Finder에서 보기")) { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
                if items.count == 1, let web = model.webURL(for: items[0]) {
                    Button(tr("GitHub에서 보기")) { NSWorkspace.shared.open(web) }
                    Button(tr("GitHub 링크 복사")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(web.absoluteString, forType: .string)
                        Log.info("app", "GitHub 링크 복사: \(web.absoluteString)")
                    }
                }
                if items.contains(where: { [.modified, .untracked].contains(model.badge(for: $0)) }) {
                    Button(tr("바뀐 내용 올리기")) { Task { await model.commitChanges(items) } }
                }
                if items.count == 1, !items[0].isDirectory {
                    Button(tr("변경 기록…")) { historyItem = items[0] }
                }
                if items.count == 1, items[0].isDirectory {
                    if model.repoFavorites.isFavorite(items[0].url) {
                        Button(tr("즐겨찾기에서 제거")) { model.repoFavorites.remove(items[0].url) }
                    } else {
                        Button(tr("즐겨찾기에 추가")) { model.repoFavorites.add(items[0].url) }
                    }
                }
                Divider()
                Button(tr("← 내 폴더로 복사")) { sendToLocal(items, move: false) }
                Button(tr("← 내 폴더로 이동")) { sendToLocal(items, move: true) }
                Divider()
                Button(tr("이름 변경…")) { askRename(items[0]) }
                    .disabled(items.count != 1)
                Button(tr("삭제…"), role: .destructive) { deleting = items }
            }
        }
        .disabled(model.isBusy)
        .overlay(alignment: .top) {
            if let results, !query.isEmpty {
                HStack(spacing: 6) {
                    if searching { ProgressView().controlSize(.mini) }
                    Text(searching ? tr("찾는 중…") : tr("‘\(query)’ \(results.count)개\(partial ? tr(" · 일부만 찾았어요 (더 좁은 폴더에서 찾아 보세요)") : tr(" · 하위 폴더 포함"))"))
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
            case .here: DropHighlight(text: tr("놓으면 /\(model.relativeDir) 에 업로드"))
            case .folder(let url): DropHighlight(text: tr("‘\(url.lastPathComponent)’ 폴더에 놓기"), full: false)
            }
        }
    }

    // MARK: - 동작

    private var deleteTitle: String {
        deleting.count == 1 ? tr("‘\(deleting[0].name)’을(를) 삭제할까요?") : tr("\(deleting.count)개 항목을 삭제할까요?")
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
            Task {
                if await model.materialize([item.url]) { NSWorkspace.shared.open(item.url) }
            }
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
        nameRequest = NameRequest(title: tr("새 폴더 (Git)"), confirm: tr("만들기"), initial: "") { name in
            Task { await model.createFolder(name) }
        }
    }

    private func askRename(_ item: FileItem) {
        nameRequest = NameRequest(title: tr("이름 변경 (Git)"), confirm: tr("변경"), initial: item.name) { name in
            Task { await model.rename(item, to: name) }
        }
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = tr("업로드")
        panel.directoryURL = model.local.dir
        panel.message = tr("/\(model.relativeDir) 에 업로드할 파일이나 폴더를 선택하세요")
        if panel.runModal() == .OK { receive(panel.urls, folder: nil) }
    }

    /// 오른쪽 → 왼쪽 (내 폴더로)
    private func sendToLocal(_ items: [FileItem], move: Bool) {
        guard let plan = model.downloadPlan(items.map(\.url), removeFromRepo: move) else { return }
        pending = PendingTransfer.start(plan)
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
            model.errorMessage = tr("다른 작업이 끝난 뒤 다시 시도하세요.")
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
        guard let plan = model.uploadPlan(external, toDir: destDir) else { return }
        pending = PendingTransfer.start(plan)
    }
}
