import AppKit
import Quartz

/// Finder처럼 스페이스바로 미리 보기 (Quick Look).
/// 미리 보기 창은 응답 체인 끝의 AppDelegate를 통해 이 객체를 데이터 소스로 받는다.
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private(set) var urls: [URL] = []

    private var panel: QLPreviewPanel? { QLPreviewPanel.shared() }
    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && (panel?.isVisible ?? false) }

    /// 보이면 닫고, 안 보이면 이 항목들로 연다
    func toggle(_ urls: [URL]) {
        guard let panel else { return }
        if isVisible {
            panel.orderOut(nil)
            return
        }
        guard !urls.isEmpty else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    /// 미리 보기가 열린 채로 선택을 바꾸면 따라간다
    func follow(_ urls: [URL]) {
        guard isVisible, !urls.isEmpty, urls != self.urls, let panel else { return }
        self.urls = urls
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
    }

    func attach(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }
}
