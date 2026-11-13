import SwiftUI
import AppKit

/// 작업 기록 창 (~/Library/Logs/Gitty/gitty.log)
struct LogView: View {
    @State private var text = ""
    @State private var onlyErrors = false
    @State private var filter = ""
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var shownLines: [String] {
        // 여러 줄 항목(들여쓴 줄)은 앞 항목에 붙여서 한 덩어리로 거른다
        var entries: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("    "), !entries.isEmpty {
                entries[entries.count - 1] += "\n" + line
            } else {
                entries.append(String(line))
            }
        }
        return entries.filter { entry in
            (!onlyErrors || entry.contains(" ERROR ")) &&
            (filter.isEmpty || entry.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(tr("검색 (예: upload, 파일 이름)"), text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Toggle(tr("오류만"), isOn: $onlyErrors)
                Spacer()
                Button(tr("Finder에서 보기")) {
                    NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
                }
                Button(tr("복사")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shownLines.joined(separator: "\n"), forType: .string)
                }
            }
            .padding(10)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(shownLines.enumerated()), id: \.offset) { _, entry in
                            Text(entry)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(entry.contains(" ERROR ") ? .red : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(10)
                }
                .overlay {
                    if shownLines.isEmpty {
                        Text(text.isEmpty ? tr("아직 기록이 없어요") : tr("조건에 맞는 기록이 없어요"))
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: text) { proxy.scrollTo("bottom") }
                .onAppear { proxy.scrollTo("bottom") }
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .onAppear { text = Log.tail() }
        .onReceive(timer) { _ in
            let latest = Log.tail()
            if latest != text { text = latest }
        }
    }
}
