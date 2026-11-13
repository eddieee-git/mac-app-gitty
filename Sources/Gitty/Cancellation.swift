import Foundation

/// 지금 하는 작업(복사·git 명령)을 멈추기 위한 표시. 어느 스레드에서 불러도 된다.
/// 복사는 4MB마다, git은 실행 중인 명령을 끊어서 멈춘다.
enum Cancellation {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requested = false
    nonisolated(unsafe) private static var running: Set<ObjectIdentifier> = []
    nonisolated(unsafe) private static var processes: [ObjectIdentifier: Process] = [:]

    static var isRequested: Bool { lock.withLock { requested } }

    /// 새 작업을 시작할 때
    static func reset() { lock.withLock { requested = false } }

    /// 취소 단추: 표시를 세우고 실행 중인 명령을 끊는다
    static func request() {
        let running = lock.withLock { () -> [Process] in
            requested = true
            return Array(processes.values)
        }
        for p in running where p.isRunning { p.interrupt() }
        Log.info("작업", "취소 요청 (실행 중인 명령 \(running.count)개 중단)")
    }

    /// 취소됐으면 CancellationError
    static func check() throws {
        if isRequested { throw CancellationError() }
    }

    static func track(_ process: Process) {
        lock.withLock { processes[ObjectIdentifier(process)] = process }
    }

    static func untrack(_ process: Process) {
        _ = lock.withLock { processes.removeValue(forKey: ObjectIdentifier(process)) }
    }
}
