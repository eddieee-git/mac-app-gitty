// 업데이트 파일(dmg) 서명 도구. Ed25519 키를 쓴다.
//
//   swift scripts/update-signing.swift keygen          키를 만들어 키체인에 저장하고 공개 키를 출력
//   swift scripts/update-signing.swift public-key      저장된 키의 공개 키 출력
//   swift scripts/update-signing.swift sign <파일>      서명(base64) 출력
//   swift scripts/update-signing.swift verify <파일> <서명파일> <공개키>
//
// 비밀 키는 로그인 키체인의 "Gitty Update Signing" 항목에만 있다. 잃어버리면 새 키로 바꾼 버전을
// 사용자가 한 번 직접 설치해야 하므로, 키체인 접근으로 내보내 안전한 곳에 백업해 두자.
import Foundation
import CryptoKit

let service = "Gitty Update Signing"
let account = "ed25519"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

@discardableResult
func security(_ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try! p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    let r = security(["find-generic-password", "-s", service, "-a", account, "-w"])
    guard r.status == 0, let raw = Data(base64Encoded: r.out),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("키체인에 서명 키가 없어요. 먼저 keygen을 실행하세요.")
    }
    return key
}

func read(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("파일을 읽을 수 없어요: \(path)") }
    return data
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "keygen":
    if security(["find-generic-password", "-s", service, "-a", account]).status == 0 {
        fail("이미 서명 키가 있어요. 공개 키는 public-key로 확인하세요.")
    }
    let key = Curve25519.Signing.PrivateKey()
    let r = security(["add-generic-password", "-s", service, "-a", account,
                      "-w", key.rawRepresentation.base64EncodedString()])
    guard r.status == 0 else { fail("키체인에 저장하지 못했어요") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public-key":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign" where args.count == 2:
    let signature = try loadKey().signature(for: read(args[1]))
    print(signature.base64EncodedString())
case "verify" where args.count == 4:
    let signatureText = String(decoding: read(args[2]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let signature = Data(base64Encoded: signatureText),
          let raw = Data(base64Encoded: args[3]),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { fail("서명이나 공개 키 형식이 잘못됐어요") }
    guard publicKey.isValidSignature(signature, for: read(args[1])) else { fail("서명이 맞지 않아요") }
    print("서명 확인 완료")
default:
    fail("사용: keygen | public-key | sign <파일> | verify <파일> <서명파일> <공개키>")
}
