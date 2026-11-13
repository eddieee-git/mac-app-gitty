import SwiftUI

/// 창 아래쪽의 진행 로그. 업로드·내려받기·커밋·push가 일어나는 대로 보여 준다.
struct LogPanel: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("logPanelShowGit") private var showGit = false
    @AppStorage("logPanelOnlyErrors") private var onlyErrors = false
    private var feed: LogFeed { LogFeed.shared }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var shown: [LogEntry] {
        feed.entries.filter { entry in
            if onlyErrors && !entry.isError { return false }
            // git 명령 한 줄 한 줄은 실패한 경우만 기본으로 보여 준다
            if !showGit && entry.category == "git" && !entry.isError { return false }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("진행 로그", systemImage: "text.alignleft")
                    .font(.callout.weight(.semibold))
                Spacer()
                Toggle("git 명령", isOn: $showGit)
                Toggle("오류만", isOn: $onlyErrors)
                Button("지우기") { feed.clear() }
                Button("전체 기록…") { openWindow(id: "log") }
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(shown) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .overlay {
                    if shown.isEmpty {
                        Text("파일을 올리거나 내려받으면 진행 상황이 여기에 보여요")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: feed.entries.last?.id) {
                    if let last = shown.last?.id {
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                .onAppear {
                    if let last = shown.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .background(.background)
    }

    private func row(_ entry: LogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timeFormat.string(from: entry.date))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(Self.label(for: entry.category))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Self.color(for: entry).opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(Self.color(for: entry))
                .frame(minWidth: 54, alignment: .leading)
            Text(entry.message)
                .foregroundStyle(entry.isError ? .red : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.callout, design: .monospaced))
    }

    private static func label(for category: String) -> String {
        switch category {
        case "upload": "업로드"
        case "download": "내려받기"
        case "drop": "놓기"
        case "commit": "커밋"
        case "push": "push"
        case "repo": "저장소"
        case "clone": "클론"
        case "app": "앱"
        default: category
        }
    }

    private static func color(for entry: LogEntry) -> Color {
        if entry.isError { return .red }
        switch entry.category {
        case "upload", "push": return .blue
        case "download": return .green
        case "commit": return .purple
        case "drop": return .orange
        default: return .secondary
        }
    }
}
