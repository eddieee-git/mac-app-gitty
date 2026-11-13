import Foundation

/// 상태 표시줄에 보여 줄 진행 상황
struct TransferProgress: Equatable, Sendable {
    var phase: String
    /// 0...1, nil이면 얼마나 남았는지 모름 (빙글빙글)
    var fraction: Double?
    var detail: String = ""
}

/// 파일 복사·git 출력에서 진행 상황을 모아, 너무 자주 알리지 않게(0.1초에 한 번) 화면에 넘긴다.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (TransferProgress) -> Void
    private var lastSent = Date.distantPast
    private var phase = ""
    private var total: Int64 = 0
    private var done: Int64 = 0

    init(handler: @escaping @Sendable (TransferProgress) -> Void) {
        self.handler = handler
    }

    /// 바이트 단위로 셀 수 있는 단계 시작 (total이 0이면 진행률 없음)
    func begin(_ phase: String, totalBytes: Int64 = 0) {
        lock.lock()
        self.phase = phase
        total = totalBytes
        done = 0
        lock.unlock()
        send(TransferProgress(phase: phase, fraction: totalBytes > 0 ? 0 : nil), force: true)
    }

    func advance(_ bytes: Int64) {
        lock.lock()
        done += bytes
        let progress = TransferProgress(
            phase: phase,
            fraction: total > 0 ? min(1, Double(done) / Double(total)) : nil,
            detail: total > 0
                ? "\(Self.bytes(done)) / \(Self.bytes(total))"
                : Self.bytes(done))
        lock.unlock()
        send(progress, force: false)
    }

    /// git이 출력한 진행 줄 (예: "Writing objects:  45% (9/20), 1.20 MiB | 2.00 MiB/s")
    func gitLine(_ line: String) {
        guard let parsed = Self.parseGit(line) else { return }
        send(parsed, force: parsed.fraction == 1)
    }

    private func send(_ progress: TransferProgress, force: Bool) {
        lock.lock()
        let now = Date()
        let due = force || now.timeIntervalSince(lastSent) >= 0.1
        if due { lastSent = now }
        lock.unlock()
        if due { handler(progress) }
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private static let gitPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:remote:\s*)?([A-Za-z ]+?):\s+(\d{1,3})% \(([^)]*)\)(?:,\s*(.*?))?(?:,\s*done\.)?\s*$"#)

    static func parseGit(_ line: String) -> TransferProgress? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = gitPattern.firstMatch(in: line, range: range),
              let nameRange = Range(m.range(at: 1), in: line),
              let pctRange = Range(m.range(at: 2), in: line),
              let pct = Double(line[pctRange]) else { return nil }
        let name = String(line[nameRange])
        let phase: String
        switch name.lowercased() {
        case "writing objects": phase = tr("push 중")
        case "compressing objects": phase = tr("압축 중")
        case "receiving objects": phase = tr("받는 중")
        case "resolving deltas": phase = tr("정리 중")
        case "uploading lfs objects": phase = tr("LFS 업로드 중")
        case "downloading lfs objects", "filtering content": phase = tr("LFS 받는 중")
        case "counting objects", "enumerating objects": phase = tr("준비 중")
        default: phase = name
        }
        var detail = Range(m.range(at: 3), in: line).map { String(line[$0]) } ?? ""
        if let extraRange = Range(m.range(at: 4), in: line) {
            let extra = line[extraRange].replacingOccurrences(of: "done.", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
            if !extra.isEmpty { detail += " · " + extra }
        }
        return TransferProgress(phase: phase, fraction: pct / 100, detail: detail)
    }
}
