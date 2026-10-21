@testable import CueCore
import Foundation
import Testing

@Suite struct RunOutputTests {
    private func feed(_ output: RunOutput, _ text: String, _ stream: RunOutput.Stream = .stdout) {
        output.append(Data(text.utf8), from: stream)
    }

    @Test func tracksLastLineAndFirstErrorLine() {
        let output = RunOutput()
        feed(output, "compiling\nwarning: x\nError: listen EADDRINUSE :4000\nmore Error later\n")
        feed(output, "done\n\n   \n")
        #expect(output.lastLine == "done")
        #expect(output.firstErrorLine == "Error: listen EADDRINUSE :4000")
    }

    @Test func fallsBackToTheLastStderrLine() {
        let output = RunOutput()
        feed(output, "first problem\n", .stderr)
        feed(output, "all good\n")
        feed(output, "second problem\n", .stderr)
        #expect(output.firstErrorLine == "second problem")
        #expect(output.firstStderrLine == "first problem")
    }

    @Test func linesSplitAcrossChunksAndStreams() {
        let output = RunOutput()
        feed(output, "Trace")
        feed(output, "warn: half", .stderr)
        feed(output, "back (most recent)\n")
        feed(output, " line\n", .stderr)
        #expect(output.firstErrorLine == "Traceback (most recent)")
        #expect(output.lastStderrLine == "warn: half line")
    }

    @Test func cueDirectivesLastOneWins() {
        let output = RunOutput()
        feed(output, "::cue result saved a.csv\n::cue result saved streams.csv\n")
        feed(output, "::cue reason quota exceeded\n::cue reasonless\n::cue reason   \n")
        feed(output, "::cue result ignored because it's on stderr? no, stderr counts too\n", .stderr)
        #expect(output.result == "ignored because it's on stderr? no, stderr counts too")
        #expect(output.reason == "quota exceeded")
        // An empty directive isn't one; it's ordinary output.
        #expect(output.lastLine == "::cue reason")
    }

    @Test func carriageReturnsKeepTheLastFrame() {
        let output = RunOutput()
        feed(output, "10%\r50%\r100%\r\n")
        #expect(output.lastLine == "100%")
    }

    @Test func keepsOnlyTheTailAndCutsEndlessLines() {
        let output = RunOutput(limit: 10)
        feed(output, "0123456789abcdef")
        #expect(output.data == Data("6789abcdef".utf8))
        let long = RunOutput()
        feed(long, String(repeating: "x", count: RunOutput.maxLineLength + 5))
        #expect(long.lastLine?.count == RunOutput.maxLineLength + 5)
    }

    @Test func redactsSecretsEverywhere() {
        let output = RunOutput(redactor: Redactor(secrets: ["hunter22", "pw", "hunter2"]))
        feed(output, "token=hunter22\n")
        feed(output, "fatal: bad credentials hunter2 pw\n", .stderr)
        feed(output, "::cue reason rejected hunter22\n")
        #expect(output.text == "token=••••\nfatal: bad credentials •••• pw\n::cue reason rejected ••••\n")
        #expect(output.firstErrorLine == "fatal: bad credentials •••• pw")
        #expect(output.reason == "rejected ••••")
        #expect(!output.text.contains("hunter2"))
    }
}
