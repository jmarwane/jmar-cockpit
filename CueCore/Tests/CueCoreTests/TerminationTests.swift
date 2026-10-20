@testable import CueCore
import Testing

@Suite struct TerminationTests {
    @Test func decodesExitAndSignalStatuses() {
        #expect(Termination(waitStatus: 0) == .exited(0))
        #expect(Termination(waitStatus: 3 << 8) == .exited(3))
        #expect(Termination(waitStatus: 15) == .signaled(15))
        #expect(Termination(waitStatus: 9) == .signaled(9))
    }
}
