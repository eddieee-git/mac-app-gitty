import SwiftUI
import AppKit

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showClone = false
    @State private var selectedRecent: URL?
    @State private var opening: URL?

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Image(systemName: "externaldrive.badge.icloud")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Gitty").font(.largeTitle.bold())
                Text("Git 저장소를 파일 관리자처럼 다루세요")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    showClone = true
                } label: {
                    Label("GitHub 저장소 열기…", systemImage: "arrow.down.circle")
                        .frame(minWidth: 180)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                Button {
                    chooseLocalClone()
                } label: {
                    Label("로컬 클론 열기…", systemImage: "folder")
                        .frame(minWidth: 180)
                }
                .controlSize(.large)
            }

            if !model.recents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("최근 저장소").font(.headline)
                    List(model.recents, id: \.self, selection: $selectedRecent) { url in
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text(url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent)
                                Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if opening == url {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("열기") { openRecent(url) }
                                    .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    // 더블클릭·Return은 macOS 목록의 기본 동작(primaryAction)으로 받는다. 줄 어디를 눌러도 된다.
                    .contextMenu(forSelectionType: URL.self) { urls in
                        if let url = urls.first {
                            Button("열기") { openRecent(url) }
                            Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Divider()
                            Button("목록에서 제거") { model.removeRecent(url) }
                        }
                    } primaryAction: { urls in
                        if let url = urls.first { openRecent(url) }
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                    .frame(maxWidth: 520, maxHeight: 220)
                    Text("더블클릭, Return 키, 또는 열기 버튼으로 열어요").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let busy = model.busyMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(.secondary)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(model.isBusy)
        .sheet(isPresented: $showClone) {
            CloneSheet()
        }
    }

    private func openRecent(_ url: URL) {
        guard opening == nil, !model.isBusy else { return }
        selectedRecent = url
        opening = url
        Log.info("repo", "최근 저장소 열기: \(url.path)")
        Task {
            await model.open(url)
            opening = nil
        }
    }

    private func chooseLocalClone() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "git 저장소(클론) 폴더를 선택하세요"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.open(url) }
        }
    }
}

private struct RemoteRepo: Decodable, Hashable {
    let nameWithOwner: String
    let isPrivate: Bool
}

struct CloneSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var repos: [RemoteRepo] = []
    @State private var loading = true
    @State private var query = ""
    @State private var selection: String?

    private var filtered: [RemoteRepo] {
        query.isEmpty ? repos : repos.filter { $0.nameWithOwner.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub 저장소 열기").font(.title2.bold())
            TextField("owner/repo 또는 저장소 URL — 목록에서 검색", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(openSelected)

            Group {
                if loading {
                    ProgressView("저장소 목록을 불러오는 중…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if repos.isEmpty {
                    Text("gh CLI로 목록을 불러올 수 없습니다.\n위에 owner/repo 를 직접 입력하세요.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered, id: \.nameWithOwner, selection: $selection) { repo in
                        HStack {
                            Image(systemName: repo.isPrivate ? "lock.fill" : "globe")
                                .foregroundStyle(repo.isPrivate ? .orange : .secondary)
                                .frame(width: 18)
                            Text(repo.nameWithOwner)
                        }
                        .tag(repo.nameWithOwner)
                    }
                    .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { _ in openSelected() }
                }
            }
            .frame(height: 300)

            HStack {
                Text("처음 열 때 \(AppModel.reposDirectory.path)에 클론됩니다")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("열기", action: openSelected)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil && query.trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await loadRepos() }
    }

    private func openSelected() {
        let spec = selection ?? query.trimmed
        guard !spec.isEmpty else { return }
        dismiss()
        Task { await model.clone(spec) }
    }

    private func loadRepos() async {
        defer { loading = false }
        guard let gh = Shell.ghPath else { return }
        let r = await Shell.run(gh, ["repo", "list", "--limit", "300", "--json", "nameWithOwner,isPrivate"])
        guard r.status == 0, let data = r.stdout.data(using: .utf8),
              let list = try? JSONDecoder().decode([RemoteRepo].self, from: data) else { return }
        repos = list.sorted { ($0.isPrivate ? 0 : 1, $0.nameWithOwner.lowercased()) < ($1.isPrivate ? 0 : 1, $1.nameWithOwner.lowercased()) }
    }
}
