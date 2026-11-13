import SwiftUI

/// Git 쪽 파일 옆에 붙는 상태 표시
enum FileBadge: Equatable {
    /// 저장소 폴더에서 직접 고쳤지만 아직 올리지 않음 (예: 파일을 열어서 고치고 저장)
    case modified
    /// 저장소 폴더에 새로 생겼지만 Git에는 없음
    case untracked
    /// 커밋은 했지만 아직 GitHub에 올라가지 않음
    case unpushed
    /// 큰 파일(LFS)인데 아직 내용을 받지 않음
    case cloudOnly

    var symbol: String {
        switch self {
        case .modified: "pencil.circle.fill"
        case .untracked: "plus.circle.fill"
        case .unpushed: "arrow.up.circle.fill"
        case .cloudOnly: "icloud.and.arrow.down"
        }
    }

    var color: Color {
        switch self {
        case .modified: .orange
        case .untracked: .green
        case .unpushed: .blue
        case .cloudOnly: .secondary
        }
    }

    var help: String {
        switch self {
        case .modified: tr("고쳤지만 아직 올리지 않았어요 (오른쪽 클릭 → 바뀐 내용 올리기)")
        case .untracked: tr("저장소 폴더에 있지만 Git에는 없어요 (오른쪽 클릭 → 바뀐 내용 올리기)")
        case .unpushed: tr("커밋했지만 아직 GitHub에 올라가지 않았어요")
        case .cloudOnly: tr("큰 파일이라 아직 받지 않았어요. 열거나 복사하면 받아요")
        }
    }
}

/// 저장소 전체의 파일 상태 (저장소 기준 경로 → 상태). 폴더는 안에 바뀐 게 있으면 같은 표시.
struct RepoStatus: Equatable {
    var files: [String: FileBadge] = [:]
    var folders: [String: FileBadge] = [:]

    var changedCount: Int { files.values.filter { $0 == .modified || $0 == .untracked }.count }
    var changedPaths: [String] { files.filter { $0.value == .modified || $0.value == .untracked }.map(\.key).sorted() }

    func badge(for path: String, isDirectory: Bool) -> FileBadge? {
        isDirectory ? folders[path] : files[path]
    }

    /// 우선순위: 고침 > 새 파일 > 올리기 전 > 안 받음
    static func rank(_ b: FileBadge) -> Int {
        switch b { case .modified: 0; case .untracked: 1; case .unpushed: 2; case .cloudOnly: 3 }
    }

    mutating func set(_ path: String, _ badge: FileBadge) {
        if let old = files[path], Self.rank(old) <= Self.rank(badge) { return }
        files[path] = badge
        var dir = (path as NSString).deletingLastPathComponent
        while !dir.isEmpty {
            if let old = folders[dir], Self.rank(old) <= Self.rank(badge) { break }
            folders[dir] = badge
            dir = (dir as NSString).deletingLastPathComponent
        }
    }
}
