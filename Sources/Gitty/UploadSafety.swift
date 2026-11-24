import Foundation

/// 올리기 전에 비밀 정보가 들어 있을 법한 파일을 찾는다.
/// Git에 한 번 올라간 파일은 지워도 기록에 남기 때문에, 이런 파일은 올리기 전에 꼭 묻는다.
enum UploadSafety {
    /// 이름이 정확히 같으면
    static let exactNames: Set<String> = [
        ".env", ".npmrc", ".netrc", ".pypirc", ".git-credentials", ".htpasswd",
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credentials", "credentials.json",
        "secrets.json", "secrets.yml", "secrets.yaml", "service-account.json", "keystore.jks",
    ]
    /// 이 확장자면
    static let extensions: Set<String> = ["pem", "key", "p12", "pfx", "keystore", "jks", "kdbx", "ovpn", "asc", "gpg"]

    static func isSensitive(_ name: String) -> Bool {
        let lower = name.lowercased()
        if exactNames.contains(lower) { return true }
        if lower.hasPrefix(".env.") && lower != ".env.example" && lower != ".env.sample" { return true }
        if lower.hasPrefix("service-account") && lower.hasSuffix(".json") { return true }
        if lower.hasPrefix("id_") && !lower.hasSuffix(".pub") && ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"].contains(where: lower.hasPrefix) { return true }
        let ext = (lower as NSString).pathExtension
        return extensions.contains(ext)
    }

    /// 올릴 항목(폴더면 안쪽까지) 중 비밀 정보일 수 있는 파일. 이름만 본다. 너무 많으면 limit에서 멈춘다.
    static func sensitiveFiles(in urls: [URL], limit: Int = 20_000) -> [String] {
        var found: [String] = []
        var seen = 0
        for url in urls {
            let base = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            func rel(_ u: URL) -> String { String(u.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(base.count + 1)) }
            if isSensitive(url.lastPathComponent) { found.append(url.lastPathComponent) }
            guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { continue }
            while let child = e.nextObject() as? URL {
                seen += 1
                if seen > limit { return found }
                if child.lastPathComponent == ".git" { e.skipDescendants(); continue }
                if isSensitive(child.lastPathComponent) { found.append(rel(child)) }
            }
        }
        return found
    }
}

extension UploadSafety {
    /// 내용에서 찾는 비밀 정보 형식 (이름, 정규식). gitleaks 같은 도구가 찾는 대표적인 것들.
    static let contentPatterns: [(String, NSRegularExpression)] = [
        (tr("비밀 키"), #"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY-----"#),
        (tr("AWS 키"), #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        (tr("GitHub 토큰"), #"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})"#),
        (tr("Slack 토큰"), #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#),
        (tr("Google API 키"), #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
        (tr("Stripe 키"), #"\b(?:sk|rk)_live_[0-9A-Za-z]{20,}"#),
        (tr("API 키"), #"\bsk-(?:proj-|ant-)?[A-Za-z0-9_\-]{32,}"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// 올릴 항목의 내용에서 비밀 정보 형식을 찾는다. 작은 텍스트 파일만 본다 (1MB 이하, 바이너리 제외).
    /// 돌려주는 값: "경로 (종류)"
    static func contentFindings(in urls: [URL], fileLimit: Int = 3000, sizeLimit: Int = 1 << 20) -> [String] {
        var found: [String] = []
        var checked = 0
        func scan(_ file: URL, _ shown: String) {
            guard checked < fileLimit else { return }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size > 0, size <= sizeLimit, !GitRepo.isLFSPointer(file),
                  let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return }
            checked += 1
            if data.prefix(8192).contains(0) { return }   // 바이너리
            let text = String(decoding: data, as: UTF8.self)
            let range = NSRange(text.startIndex..., in: text)
            for (label, pattern) in contentPatterns where pattern.firstMatch(in: text, range: range) != nil {
                found.append("\(shown) (\(label))")
                return
            }
        }
        for url in urls {
            let base = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue { scan(url, url.lastPathComponent); continue }
            let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey])
            while let child = e?.nextObject() as? URL {
                if child.lastPathComponent == ".git" { e?.skipDescendants(); continue }
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
                scan(child, String(child.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(base.count + 1)))
                if checked >= fileLimit { break }
            }
        }
        return found
    }

    /// 이름과 내용 둘 다 본 결과 (같은 파일은 한 번만)
    static func findings(in urls: [URL]) -> [String] {
        let names = sensitiveFiles(in: urls)
        let contents = contentFindings(in: urls).filter { item in !names.contains { item.hasPrefix($0 + " (") } }
        return names + contents
    }
}
