import Foundation

/// ~/Library/Logs/Gitty/gitty.log 에 작업 기록을 남긴다. 어느 스레드에서 불러도 된다.
enum Log {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Gitty", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("gitty.log")
    private static let previousURL = directory.appendingPathComponent("gitty.1.log")
    private static let maxSize = 5 * 1024 * 1024

    private static let queue = DispatchQueue(label: "gitty.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// 기다리는 기록을 파일에 다 쓴다 (앱 종료 직전)
    static func flush() { queue.sync {} }

    static func info(_ category: String, _ message: String) { write("INFO", category, message) }
    static func error(_ category: String, _ message: String) { write("ERROR", category, message) }

    private static let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    /// 원격 주소에 들어 있는 인증 정보(https://사용자:토큰@…)와 GitHub 토큰을 가린다.
    static func redact(_ text: String) -> String {
        var s = text
        for (pattern, template) in redactions {
            s = pattern.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }

    private static let redactions: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"(https?://)[^/\s@]+@"#), "$1***@"),
        (try! NSRegularExpression(pattern: #"\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#), "***"),
    ]

    private static func write(_ level: String, _ category: String, _ message: String) {
        let date = Date()
        // 홈 폴더 경로는 ~로 줄여서 읽기 쉽게, 토큰은 가려서
        let message = redact(message).replacingOccurrences(of: homePath + "/", with: "~/")
        queue.async {
            let stamp = formatter.string(from: date)
            // 여러 줄 메시지는 들여써서 한 항목으로 보이게
            let body = message.replacingOccurrences(of: "\n", with: "\n    ")
            let line = "\(stamp) \(level) [\(category)] \(body)\n"
            append(line)
        }
        let entry = LogEntry(date: date, isError: level == "ERROR", category: category, message: message)
        Task { @MainActor in LogFeed.shared.append(entry) }
    }

    private static func append(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > maxSize {
            try? fm.removeItem(at: previousURL)
            try? fm.moveItem(at: fileURL, to: previousURL)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// 로그 창에 보여 줄 마지막 부분
    static func tail(maxBytes: Int = 200_000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text
    }

    static func sizeDescription(of url: URL) -> String {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let values = try? url.resourceValues(forKeys: keys)
        if values?.isDirectory == true {
            var total: Int64 = 0, count = 0
            let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
            while let u = e?.nextObject() as? URL {
                if u.lastPathComponent == ".git" { e?.skipDescendants(); continue }
                if let s = (try? u.resourceValues(forKeys: keys))?.fileSize { total += Int64(s); count += 1 }
            }
            return "폴더, 파일 \(count)개, \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let isError: Bool
    let category: String
    let message: String
}

/// 아래쪽 진행 로그 패널이 보는 이번 실행의 기록 (최근 500개)
@MainActor
@Observable
final class LogFeed {
    static let shared = LogFeed()
    private(set) var entries: [LogEntry] = []
    private let limit = 500

    func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    func clear() { entries.removeAll() }
}
