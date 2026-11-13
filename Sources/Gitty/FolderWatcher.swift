import Foundation

/// 지금 보고 있는 폴더 하나를 지켜보다가, 안의 항목이 생기거나 지워지거나 이름이 바뀌면 알려 준다.
/// (Finder 등 다른 곳에서 바꾼 것을 바로 반영하기 위해. 하위 폴더까지 보지는 않아서 가볍다.)
@MainActor
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var watched: String?
    private var pending: Task<Void, Never>?
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    /// 다른 폴더를 보기 시작한다 (같은 폴더면 그대로)
    func watch(_ url: URL?) {
        let path = url?.resolvingSymlinksInPath().path
        guard path != watched else { return }
        stop()
        guard let path else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        watched = path
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        pending?.cancel()
        source?.cancel()
        source = nil
        watched = nil
    }

    /// 한꺼번에 여러 개가 바뀌어도 한 번만 다시 읽도록 잠깐 기다린다
    private func changed() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }
}
