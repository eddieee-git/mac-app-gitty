import SwiftUI
import AppKit

extension View {
    /// 이 뷰를 담고 있는 HSplitView/VSplitView의 칸 나눔 위치를 기억했다가 다음에 되살린다.
    /// vertical: 세로 경계선(좌우로 나눔, HSplitView)이면 true, 가로 경계선(위아래, VSplitView)이면 false.
    /// 칸 수가 바뀌면(예: 진행 로그 숨기기) 칸 수별로 따로 기억한다.
    func splitAutosave(_ name: String, vertical: Bool) -> some View {
        background(SplitAutosaveMarker(name: name, vertical: vertical).frame(width: 0, height: 0))
    }
}

private struct SplitAutosaveMarker: NSViewRepresentable {
    let name: String
    let vertical: Bool

    func makeNSView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.name = name
        view.vertical = vertical
        return view
    }

    func updateNSView(_ nsView: MarkerView, context: Context) {}

    final class MarkerView: NSView {
        var name = ""
        var vertical = true
        private weak var split: NSSplitView?
        private var observer: NSObjectProtocol?
        private var restoredCount = 0
        private var restoring = false
        /// 처음 붙고 잠시 동안은 바깥 칸(좌우 패널 등)이 자리를 잡느라 안쪽 칸 크기가 흔들린다.
        /// 그동안은 저장하지 않고, 자리를 잡은 뒤 한 번 더 되살린다.
        private var settled = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // 화면에 붙은 직후에는 아직 크기가 정해지지 않아서, 한 박자 뒤에 찾는다
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        private func attach() {
            guard split == nil else { return }
            var view = superview
            while let v = view {
                if let s = v as? NSSplitView, s.isVertical == vertical {
                    split = s
                    break
                }
                view = v.superview
            }
            guard let split else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.splitDidResize() }
            }
            restore()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.restore()
                self.settled = true
            }
        }

        private var key: String { "split.\(name).\(split?.arrangedSubviews.count ?? 0)" }

        private func sizes(of split: NSSplitView) -> [CGFloat] {
            split.arrangedSubviews.map { vertical ? $0.frame.width : $0.frame.height }
        }

        private func splitDidResize() {
            guard let split, !restoring, settled else { return }
            let count = split.arrangedSubviews.count
            // 칸 수가 바뀌었으면(로그를 다시 보이게 하는 등) 그 칸 수로 기억한 위치를 되살린다
            if count != restoredCount {
                restore()
                return
            }
            let values = sizes(of: split)
            guard values.allSatisfy({ $0 > 0 }) else { return }
            UserDefaults.standard.set(values.map(Double.init), forKey: key)
        }

        private func restore() {
            guard let split else { return }
            restoredCount = split.arrangedSubviews.count
            guard let saved = UserDefaults.standard.array(forKey: key) as? [Double],
                  saved.count == split.arrangedSubviews.count, saved.count > 1 else { return }
            restoring = true
            defer { restoring = false }
            var position: CGFloat = 0
            for index in 0..<(saved.count - 1) {
                position += CGFloat(saved[index])
                split.setPosition(position, ofDividerAt: index)
                position += split.dividerThickness
            }
        }
    }
}
