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
