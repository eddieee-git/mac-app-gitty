import SwiftUI
import AppKit
import QuickLookThumbnailing

/// 아이콘 보기: 파일을 큰 아이콘·미리보기 그림으로 늘어놓는다 (Finder의 아이콘 보기)
struct FileGrid<MenuContent: View>: View {
    let pane: String
    let rows: [FileItem]
    @Binding var selection: Set<URL>
    let onOpen: (FileItem) -> Void
    let onDelete: ([FileItem]) -> Void
    let badge: (FileItem) -> FileBadge?
    @ViewBuilder let menu: ([FileItem]) -> MenuContent

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 6)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(rows) { item in
                    cell(item)
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { selection = [] }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            QuickLook.shared.toggle(rows.filter { selection.contains($0.id) }.map(\.url))
            return .handled
        }
        .onKeyPress(.return) {
            let picked = rows.filter { selection.contains($0.id) }
            guard !picked.isEmpty else { return .ignored }
            picked.forEach(onOpen)
            return .handled
        }
        .onDeleteCommand {
            let picked = rows.filter { selection.contains($0.id) }
            if !picked.isEmpty { onDelete(picked) }
        }
        .onChange(of: selection) { QuickLook.shared.follow(rows.filter { selection.contains($0.id) }.map(\.url)) }
    }

    private func cell(_ item: FileItem) -> some View {
        let selected = selection.contains(item.id)
        return VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                Thumbnail(item: item)
                    .frame(width: 64, height: 64)
                if let b = badge(item) {
                    Image(systemName: b.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(b.color)
                        .background(Circle().fill(Color(nsColor: .textBackgroundColor)))
                        .help(b.help)
                }
            }
            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 3)
                .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .frame(width: 96, height: 104, alignment: .top)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .background { if item.isDirectory { DropFolderMarker(url: item.url) } }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen(item) }
        .onTapGesture { click(item) }
        .contextMenu {
            // 오른쪽 클릭한 항목이 선택에 없으면 그 항목만
            let picked = selected ? rows.filter { selection.contains($0.id) } : [item]
            menu(picked)
        }
        .onDrag {
            DragSession.note(pane: pane, url: item.url)
            return NSItemProvider(object: item.url as NSURL)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// ⌘ 누르고 클릭: 하나 더 고르기/빼기, ⇧: 범위, 그냥: 하나만
    private func click(_ item: FileItem) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else if flags.contains(.shift), let anchor = rows.firstIndex(where: { selection.contains($0.id) }),
                  let target = rows.firstIndex(of: item) {
            let range = min(anchor, target)...max(anchor, target)
            selection = Set(rows[range].map(\.id))
        } else {
            selection = [item.id]
        }
    }
}

/// 사진·PDF 등은 미리보기 그림, 나머지는 아이콘
private struct Thumbnail: View {
    let item: FileItem
    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? IconCache.icon(for: item))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .task(id: item.url) { image = await ThumbnailCache.thumbnail(for: item) }
    }
}

@MainActor
enum ThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func thumbnail(for item: FileItem) async -> NSImage? {
        guard !item.isDirectory else { return nil }
        // 아직 받지 않은 큰 파일(LFS 포인터)이나 너무 큰 파일은 미리보기를 만들지 않는다
        if GitRepo.isLFSPointer(item.url) || (item.size ?? 0) > 200 * 1024 * 1024 { return nil }
        let key = "\(item.url.path)|\(item.modified?.timeIntervalSince1970 ?? 0)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 64, height: 64),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.nsImage
        cache.setObject(image, forKey: key)
        return image
    }
}

/// 패널 머리글의 보기 방식 바꾸기 (목록 ↔ 아이콘)
struct ViewModeButton: View {
    @Binding var icons: Bool

    var body: some View {
        Button { icons.toggle() } label: {
            Label(icons ? tr("목록으로 보기") : tr("아이콘으로 보기"), systemImage: icons ? "list.bullet" : "square.grid.2x2")
        }
        .help(icons ? tr("목록으로 보기") : tr("아이콘으로 보기 (사진은 미리보기)"))
    }
}
