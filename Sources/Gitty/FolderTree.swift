import SwiftUI

struct TreeRoot: Identifiable {
    let url: URL
    let title: String
    let icon: String
    var id: String { url.standardizedFileURL.path }
}

/// 윈도우 탐색기의 왼쪽 탐색 창처럼 폴더만 트리로 보여 준다.
/// 펼친 폴더만 읽어서 큰 폴더(홈 등)에서도 가볍다.
struct FolderTree: View {
    var favorites: [TreeRoot] = []
    let roots: [TreeRoot]
    /// 지금 오른쪽 목록에 보이는 폴더
    let current: URL
    /// 값이 바뀌면 트리를 다시 읽는다 (업로드·삭제로 폴더가 바뀐 경우)
    let revision: Int
    let includeHidden: Bool
    let alwaysHidden: Set<String>
    let onSelect: (URL) -> Void
    /// 즐겨찾기 편집. nil이면 메뉴를 보여 주지 않는다.
    var favoriteActions: FavoriteActions?
    /// 아래쪽 트리 묶음의 제목 (기본: 즐겨찾기가 있으면 "위치", 없으면 "폴더")
    var rootsTitle: String?

    @State private var expanded: Set<String> = []
    @State private var children = FolderChildren()

    private var currentPath: String { current.standardizedFileURL.path }

    var body: some View {
        List(selection: Binding<String?>(
            get: { currentPath },
            set: { path in
                if let path, path != currentPath { onSelect(URL(fileURLWithPath: path, isDirectory: true)) }
            })
        ) {
            if !favorites.isEmpty {
                Section(tr("즐겨찾기")) {
                    ForEach(favorites) { root in
                        Label(root.title, systemImage: root.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DropFolderMarker(url: root.url))
                            .help(root.url.path)
                            .tag(root.id)
                            .contextMenu {
                                if let actions = favoriteActions {
                                    Button(tr("즐겨찾기에서 제거")) { actions.remove(root.url) }
                                    Divider()
                                    Button(actions.resetLabel) { actions.reset() }
                                }
                            }
                    }
                    .onMove { from, to in favoriteActions?.move(from, to) }
                }
            }
            Section(rootsTitle ?? (favorites.isEmpty ? tr("폴더") : tr("위치"))) {
                ForEach(roots) { root in
                    node(root.url, title: root.title, icon: root.icon)
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear(perform: expandToCurrent)
        .onChange(of: currentPath) { expandToCurrent() }
        .onChange(of: revision) { children.invalidate() }
        .onChange(of: includeHidden) { children.invalidate() }
    }

    private func node(_ url: URL, title: String? = nil, icon: String = "folder") -> AnyView {
        let path = url.standardizedFileURL.path
        // 하위 폴더는 뒤에서 읽어 둔다. 아직 모르면(nil) 펼침 단추 없이 보여 주고, 읽히면 다시 그린다.
        let children = self.children.children(of: url, includeHidden: includeHidden, alwaysHidden: alwaysHidden) ?? []
        let label = Label(title ?? url.lastPathComponent, systemImage: path == currentPath ? "folder.fill" : icon)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DropFolderMarker(url: url))
            .help(url.path)
            .tag(path)
            .contextMenu {
                if let actions = favoriteActions {
                    if actions.isFavorite(url) {
                        Button(tr("즐겨찾기에서 제거")) { actions.remove(url) }
                    } else {
                        Button(tr("즐겨찾기에 추가")) { actions.add(url) }
                    }
                }
            }

        guard !children.isEmpty else { return AnyView(label) }

        return AnyView(
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(path) },
                set: { open in
                    if open { expanded.insert(path) } else { expanded.remove(path) }
                })
            ) {
                // 펼쳤을 때만 하위 폴더를 만든다 (안 그러면 트리 전체를 읽게 됨)
                if expanded.contains(path) {
                    ForEach(children, id: \.self) { child in
                        node(child)
                    }
                }
            } label: {
                label
            }
        )
    }

    /// 목록에서 들어간 폴더가 트리에 보이도록 위쪽 폴더들을 펼친다.
    /// 여러 루트에 걸리면(예: Google Drive는 홈 안에도 있음) 가장 가까운 루트 하나만 펼친다.
    private func expandToCurrent() {
        let matching = roots.map(\.id).filter { rootPath in
            currentPath == rootPath || currentPath.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
        }
        guard let rootPath = matching.max(by: { $0.count < $1.count }) else { return }
        expanded.insert(rootPath)
        var parent = (currentPath as NSString).deletingLastPathComponent
        while parent.count > rootPath.count {
            expanded.insert(parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
    }
}

struct FavoriteActions {
    let isFavorite: (URL) -> Bool
    let add: (URL) -> Void
    let remove: (URL) -> Void
    let move: (IndexSet, Int) -> Void
    let resetLabel: String
    let reset: () -> Void
}

/// 트리의 하위 폴더 목록을 뒤에서 읽어 기억해 둔다.
/// 화면을 그릴 때마다 디스크(특히 Google Drive·네트워크 폴더)를 읽으면 앱이 멈추기 때문.
@MainActor
@Observable
final class FolderChildren {
    private var cache: [String: [URL]] = [:]
    /// 최신 상태로 읽은 폴더. invalidate 후에는 비고, 이전 값을 보여 주면서 다시 읽는다.
    @ObservationIgnored private var fresh: Set<String> = []
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var generation = 0

    func children(of url: URL, includeHidden: Bool, alwaysHidden: Set<String>) -> [URL]? {
        let key = url.standardizedFileURL.path
        if !fresh.contains(key), !loading.contains(key) {
            loading.insert(key)
            let gen = generation
            Task {
                let list = await Task.detached(priority: .userInitiated) {
                    FileItem.subfolders(of: url, includeHidden: includeHidden, alwaysHidden: alwaysHidden)
                }.value
                loading.remove(key)
                if gen == generation { fresh.insert(key) }
                if cache[key] != list { cache[key] = list }
            }
        }
        return cache[key]
    }

    /// 폴더가 바뀌었을 수 있으니 다음에 그릴 때 다시 읽는다 (그동안은 이전 값을 보여 준다)
    func invalidate() {
        generation += 1
        fresh = []
        loading = []
        // 이미 그려진 노드들이 다시 읽도록 한 번 알린다
        cache = cache
    }
}
