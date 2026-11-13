import Foundation

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var errorText: String {
        let text = stderr.isEmpty ? stdout : stderr
        return text.trimmed
    }
}

struct GittyError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum Shell {
    static let gitPath = "/usr/bin/git"

    /// GitHub CLI 경로 (설치되어 있으면 인증 헬퍼로 사용)
    static let ghPath: String? = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static func run(_ executable: String, _ args: [String], cwd: URL? = nil) async -> CommandResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                if let cwd { process.currentDirectoryURL = cwd }

                var env = ProcessInfo.processInfo.environment
                // Finder에서 실행하면 PATH가 최소한이라 Homebrew 경로를 보강
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                env["GIT_TERMINAL_PROMPT"] = "0"   // 인증 프롬프트로 멈추지 않도록
                process.environment = env

                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    cont.resume(returning: CommandResult(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }

                // stdout/stderr를 동시에 읽어 파이프 버퍼가 꽉 차서 멈추는 것을 방지
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                cont.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)))
            }
        }
    }
}
