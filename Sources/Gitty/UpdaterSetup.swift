import AppKit

/// 공통 업데이트(AppUpdater.swift)에 Gitty 정보를 넣는다. AppUpdater.swift는 mac-app/shared에서 복사해 오므로 여기만 고친다.
extension AppUpdater {
    /// 업데이트 서명 공개 키. Info.plist의 GittyUpdatePublicKey (scripts/release.sh가 같은 값을 읽는다).
    nonisolated static let appPublicKey = Bundle.main.object(forInfoDictionaryKey: "GittyUpdatePublicKey") as? String ?? ""
    nonisolated static let appSignatureFormat = SignatureFormat.dmg

    static let shared = AppUpdater(.init(
        appName: "Gitty",
        repo: "eddieee-git/mac-app-gitty",
        publicKey: appPublicKey,
        signatureFormat: appSignatureFormat,
        isEnglish: { Loc.isEnglish },
        // 올리는 중이거나 아직 올리지 않은 커밋이 있으면 다시 시작하지 않는다.
        canRestartNow: { MainActor.assumeIsolated { AppModel.live.allSatisfy { !$0.isBusy && !$0.pushPending } } },
        log: { Log.info("update", $0) }
    ))
}
