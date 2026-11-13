import SwiftUI
import AppKit

// MARK: - 파일 목록 테이블 (양쪽 패널 공용)

/// 키보드 초점이 있는 패널 (Tab으로 오간다)
enum PaneID: Hashable { case local, repo }

struct FileTable<MenuContent: View>: View {
    /// 끌기가 어느 패널에서 시작됐는지 기록할 이름
    let pane: String
    let items: [FileItem]
    @Binding var selection: Set<URL>
    let emptyTitle: String
    let emptyHint: String
    let onOpen: (FileItem) -> Void
    let onDelete: ([FileItem]) -> Void
    /// 키보드: Tab으로 반대쪽 패널, ⌘↑로 상위 폴더
    var focus: FocusState<PaneID?>.Binding
    let paneID: PaneID
    let onParent: () -> Void
    /// 이름 옆 상태 표시 (Git 쪽만)
    var badge: (FileItem) -> FileBadge? = { _ in nil }
    /// 아이콘 보기
    var icons = false
    @ViewBuilder let menu: ([FileItem]) -> MenuContent

    /// 글자를 치면 그 이름으로 시작하는 항목으로 (Finder와 같음)
    @State private var typed = ""
    @State private var typedAt = Date.distantPast

    /// 열 제목을 눌러 정렬. 폴더는 늘 위에.
    @State private var sortOrder = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard)]

    private var sorted: [FileItem] {
        let ordered = items.sorted(using: sortOrder)
        return ordered.filter(\.isDirectory) + ordered.filter { !$0.isDirectory }
    }

    var body: some View {
        if icons {
            FileGrid(pane: pane, rows: sorted, selection: $selection, onOpen: onOpen, onDelete: onDelete,
                     badge: badge, menu: menu)
                .focused(focus, equals: paneID)
                .overlay { emptyOverlay }
        } else {
            tableView
        }
    }

    @ViewBuilder private var emptyOverlay: some View {
        if items.isEmpty {
            VStack(spacing: 6) {
                Text(emptyTitle).font(.headline)
                Text(emptyHint).font(.callout).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .allowsHitTesting(false)
        }
    }

    private var tableView: some View {
        let rows = sorted
        return Table(of: FileItem.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(tr("이름"), value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 6) {
                    Image(nsImage: IconCache.icon(for: item))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    if let b = badge(item) {
                        Image(systemName: b.symbol)
                            .font(.caption)
                            .foregroundStyle(b.color)
                            .help(b.help)
                            .accessibilityLabel(b.help)
                    }
                    if let location = item.location {
                        Text(location.isEmpty ? tr("· 이 폴더") : "· \(location)")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { if item.isDirectory { DropFolderMarker(url: item.url) } }
            }
            .width(min: 140, ideal: 280)
            TableColumn(tr("크기"), value: \.sortSize) { item in
                Text(item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 50, ideal: 70, max: 110)
            TableColumn(tr("수정한 날짜"), value: \.sortDate) { item in
                Text(item.modified?.formatted(date: .numeric, time: .shortened) ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130, max: 200)
        } rows: {
            ForEach(rows) { item in
                // 다른 패널이나 Finder로 끌어다 놓을 수 있도록
                TableRow(item).itemProvider {
                    DragSession.note(pane: pane, url: item.url)
                    return NSItemProvider(object: item.url as NSURL)
                }
            }
        }
        .contextMenu(forSelectionType: URL.self) { ids in
            menu(items.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            items.filter { ids.contains($0.id) }.forEach(onOpen)
        }
        .onDeleteCommand {
            let selected = items.filter { selection.contains($0.id) }
            if !selected.isEmpty { onDelete(selected) }
        }
        .overlay {
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(emptyTitle).font(.headline)
                    Text(emptyHint).font(.callout).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .allowsHitTesting(false)
            }
        }
        .onChange(of: items) {
            // 사라진 항목은 선택에서 제거
            let ids = Set(items.map(\.id))
            selection = selection.filter { ids.contains($0) }
        }
        // 스페이스바: 미리 보기 (Finder와 같음)
        .onKeyPress(.space) {
            QuickLook.shared.toggle(selectedURLs(in: rows))
            return .handled
        }
        .onChange(of: selection) { QuickLook.shared.follow(selectedURLs(in: rows)) }
        .focused(focus, equals: paneID)
        // Tab: 반대쪽 패널로
        .onKeyPress(.tab) {
            focus.wrappedValue = paneID == .local ? .repo : .local
            return .handled
        }
        // Return: 열기 (폴더면 들어가기)
        .onKeyPress(.return) {
            let selected = rows.filter { selection.contains($0.id) }
            guard !selected.isEmpty else { return .ignored }
            selected.forEach(onOpen)
            return .handled
        }
        // ⌘↑ 상위 폴더, ⌘↓ 열기, ⌘⌫ 삭제 (Finder와 같음)
        .onKeyPress(keys: [.upArrow, .downArrow, .delete], phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            let selected = rows.filter { selection.contains($0.id) }
            switch press.key {
            case .upArrow: onParent()
            case .downArrow: selected.forEach(onOpen)
            default: if !selected.isEmpty { onDelete(selected) }
            }
            return .handled
        }
        // 글자 치기: 그 글자로 시작하는 이름으로 이동
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.isEmpty || press.modifiers == .shift,
                  let ch = press.characters.first, ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-"
            else { return .ignored }
            typed = Date().timeIntervalSince(typedAt) > 1 ? press.characters : typed + press.characters
            typedAt = Date()
            if let hit = rows.first(where: { $0.name.lowercased().hasPrefix(typed.lowercased()) }) {
                selection = [hit.id]
            }
            return .handled
        }
    }

    /// 화면 순서대로 선택한 항목
    private func selectedURLs(in rows: [FileItem]) -> [URL] {
        rows.filter { selection.contains($0.id) }.map(\.url)
    }
}

// MARK: - 패널 머리글

struct PaneHeader<Buttons: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(tint)
                .lineLimit(1)
            Spacer(minLength: 8)
            buttons()
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - 경로 표시

struct Breadcrumb: View {
    let rootLabel: String
    let rootIcon: String
    let components: [String]
    /// 남길 경로 컴포넌트 개수를 넘겨준다 (0 = 루트)
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button { onSelect(0) } label: {
                        Label(rootLabel, systemImage: rootIcon)
                    }
                    .fontWeight(components.isEmpty ? .semibold : .regular)

                    ForEach(Array(components.enumerated()), id: \.offset) { index, name in
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        Button(name) { onSelect(index + 1) }
                            .fontWeight(index == components.count - 1 ? .semibold : .regular)
                    }
                    Color.clear.frame(width: 1, height: 1).id("end")
                }
                .buttonStyle(.plain)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .onAppear { proxy.scrollTo("end") }
            .onChange(of: components) { proxy.scrollTo("end") }
        }
    }
}

