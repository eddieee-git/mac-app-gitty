import SwiftUI
import AppKit

// 업데이트 자체는 공통 파일(AppUpdater.swift)이 한다. 여기에는 Gitty 창과 메뉴에 붙이는 것만 둔다.

/// Gitty 메뉴의 "업데이트 확인…" / "새 버전 X 설치…"
struct UpdateCommands: Commands {
    @ObservedObject var updater = AppUpdater.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(updater.menuTitle) { updater.menuAction() }
                .disabled(updater.isBusy)
        }
    }
}

/// 새 버전이 있으면 창 위쪽에 보이는 띠. Gitty는 메뉴바 아이콘이 없어서 여기서도 알린다.
struct UpdateBanner: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        if updater.available != nil {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.app.fill").foregroundStyle(.tint)
                Text(updater.statusText)
                Spacer()
                Button(updater.menuTitle) { updater.menuAction() }
                    .controlSize(.small)
                    .disabled(updater.isBusy)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.tint.opacity(0.12))
        }
    }
}
