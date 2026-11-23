import Foundation

/// git이 내는 영어 오류를 알아듣기 쉬운 말과 할 일로 바꾼다. 원문은 작업 기록에 그대로 남는다.
enum GitErrors {
    enum Kind: Equatable {
        case offline, auth, notFound, denied, tooLarge, diskFull, locked
    }

    static func kind(of raw: String) -> Kind? {
        let t = raw.lowercased()
        func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }
        if has("could not resolve host", "failed to connect", "network is unreachable", "operation timed out",
               "connection timed out", "connection refused", "couldn't connect to server", "no route to host",
               "the internet connection appears to be offline", "ssl_connect", "unable to access 'https") &&
            !has("403", "401", "authentication") {
            return .offline
        }
        if has("authentication failed", "could not read username", "terminal prompts disabled", "invalid username or password",
               "401", "bad credentials") {
            return .auth
        }
        if has("repository not found", "not found") && has("remote:", "repository") { return .notFound }
        if has("permission to", "403", "denied to", "protected branch") && !has("permission denied (publickey)") { return .denied }
        if has("gh001", "exceeds github's file size limit", "large files detected") { return .tooLarge }
        if has("no space left on device") { return .diskFull }
        if has("index.lock", "another git process seems to be running") { return .locked }
        return nil
    }

    /// 사용자에게 보여 줄 말. 모르는 오류면 원문 그대로.
    static func friendly(_ raw: String) -> String {
        guard let kind = kind(of: raw) else { return raw }
        let message: String
        switch kind {
        case .offline:
            message = offlineMessage
        case .auth:
            message = tr("GitHub 로그인이 풀렸어요. 터미널에서 gh auth login 을 실행한 뒤 다시 시도해 주세요.")
        case .notFound:
            message = tr("GitHub에서 저장소를 찾을 수 없어요. 주소가 맞는지, 이 계정에 권한이 있는지 확인해 주세요.")
        case .denied:
            message = tr("이 저장소에 올릴 권한이 없어요. 저장소 주인에게 쓰기 권한을 받아야 해요.")
        case .tooLarge:
            message = tr("GitHub은 100MB가 넘는 파일을 일반 파일로 받지 않아요. git-lfs를 설치하면 Gitty가 LFS로 올려요.")
        case .diskFull:
            message = tr("디스크 공간이 부족해요. 공간을 비운 뒤 다시 시도해 주세요.")
        case .locked:
            message = tr("다른 git 작업이 아직 끝나지 않았어요. 잠시 뒤 다시 시도해 주세요.")
        }
        return message + "\n\n" + tr("자세한 내용은 작업 기록(⌥⌘L)에 있어요.")
    }

    static let offlineMessage = tr("인터넷이나 GitHub에 연결할 수 없어요. 만든 커밋은 모아 뒀다가 연결되면 올려요.")

    static func isOffline(_ error: Error) -> Bool {
        if let e = error as? GittyError { return e.message.hasPrefix(offlineMessage) || kind(of: e.message) == .offline }
        return (error as? URLError) != nil
    }
}
