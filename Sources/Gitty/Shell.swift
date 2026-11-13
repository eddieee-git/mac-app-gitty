import Foundation

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var errorText: String {
        let text = stderr.isEmpty ? stdout : stderr
        return Log.redact(text.trimmed)   // 오류 창에도 토큰이 보이지 않게
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

    /// onStderrLine: stderr를 줄 단위(\r, \n 기준)로 바로바로 넘겨 받는다. git 진행률 표시용.
    /// stdoutTo: stdout을 이 파일에 그대로 쓴다 (사진 같은 바이너리 내용용). 이때 결과의 stdout은 비어 있다.
    static func run(_ executable: String, _ args: [String], cwd: URL? = nil, stdoutTo: URL? = nil,
                    onStderrLine: (@Sendable (String) -> Void)? = nil) async -> CommandResult {
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
                env["GIT_LFS_FORCE_PROGRESS"] = "1" // 파이프로 받아도 LFS 진행률을 출력하게
                process.environment = env

                let outPipe = Pipe(), errPipe = Pipe()
                var outFile: FileHandle?
                if let stdoutTo {
                    FileManager.default.createFile(atPath: stdoutTo.path, contents: nil)
                    outFile = try? FileHandle(forWritingTo: stdoutTo)
                }
                process.standardOutput = outFile ?? outPipe
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
                    let handle = errPipe.fileHandleForReading
                    if let onStderrLine {
                        var pending = Data()
                        while true {
                            let chunk = handle.availableData
                            if chunk.isEmpty { break }
                            errData.append(chunk)
                            pending.append(chunk)
                            while let i = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                                let line = String(decoding: pending[pending.startIndex..<i], as: UTF8.self)
                                pending = Data(pending[(i + 1)...])
                                if !line.isEmpty { onStderrLine(line) }
                            }
                        }
                    } else {
                        errData = handle.readDataToEndOfFile()
                    }
                    group.leave()
                }
                let outData = outFile == nil ? outPipe.fileHandleForReading.readDataToEndOfFile() : Data()
                group.wait()
                process.waitUntilExit()
                try? outFile?.close()

                cont.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)))
            }
        }
    }
}