// MARK: - 드롭 강조 표시

struct DropHighlight: View {
    let text: String
    /// false면 패널 전체 테두리 없이 아래쪽에 작은 안내만 (폴더 위에 놓을 때)
    var full = true

    var body: some View {
        if full { fullBody } else {
            VStack {
                Spacer()
                Label(text, systemImage: "folder.badge.plus")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
        }
    }

    private var fullBody: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                Label(text, systemImage: "arrow.down.doc")
                    .font(.title3.bold())
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(4)
            .allowsHitTesting(false)
    }
}

// MARK: - 이름 입력 시트

struct NameRequest: Identifiable {
    let id = UUID()
    let title: String
    let confirm: String
    let initial: String
    let action: (String) -> Void
}

struct NameSheet: View {
    let request: NameRequest
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.headline)
            TextField(tr("이름"), text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button(tr("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.confirm, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(FileOps.validateName(text) == nil)
            }
        }
        .padding(20)
        .onAppear { text = request.initial }
    }

    private func commit() {
        guard FileOps.validateName(text) != nil else { return }
        dismiss()
        request.action(text)
    }
}

// MARK: - 같은 이름 덮어쓰기 확인

struct PendingTransfer: Identifiable {
    let id = UUID()
    let title: String
    let conflicts: [String]
    let note: String
    var confirm = tr("덮어쓰기")
    let perform: () -> Void

    /// 물어볼 게 없으면 바로 복사하고 nil, 있으면(같은 이름·비밀 파일·공개 저장소) 물어볼 내용을 돌려준다
    static func start(_ plan: AppModel.TransferPlan) -> PendingTransfer? {
        if plan.conflicts.isEmpty && !plan.mustAsk {
            plan.run()
            return nil
        }
        if !plan.mustAsk {
            Log.info("transfer", "같은 이름이 있어 덮어쓸지 묻는 중: \(plan.conflicts.joined(separator: ", "))")
        }
        return PendingTransfer(title: plan.title, conflicts: plan.conflicts, note: plan.note,
                               confirm: plan.confirm, perform: plan.run)
    }
}

