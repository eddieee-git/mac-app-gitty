import Foundation

struct FileItem: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?

    var id: URL { url }
    var name: String { url.lastPathComponent }

    /// 폴더 내용을 폴더 먼저, 이름순으로 정렬해 돌려준다.
    static func list(in dir: URL, hiding isHidden: (String) -> Bool) -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return urls
            .filter { !isHidden($0.lastPathComponent) }
            .map { url in
                let v = try? url.resourceValues(forKeys: Set(keys))
                return FileItem(url: url,
                                isDirectory: v?.isDirectory ?? false,
                                size: v?.fileSize.map(Int64.init),
                                modified: v?.contentModificationDate)
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }
}

enum FileOps {
    /// 항목들을 dir 안으로 복사한다. 같은 이름이 있으면 기존 것은 휴지통으로 보낸다.
    static func copy(_ urls: [URL], into dir: URL) throws {
        let fm = FileManager.default
        let dirPath = dir.standardizedFileURL.path
        for src in urls {
            let srcPath = src.standardizedFileURL.path
            if (srcPath as NSString).deletingLastPathComponent == dirPath { continue }   // 이미 같은 폴더
            if (dirPath + "/").hasPrefix(srcPath + "/") {
                throw GittyError(message: "폴더를 자기 자신 안으로 복사할 수 없습니다: \(src.lastPathComponent)")
            }
            let dst = dir.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dst.path) {
                try fm.trashItem(at: dst, resultingItemURL: nil)
            }
            try fm.copyItem(at: src, to: dst)
        }
    }

    static func trash(_ urls: [URL]) throws {
        for url in urls {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// 대소문자만 바뀌는 이름 변경도 처리한다 (APFS는 기본적으로 대소문자 구분 안 함).
    static func rename(_ url: URL, to newName: String) throws {
        let fm = FileManager.default
        let dst = url.deletingLastPathComponent().appendingPathComponent(newName)
        if url.lastPathComponent.lowercased() == newName.lowercased() {
            let tmp = url.deletingLastPathComponent().appendingPathComponent(".gitty-rename-\(UUID().uuidString)")
            try fm.moveItem(at: url, to: tmp)
            try fm.moveItem(at: tmp, to: dst)
        } else {
            guard !fm.fileExists(atPath: dst.path) else {
                throw GittyError(message: "같은 이름의 항목이 이미 있습니다: \(newName)")
            }
            try fm.moveItem(at: url, to: dst)
        }
    }

    static func validateName(_ name: String) -> String? {
        let name = name.trimmed
        if name.isEmpty { return nil }
        if name.contains("/") || name == "." || name == ".." { return nil }
        return name
    }
}
