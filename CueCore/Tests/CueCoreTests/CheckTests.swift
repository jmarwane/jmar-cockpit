@testable import CueCore
import Foundation
import Testing

@Suite struct CheckTests {
    @Test func portProbeSeesAListenerAndAClosedPort() async throws {
        let listener = try TestListener()
        #expect(await PortProbe.isAnswering(port: listener.port))
        let reserved = try TestListener(listening: false)
        #expect(!(await PortProbe.isAnswering(port: reserved.port)))
        reserved.stop()
    }

    private func statusLaunch(_ command: String) throws -> LaunchSpec {
        let dir = NSTemporaryDirectory()
        let item = Item(kind: .service, name: "S", workingDirectory: dir, shell: .sh)
        return try LaunchSpec.make(command: command, for: item, inputs: [:], baseEnvironment: minimalEnvironment, secrets: InMemorySecretStore())
    }

    @Test func statusCommandExitCodes() async throws {
        #expect(await StatusCommand.check(try statusLaunch("exit 0")) == .on)
        #expect(await StatusCommand.check(try statusLaunch("echo noise >&2; exit 1")) == .off)
        #expect(await StatusCommand.check(try statusLaunch("echo \"Docker isn't responding\" >&2; echo second >&2; exit 2"))
            == .unknown("Docker isn't responding"))
        #expect(await StatusCommand.check(try statusLaunch("exit 3")) == .unknown("Status command exited with code 3"))
    }

    @Test func statusCommandTimeoutIsUnknown() async throws {
        let started = ContinuousClock.now
        let result = await StatusCommand.check(try statusLaunch("sleep 30"), timeout: .milliseconds(300))
        #expect(result == .unknown("Status command timed out after 0 s"))
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func statusCommandThatCantLaunchIsUnknown() async throws {
        var launch = try statusLaunch("exit 0")
        launch.shell = "/nonexistent/shell"
        guard case .unknown(let reason?) = await StatusCommand.check(launch) else {
            Issue.record("expected unknown with a reason")
            return
        }
        #expect(reason.hasPrefix("Couldn't run the status command"))
    }
}
