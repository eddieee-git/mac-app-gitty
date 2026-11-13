import Foundation

struct FileItem: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    /// 검색 결과일 때: 검색한 폴더 기준 위치 ("" = 그 폴더 바로 아래)
    var location: String? = nil

    var id: URL { url }
    var name: String { url.lastPathComponent }

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey,
    ]

    /// 폴더 내용을 폴더 먼저, 이름순으로 정렬해 돌려준다.
    /// includeHidden이 false면 점(.)으로 시작하거나 Finder에서 숨긴 항목(~/Library 등)을 뺀다.
    /// alwaysHidden은 설정과 상관없이 늘 뺀다 (.git, .DS_Store 등).
    static func list(in dir: URL, includeHidden: Bool, alwaysHidden: Set<String>) -> [FileItem] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url -> FileItem? in
            let name = url.lastPathComponent
            if alwaysHidden.contains(name) { return nil }
            let v = try? url.resourceValues(forKeys: Set(keys))
            if !includeHidden && (name.hasPrefix(".") || v?.isHidden == true) { return nil }
            // .app 같은 패키지는 Finder처럼 파일 하나로 다룬다
            let isFolder = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
            return FileItem(url: url,
                            isDirectory: isFolder,
                            size: v?.fileSize.map(Int64.init),
                            modified: v?.contentModificationDate)
        }
        .sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// 하위 폴더까지 이름으로 찾는다 (대소문자·한글 자모 조합 차이 무시). 백그라운드에서 부른다.
    static func search(_ query: String, in root: URL, includeHidden: Bool, alwaysHidden: Set<String>,
                       limit: Int = 1000) -> [FileItem] {
        let needle = query.trimmed
        guard !needle.isEmpty else { return [] }
        let rootPath = root.standardizedFileURL.path
        var results: [FileItem] = []
        var queue: [URL] = [root]
        while !queue.isEmpty, results.count < limit {
            if Task.isCancelled { return results }
            let dir = queue.removeFirst()
            for item in list(in: dir, includeHidden: includeHidden, alwaysHidden: alwaysHidden) {
                if item.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil {
                    var found = item
                    let parent = item.url.deletingLastPathComponent().standardizedFileURL.path
                    found.location = parent == rootPath ? "" : String(parent.dropFirst(rootPath.count + 1))
                    results.append(found)
                    if results.count >= limit { break }
                }
                if item.isDirectory { queue.append(item.url) }
            }
        }
        return results
    }

    /// 폴더 트리용: 하위 폴더만
    static func subfolders(of dir: URL, includeHidden: Bool, alwaysHidden: Set<String>) -> [URL] {
        list(in: dir, includeHidden: includeHidden, alwaysHidden: alwaysHidden)
            .filter(\.isDirectory)
            .map(\.url)
    }
}

enum FileOps {
    /// 항목들을 dir 안으로 복사한다. 같은 이름이 있으면 기존 것은 휴지통으로 보낸다.
    static func copy(_ urls: [URL], into dir: URL, progress: ((Int64) -> Void)? = nil) throws {
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
            try copyTree(src, to: dst, progress: progress)
        }
    }

    /// 같은 디스크 안에서 옮긴다. 같은 이름이 있으면 기존 것은 휴지통으로 보낸다.
    static func move(_ urls: [URL], into dir: URL) throws {
        let fm = FileManager.default
        let dirPath = dir.standardizedFileURL.path
        for src in urls {
            let srcPath = src.standardizedFileURL.path
            if (srcPath as NSString).deletingLastPathComponent == dirPath { continue }
            if (dirPath + "/").hasPrefix(srcPath + "/") {
                throw GittyError(message: "폴더를 자기 자신 안으로 옮길 수 없습니다: \(src.lastPathComponent)")
            }
            let dst = dir.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dst.path) {
                try fm.trashItem(at: dst, resultingItemURL: nil)
            }
            try fm.moveItem(at: src, to: dst)
        }
    }

    /// 파일·폴더 전체 크기 (폴더 안의 .git은 뺀다)
    static func totalSize(_ urls: [URL]) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        var total: Int64 = 0
        for url in urls {
            if (try? url.resourceValues(forKeys: keys))?.isDirectory == true {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
                while let u = e?.nextObject() as? URL {
                    if u.lastPathComponent == ".git" { e?.skipDescendants(); continue }
                    total += Int64((try? u.resourceValues(forKeys: keys))?.fileSize ?? 0)
                }
            } else {
                total += Int64((try? url.resourceValues(forKeys: keys))?.fileSize ?? 0)
            }
        }
        return total
    }

    /// 파일 하나 복사. 큰 파일은 4MB씩 나눠 복사하면서 진행률을 알린다.
    /// (Google Drive 온라인 전용 파일도 읽는 동안 내려받아진다)
    static func copyFile(_ src: URL, to dst: URL, progress: ((Int64) -> Void)?) throws {
        let fm = FileManager.default
        let size = Int64((try? src.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        guard let progress, size >= 8 * 1024 * 1024 else {
            try fm.copyItem(at: src, to: dst)
            progress?(size)
            return
        }
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        guard fm.createFile(atPath: dst.path, contents: nil) else {
            throw GittyError(message: "파일을 만들 수 없습니다: \(dst.path)")
        }
        let output = try FileHandle(forWritingTo: dst)
        do {
            while let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
                progress(Int64(chunk.count))
            }
            try output.close()
        } catch {
            try? output.close()
            try? fm.removeItem(at: dst)
            throw error
        }
        // 실행 권한·수정 시각은 그대로 옮긴다
        if let attrs = try? fm.attributesOfItem(atPath: src.path) {
            try? fm.setAttributes([.posixPermissions: attrs[.posixPermissions] as Any,
                                   .modificationDate: attrs[.modificationDate] as Any].compactMapValues { $0 },
                                  ofItemAtPath: dst.path)
        }
    }

    /// 폴더째 복사 (진행률용). skip에 걸리는 이름은 건너뛴다.
    static func copyTree(_ src: URL, to dst: URL, skip: Set<String> = [], progress: ((Int64) -> Void)?) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            for child in try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) where !skip.contains(child.lastPathComponent) {
                try copyTree(child, to: dst.appendingPathComponent(child.lastPathComponent), skip: skip, progress: progress)
            }
        } else {
            try copyFile(src, to: dst, progress: progress)
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

/// 폴더 안에 이미 있는 이름들
func existingNames(in dir: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
}
