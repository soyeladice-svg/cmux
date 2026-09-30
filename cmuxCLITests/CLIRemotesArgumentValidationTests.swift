import Foundation
import Testing

@Suite(.serialized)
struct CLIRemotesArgumentValidationTests {
    @Test func listRejectsTrailingArgumentsBeforeSocketDispatch() async throws {
        for arguments in [
            ["remotes", "list", "--typo"],
            ["remotes", "list", "unexpected"],
        ] {
            let run = try await run(arguments)
            #expect(run.status != 0, Comment(rawValue: arguments.joined(separator: " ")))
            #expect(run.request == nil)
        }
    }

    @Test func removeRejectsUnknownFlagsAndExtraPositionalsBeforeSocketDispatch() async throws {
        for arguments in [
            ["remotes", "remove", "studio", "--typo"],
            ["remotes", "remove", "studio", "unexpected"],
        ] {
            let run = try await run(arguments)
            #expect(run.status != 0, Comment(rawValue: arguments.joined(separator: " ")))
            #expect(run.request == nil)
        }
    }

    @Test func listAndRemoveKeepJsonAsTheSupportedOutputFlag() async throws {
        let list = try await run(["remotes", "list", "--json"])
        #expect(list.status == 0, Comment(rawValue: list.output))
        #expect(list.request?["method"] as? String == "remotes.list")

        let remove = try await run(["remotes", "remove", "studio", "--json"])
        #expect(remove.status == 0, Comment(rawValue: remove.output))
        #expect(remove.request?["method"] as? String == "remotes.remove")
        let params = try #require(remove.request?["params"] as? [String: Any])
        #expect(params["target"] as? String == "studio")
    }

    private struct Run {
        let status: Int32
        let output: String
        let request: [String: Any]?
    }

    private func run(_ arguments: [String]) async throws -> Run {
        let socketPath = Self.socketPath()
        let server = try CLIWorkspaceGroupSafetyMockServer(socketPath: socketPath)
        let requestTask = server.start()

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "2"

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(
            fileURLWithPath: try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self)
        )
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { completedProcess in
                continuation.resume(returning: completedProcess.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        let output = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let requestLine = await requestTask.value
        let request = requestLine.flatMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        return Run(status: status, output: output, request: request)
    }

    private static func socketPath() -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-remotes-args-\(suffix).sock")
            .path
    }

    private final class BundleToken {}
}
