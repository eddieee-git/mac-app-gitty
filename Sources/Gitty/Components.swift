import SwiftUI
import AppKit

// MARK: - 파일 목록 테이블 (양쪽 패널 공용)

struct FileTable<MenuContent: View>: View {
    let items: [FileItem]
    @Binding var selection: Set<URL>
    let emptyTitle: String
    let emptyHint: String
    let onOpen: (FileItem) -> Void
    let onDelete: ([FileItem]) -> Void
    @ViewBuilder let menu: ([FileItem]) -> MenuContent

    var body: some View {
        Table(of: FileItem.self, selection: $selection) {
            TableColumn("이름") { item in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                }
            }
            TableColumn("크기") { item in
                Text(item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 50, ideal: 70, max: 110)
            TableColumn("수정한 날짜") { item in
                Text(item.modified?.formatted(date: .numeric, time: .shortened) ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130, max: 200)
        } rows: {
            ForEach(items) { item in
                // 다른 패널이나 Finder로 끌어다 놓을 수 있도록
                TableRow(item).itemProvider { NSItemProvider(contentsOf: item.url) }
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

    var body: some View {
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
            TextField("이름", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
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
    let urls: [URL]
    let move: Bool
    let conflicts: [String]
}

// MARK: - 드롭된 파일 URL 읽기

func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    for provider in providers {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url {
                lock.lock(); urls.append(url); lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}
