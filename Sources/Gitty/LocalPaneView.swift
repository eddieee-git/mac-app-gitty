import SwiftUI
import AppKit

/// 왼쪽: 내 Mac의 폴더
struct LocalPaneView: View {
    static let paneName = tr("내 폴더")

    @Environment(AppModel.self) private var model
    var focus: FocusState<PaneID?>.Binding
    /// 고른 항목은 AppModel에 둔다 (가운데 복사 버튼이 함께 쓴다)
    private var selection: Set<URL> {
        get { model.localSelection }
        nonmutating set { model.localSelection = newValue }
    }
    @State private var nameRequest: NameRequest?
    @State private var pending: PendingTransfer?
    @State private var dropTarget: DropTarget = .none
    @State private var treeDropTarget: DropTarget = .none
    @State private var query = ""
    @State private var results: [FileItem]?
    @State private var searching = false
    @State private var partial = false
    @AppStorage("localIcons") private var icons = false
    @AppStorage("showLocalTree") private var showTree = true
    @AppStorage("localStacked") private var stacked = false

    private var local: LocalBrowser { model.local }
    private var shownItems: [FileItem] { results ?? local.items }

    private var selectedItems: [FileItem] {
        shownItems.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            HStack(spacing: 6) {
                let crumb = local.breadcrumb
                Breadcrumb(rootLabel: crumb.label, rootIcon: crumb.icon, components: crumb.components) { keep in
                    local.dir = crumb.components.prefix(keep).reduce(crumb.root) {
                        $0.appendingPathComponent($1, isDirectory: true)
                    }
                }
                SearchBox(text: $query, prompt: tr("이 폴더에서 검색"))
                    .padding(.trailing, 10)
                    .padding(.bottom, 6)
            }
            Divider()

            TreeListSplit(stacked: stacked, showTree: showTree, autosave: "local.tree") {
                    FileDropHost(name: tr("\(Self.paneName) 트리"), target: $treeDropTarget,
                                 accepts: { urls, folder in folder != nil && accepts(urls, folder) },
                                 onDrop: receive) {
                        FolderTree(favorites: model.places.favoriteRoots,
                                   roots: model.places.locations,
                                   current: local.dir,
                                   revision: local.revision,
                                   includeHidden: local.showHidden,
                                   alwaysHidden: LocalBrowser.alwaysHidden,
                                   onSelect: { local.dir = $0 },
                                   favoriteActions: favoriteActions)
                    }
            } list: {
                FileDropHost(name: Self.paneName, target: $dropTarget, accepts: accepts, onDrop: receive) {
                    fileTable
                }
            }
        }
        .onChange(of: local.dir) {
            selection.removeAll()
            query = ""
        }
        .task(id: SearchKey(query: query, dir: local.dir.path, revision: local.revision)) { await search() }
        // 드라이브 연결·해제, 앱으로 돌아올 때 위치 목록(Google Drive 등)을 다시 읽는다
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            model.places.refreshLocations()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            model.places.refreshLocations()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.places.refreshLocations()
        }
        .sheet(item: $nameRequest) { NameSheet(request: $0) }
        .overwriteConfirmation($pending)
    }

    // MARK: - 화면 조각

    private var header: some View {
        PaneHeader(title: Self.paneName, icon: "desktopcomputer", tint: .primary) {
            Button { showTree.toggle() } label: { Label(tr("폴더 트리"), systemImage: "sidebar.left") }
                .help(showTree ? tr("폴더 트리 숨기기") : tr("폴더 트리 보기"))
            LayoutToggleButton(stacked: $stacked)
                .disabled(!showTree)
            ViewModeButton(icons: $icons)
            Menu {
                Section(tr("즐겨찾기")) {
                    ForEach(model.places.favoriteRoots) { root in
                        Button { local.dir = root.url } label: { Label(root.title, systemImage: root.icon) }
                    }
                }
                Section(tr("위치")) {
                    ForEach(model.places.locations) { root in
                        Button { local.dir = root.url } label: { Label(root.title, systemImage: root.icon) }
                    }
                }
                Divider()
                Button(tr("다른 폴더 선택…"), action: chooseFolder)
            } label: {
                Label(tr("위치"), systemImage: "star")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("자주 쓰는 위치"))

            Button { local.goUp() } label: { Label(tr("상위 폴더"), systemImage: "chevron.up") }
                .disabled(!local.canGoUp)
                .help(tr("상위 폴더"))
            Button { askNewFolder() } label: { Label(tr("새 폴더"), systemImage: "folder.badge.plus") }
                .help(tr("새 폴더"))
            Button { local.reload() } label: { Label(tr("새로고침"), systemImage: "arrow.clockwise") }
                .help(tr("새로고침"))
        }
    }

    private var fileTable: some View {
        FileTable(pane: Self.paneName,
                  items: shownItems,
                  selection: Bindable(model).localSelection,
                  emptyTitle: results == nil
                    ? (local.loading ? tr("불러오는 중…") : (local.loadError != nil ? tr("이 폴더를 읽을 수 없어요") : tr("빈 폴더입니다")))
                    : (searching ? tr("찾는 중…") : tr("검색 결과가 없어요")),
                  emptyHint: results == nil
                    ? (local.loadError == "denied"
                       ? tr("macOS가 Gitty의 접근을 막았어요.\n시스템 설정 → 개인정보 보호 및 보안 →\n파일 및 폴더(또는 전체 디스크 접근)에서 Gitty를 허용해 주세요.")
                       : (local.loadError ?? tr("오른쪽 Git 폴더의 파일을\n여기로 끌어다 놓으면 내려받습니다")))
                    : tr("하위 폴더까지 이름으로 찾아요"),
                  onOpen: open,
                  onDelete: trash,
                  focus: focus, paneID: .local, onParent: { local.goUp() }, icons: icons) { items in
            if items.isEmpty {
                Button(tr("새 폴더…"), action: askNewFolder)
                Toggle(tr("숨김 파일 보기"), isOn: Binding(get: { local.showHidden }, set: { local.showHidden = $0 }))
            } else {
                Button(tr("열기")) { items.forEach(open) }
                Button(tr("미리 보기")) { QuickLook.shared.toggle(items.map(\.url)) }
                    .keyboardShortcut(.space, modifiers: [])
                Button(tr("Finder에서 보기")) { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
                if items.count == 1, items[0].isDirectory {
                    if model.places.isFavorite(items[0].url) {
                        Button(tr("즐겨찾기에서 제거")) { model.places.removeFavorite(items[0].url) }
                    } else {
                        Button(tr("즐겨찾기에 추가")) { model.places.addFavorite(items[0].url) }
                    }
                }
                Divider()
                Button(tr("Git 저장소로 복사 →")) { sendToRepo(items, move: false) }
                Button(tr("Git 저장소로 이동 →")) { sendToRepo(items, move: true) }
                Divider()
                Button(tr("이름 변경…")) { askRename(items[0]) }
                    .disabled(items.count != 1)
                Button(tr("휴지통으로 이동")) { trash(items) }
            }
        }
        .disabled(model.isBusy)
        .overlay(alignment: .top) {
            if let results, !query.isEmpty {
                searchBanner(count: results.count)
            }
        }
        .overlay {
            switch dropTarget {
            case .none: EmptyView()
            case .here: DropHighlight(text: tr("놓으면 여기로 복사"))
            case .folder(let url): DropHighlight(text: tr("‘\(url.lastPathComponent)’ 폴더에 놓기"), full: false)
            }
        }
    }

    private func searchBanner(count: Int) -> some View {
        HStack(spacing: 6) {
            if searching { ProgressView().controlSize(.mini) }
            Text(searching ? tr("찾는 중…") : tr("‘\(query)’ \(count)개\(partial ? tr(" · 일부만 찾았어요 (더 좁은 폴더에서 찾아 보세요)") : tr(" · 하위 폴더 포함"))"))
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 30)
        .allowsHitTesting(false)
    }

    // MARK: - 동작

    private var favoriteActions: FavoriteActions {
        let places = model.places
        return FavoriteActions(isFavorite: places.isFavorite,
                               add: places.addFavorite,
                               remove: places.removeFavorite,
                               move: places.moveFavorites,
                               resetLabel: tr("Finder 기본 구성으로 되돌리기"),
                               reset: places.resetFavorites)
    }

    private func search() async {
        let text = query.trimmed
        guard !text.isEmpty else {
            results = nil
            searching = false
            return
        }
        try? await Task.sleep(for: .milliseconds(250))   // 타이핑이 멈춘 뒤 찾기
        guard !Task.isCancelled else { return }
        searching = true
        if results == nil { results = [] }
        let dir = local.dir, showHidden = local.showHidden
        let found = await FileItem.search(text, in: dir, includeHidden: showHidden, alwaysHidden: LocalBrowser.alwaysHidden)
        guard !Task.isCancelled else { return }
        results = found.items
        partial = found.partial
        searching = false
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
        nameRequest = NameRequest(title: tr("새 폴더"), confirm: tr("만들기"), initial: tr("새 폴더")) { name in
            do { try local.createFolder(name) } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func askRename(_ item: FileItem) {
        nameRequest = NameRequest(title: tr("이름 변경"), confirm: tr("변경"), initial: item.name) { name in
            do { try local.rename(item, to: name) } catch { model.errorMessage = error.localizedDescription }
        }
    }

    /// 왼쪽 → 오른쪽 (Git 저장소 현재 폴더로)
    private func sendToRepo(_ items: [FileItem], move: Bool) {
        guard let plan = model.uploadPlan(items.map(\.url), removeLocalAfter: move) else { return }
        pending = PendingTransfer.start(plan)
        selection.removeAll()
    }

    // MARK: - 놓기

    private func accepts(_ urls: [URL], _ folder: URL?) -> Bool {
        if model.isBusy { return false }
        // 이 패널에서 끌어 온 항목은 폴더 위에 놓을 때만 (이동)
        if DragSession.isFrom(pane: Self.paneName, urls) { return folder != nil }
        let dest = (folder ?? local.dir).standardizedFileURL.path
        return urls.contains { $0.deletingLastPathComponent().standardizedFileURL.path != dest }
    }

    /// folder: 놓은 폴더 (nil이면 지금 보고 있는 폴더)
    private func receive(_ urls: [URL], folder: URL?) {
        guard !model.isBusy else {
            model.errorMessage = tr("다른 작업이 끝난 뒤 다시 시도하세요.")
            return
        }
        let dest = folder ?? local.dir
        let incoming = urls.filter {
            $0.deletingLastPathComponent().standardizedFileURL.path != dest.standardizedFileURL.path
        }
        guard !incoming.isEmpty else {
            Log.info("download", "이미 그 폴더에 있는 항목이라 무시")
            return
        }
        let isMove = DragSession.isFrom(pane: Self.paneName, urls)
        let conflicts = incoming.map(\.lastPathComponent).filter(existingNames(in: dest).contains)
        let run = {
            if isMove {
                model.moveLocal(incoming, into: dest)
            } else {
                Task { await model.copyToLocal(incoming, removeFromRepo: false, into: dest) }
            }
        }
        if conflicts.isEmpty {
            run()
        } else {
            Log.info("download", "같은 이름이 있어 덮어쓸지 묻는 중: \(conflicts.joined(separator: ", "))")
            pending = PendingTransfer(title: tr("‘\(dest.lastPathComponent)’에 같은 이름이 있어요. 덮어쓸까요?"),
                                      conflicts: conflicts, note: tr("기존 항목은 휴지통으로 이동합니다."), perform: run)
        }
    }
}