extension View {
    /// 같은 이름 덮어쓰기 확인
    func overwriteConfirmation(_ pending: Binding<PendingTransfer?>) -> some View {
        confirmationDialog(pending.wrappedValue?.title ?? "",
                           isPresented: Binding(get: { pending.wrappedValue != nil },
                                                set: { if !$0 { pending.wrappedValue = nil } }),
                           presenting: pending.wrappedValue) { p in
            Button(p.confirm, role: .destructive) { p.perform() }
        } message: { p in
            Text(p.conflicts.prefix(10).joined(separator: "\n") + (p.note.isEmpty ? "" : "\n\n" + p.note))
        }
    }
}


// MARK: - 파일 드롭 영역
//
// SwiftUI의 .onDrop은 드롭 처리용 뷰를 내용 "뒤"에 깔아 둔다. 그 위에 Table(NSTableView)이 있으면
// 표 위에서 놓은 드래그가 표에 막혀 .onDrop까지 오지 않는다. 그래서 내용을 감싸는 AppKit 뷰가
// 직접 파일 드롭을 받도록 한다. 감싸는 뷰는 표의 조상이라 표 어디에 놓아도 여기로 온다.

/// 끌고 있는 파일을 어디에 놓게 되는지
enum DropTarget: Equatable {
    case none
    /// 지금 보고 있는 폴더
    case here
    /// 목록이나 트리의 특정 폴더 위
    case folder(URL)
}

struct FileDropHost<Content: View>: NSViewRepresentable {
    let name: String
    @Binding var target: DropTarget
    /// 이 패널이 이 파일들을 받을 수 있는지 (folder: 놓으려는 폴더, nil이면 지금 폴더)
    let accepts: ([URL], URL?) -> Bool
    let onDrop: ([URL], URL?) -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> FileDropView<Content> {
        FileDropView(rootView: content())
    }

    func updateNSView(_ view: FileDropView<Content>, context: Context) {
        view.host.rootView = content()
        view.name = name
        view.accepts = accepts
        view.onTargetChange = { newTarget in
            if target != newTarget { target = newTarget }
        }
        view.onDrop = onDrop
    }
}

final class FileDropView<Content: View>: NSView {
    let host: NSHostingView<Content>
    var name = ""
    var accepts: ([URL], URL?) -> Bool = { _, _ in true }
    var onTargetChange: (DropTarget) -> Void = { _ in }
    var onDrop: ([URL], URL?) -> Void = { _, _ in }
    private weak var highlighted: FolderMarkerView?

    init(rootView: Content) {
        host = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
        return objects.compactMap { $0 as? URL }
    }

    /// 끌고 있는 위치(창 좌표) 아래의 폴더 표시를 찾는다
    func folderMarker(at windowPoint: NSPoint) -> FolderMarkerView? {
        var found: FolderMarkerView?
        func walk(_ view: NSView) {
            if found != nil || view.isHidden { return }
            if let marker = view as? FolderMarkerView,
               marker.convert(marker.bounds, to: nil).contains(windowPoint) {
                found = marker
                return
            }
            view.subviews.forEach(walk)
        }
        walk(self)
        return found
    }

    /// 놓을 곳을 정한다. 끌고 있는 항목 자신(또는 그 안)에는 놓지 않는다.
    private func resolve(_ info: NSDraggingInfo) -> (urls: [URL], marker: FolderMarkerView?, operation: NSDragOperation) {
        let urls = fileURLs(info)
        guard !urls.isEmpty else { return ([], nil, []) }
        var marker = folderMarker(at: info.draggingLocation)
        if let folder = marker?.url.standardizedFileURL.path,
           urls.contains(where: { folder == $0.standardizedFileURL.path || folder.hasPrefix($0.standardizedFileURL.path + "/") }) {
            marker = nil
        }
        guard accepts(urls, marker?.url) else { return (urls, nil, []) }
        let mask = info.draggingSourceOperationMask
        let operation: NSDragOperation = mask.contains(.copy) ? .copy : (mask.contains(.generic) ? .generic : .move)
        return (urls, marker, operation)
    }

    private func setHighlight(_ marker: FolderMarkerView?) {
        if highlighted !== marker {
            highlighted?.isHighlighted = false
            marker?.isHighlighted = true
            highlighted = marker
        }
    }

