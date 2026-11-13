import Foundation
import CryptoKit

/// 내 폴더와 Git 폴더를 비교해서 한쪽을 다른 쪽과 같게 맞춘다 (ForkLift의 "동기화"와 같은 것).
enum FolderSync {
    enum Direction: String, CaseIterable, Identifiable {
        case toRepo, toLocal
        var id: String { rawValue }
    }

    struct Plan: Equatable {
        /// 보낼 것: 상대에 없는 파일
        var added: [String] = []
        /// 보낼 것: 양쪽에 있지만 내용이 다른 파일
        var changed: [String] = []
        /// 받는 쪽에만 있는 파일 (지우기를 켜면 지운다)
        var extra: [String] = []
        /// 너무 많아서 중간에 멈춤
        var partial = false

        var isEmpty: Bool { added.isEmpty && changed.isEmpty && extra.isEmpty }
    }

    static let skipNames: Set<String> = [".git", ".DS_Store", ".gitkeep"]
    static let fileLimit = 20_000

    /// 폴더 안의 파일들 (상대 경로 → 크기). 숨김 파일도 포함하되 .git 등은 뺀다.
    static func files(in root: URL) -> (files: [String: Int64], partial: Bool) {
        var result: [String: Int64] = [:]
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: base), includingPropertiesForKeys: keys) else {
            return ([:], false)
        }
        while let url = e.nextObject() as? URL {
            if Task.isCancelled || Cancellation.isRequested { return (result, true) }
            let v = try? url.resourceValues(forKeys: Set(keys))
            if skipNames.contains(url.lastPathComponent) {
                // 폴더(.git)일 때만 안으로 들어가지 않게 한다. 파일에 부르면 직전 폴더를 통째로 건너뛴다.
                if v?.isDirectory == true { e.skipDescendants() }
                continue
            }
            if v?.isDirectory == true && v?.isPackage != true { continue }
            if v?.isPackage == true { e.skipDescendants() }   // 패키지는 통째로 하나로 본다 (크기 비교는 생략)
            let rel = String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(base.count + 1))
            result[rel] = Int64(v?.fileSize ?? 0)
            if result.count >= fileLimit { return (result, true) }
        }
        return (result, false)
    }

    /// 두 파일 내용이 같은지 (크기가 같을 때만 부른다)
    static func sameContent(_ a: URL, _ b: URL) -> Bool {
        func digest(_ u: URL) -> Data? {
            guard let h = try? FileHandle(forReadingFrom: u) else { return nil }
            defer { try? h.close() }
            var hasher = SHA256()
            while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return Data(hasher.finalize())
        }
        return digest(a) == digest(b)
    }

    /// from 폴더를 기준으로 to 폴더와 무엇이 다른지
    static func compare(from: URL, to: URL) -> Plan {
        let (src, p1) = files(in: from)
        let (dst, p2) = files(in: to)
        var plan = Plan(partial: p1 || p2)
        for (path, size) in src.sorted(by: { $0.key < $1.key }) {
            guard let other = dst[path] else { plan.added.append(path); continue }
            // LFS 포인터만 있는 Git 파일은 내용 비교를 할 수 없어서 크기로만 본다
            if other != size {
                if !GitRepo.isLFSPointer(to.appendingPathComponent(path)) && !GitRepo.isLFSPointer(from.appendingPathComponent(path)) {
                    plan.changed.append(path)
                }
            } else if !sameContent(from.appendingPathComponent(path), to.appendingPathComponent(path)) {
                plan.changed.append(path)
            }
        }
        plan.extra = dst.keys.filter { src[$0] == nil }.sorted()
        return plan
    }
}