    private func update(_ info: NSDraggingInfo) -> NSDragOperation {
        let (_, marker, operation) = resolve(info)
        setHighlight(operation.isEmpty ? nil : marker)
        onTargetChange(operation.isEmpty ? .none : (marker.map { .folder($0.url) } ?? .here))
        return operation
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHighlight(nil)
        onTargetChange(.none)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setHighlight(nil)
        onTargetChange(.none)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let (urls, marker, operation) = resolve(sender)
        setHighlight(nil)
        onTargetChange(.none)
        let types = sender.draggingPasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "-"
        let place = marker.map { tr("‘\($0.url.lastPathComponent)’ 폴더") } ?? tr("지금 폴더")
        Log.info("drop", "\(name) · \(place)에 \(urls.count)개 항목을 놓음\n" +
                 (urls.isEmpty ? "파일 URL 없음. 붙여넣기 형식: \(types)" : urls.map(\.path).joined(separator: "\n")))
        guard !urls.isEmpty, !operation.isEmpty else { return false }
        onDrop(urls, marker?.url)
        return true
    }
}

// MARK: - 폴더 표시 (놓을 폴더 찾기용)

/// 목록·트리의 폴더 줄 뒤에 까는 보이지 않는 뷰. 끌어다 놓을 때 어느 폴더 위인지 알려 주고, 강조 표시를 그린다.
struct DropFolderMarker: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> FolderMarkerView { FolderMarkerView(url: url) }
    func updateNSView(_ view: FolderMarkerView, context: Context) { view.url = url }
}

final class FolderMarkerView: NSView {
    var url: URL

    var isHighlighted = false {
        didSet {
            layer?.backgroundColor = isHighlighted
                ? NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
                : NSColor.clear.cgColor
            layer?.borderWidth = isHighlighted ? 1.5 : 0
        }
    }

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 클릭·끌기는 그대로 아래로 통과시킨다
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - 끌기 출처

/// 목록에서 끌기가 시작되면 어느 패널의 어떤 파일인지 적어 둔다.
/// 놓을 때 같은 패널에서 온 것이면 복사 대신 이동으로 처리한다.
@MainActor
enum DragSession {
    private static var pane: String?
    private static var urls: Set<String> = []
    private static var startedAt = Date.distantPast

    static func note(pane: String, url: URL) {
        // 여러 개를 함께 끌면 항목마다 불린다. 1초 넘게 지났으면 새 끌기로 본다.
        if Date().timeIntervalSince(startedAt) > 1 || self.pane != pane {
            self.pane = pane
            urls = []
        }
        startedAt = Date()
        urls.insert(url.standardizedFileURL.path)
    }

    /// 놓인 파일들이 모두 이 패널에서 끌어 온 것인지
    static func isFrom(pane: String, _ dropped: [URL]) -> Bool {
        guard self.pane == pane, !dropped.isEmpty else { return false }
        return dropped.allSatisfy { urls.contains($0.standardizedFileURL.path) }
    }
}

// MARK: - 검색 상자

struct SearchBox: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .accessibilityLabel(tr("검색어 지우기"))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .frame(width: 180)
    }
}

/// 검색어·폴더·내용이 바뀔 때마다 다시 찾기 위한 키
struct SearchKey: Equatable {
    let query: String
    let dir: String
    let revision: Int
}

// MARK: - 폴더 트리 + 파일 목록 배치

/// 패널 안의 폴더 트리와 파일 목록. stacked면 위아래, 아니면 좌우로 놓는다. 경계 위치는 배치별로 기억한다.
struct TreeListSplit<Tree: View, List: View>: View {
    let stacked: Bool
    let showTree: Bool
    let autosave: String
    @ViewBuilder let tree: () -> Tree
    @ViewBuilder let list: () -> List

    var body: some View {
        if stacked {
            VSplitView {
                if showTree {
                    tree().frame(maxWidth: .infinity, minHeight: 80, idealHeight: 180, maxHeight: .infinity)
                }
                list()
                    .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
                    .splitAutosave(autosave + ".stacked", vertical: false)
            }
        } else {
            HSplitView {
                if showTree {
                    tree().frame(minWidth: 140, idealWidth: 190, maxWidth: 360, maxHeight: .infinity)
                }
                list()
                    .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                    .splitAutosave(autosave, vertical: true)
            }
        }
    }
}

/// 패널 머리글의 배치 바꾸기 단추 (좌우 ↔ 위아래)
struct LayoutToggleButton: View {
    @Binding var stacked: Bool

    var body: some View {
        Button { stacked.toggle() } label: {
            Label(stacked ? tr("좌우로 놓기") : tr("위아래로 놓기"),
                  systemImage: stacked ? "rectangle.split.2x1" : "rectangle.split.1x2")
        }
        .help(stacked ? tr("폴더 트리를 파일 목록 왼쪽으로") : tr("폴더 트리를 파일 목록 위로"))
    }
}
