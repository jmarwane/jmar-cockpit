@testable import CueCore
import Foundation
import Testing

@Suite struct LoginShellEnvironmentTests {
    @Test func ignoresStartupNoiseFromAFakeShell() async throws {
        let dir = try TemporaryDirectory()
        // A stand-in login shell: noisy on both streams, before and after the command.
        let shell = try dir.script("noisy-shell", """
        #!/bin/sh
        echo "Last login: Tue Oct 21 on ttys000"
        printf '\\033]0;title\\007%%s' "prompt> "
        echo "plugin warning" >&2
        export FROM_RC="hello world"
        export MULTI="line1
        line2"
        export EQUALS="a=b=c"
        /bin/sh -c "$2"
        echo "goodbye from .zlogout"
        """)

        let captured = await LoginShellEnvironment.capture(
            shell: shell, timeout: .seconds(5), baseEnvironment: minimalEnvironment
        )

        #expect(captured.source == .interactiveLogin)
        #expect(captured.variables["FROM_RC"] == "hello world")
        #expect(captured.variables["MULTI"] == "line1\nline2")
        #expect(captured.variables["EQUALS"] == "a=b=c")
        #expect(captured.path == minimalEnvironment["PATH"])
        #expect(captured.variables["SHLVL"] == nil)
        #expect(captured.variables.keys.allSatisfy { !$0.contains("Last login") && !$0.contains("prompt") })
    }

    @Test func capturesFromRealZshWithANoisyConfig() async throws {
        let dir = try TemporaryDirectory()
        // ZDOTDIR points zsh at fixture dotfiles instead of the user's own.
        try dir.file(".zshrc", """
        echo "Welcome to the noisy zshrc"
        print -P "%n@%m %~ %# "
        echo "stderr noise" >&2
        export CUE_FIXTURE_RC=from-zshrc
        path=(/cue/fixture/bin $path)
        """)
        try dir.file(".zprofile", "export CUE_FIXTURE_PROFILE=from-zprofile\n")

        var base = minimalEnvironment
        base["ZDOTDIR"] = dir.path
        let captured = await LoginShellEnvironment.capture(
            shell: "/bin/zsh", timeout: .seconds(5), baseEnvironment: base
        )

        #expect(captured.source == .interactiveLogin)
        #expect(captured.variables["CUE_FIXTURE_RC"] == "from-zshrc")
        #expect(captured.variables["CUE_FIXTURE_PROFILE"] == "from-zprofile")
        #expect(captured.path.hasPrefix("/cue/fixture/bin:"))
    }

    @Test func fallsBackToLoginWhenInteractiveHangs() async throws {
        let dir = try TemporaryDirectory()
        let shell = try dir.script("hangs-when-interactive", """
        #!/bin/sh
        if [ "$1" = "-ilc" ]; then sleep 30; fi
        export MODE="$1"
        exec /bin/sh -c "$2"
        """)

        let started = ContinuousClock.now
        let captured = await LoginShellEnvironment.capture(
            shell: shell, timeout: .milliseconds(500), baseEnvironment: minimalEnvironment
        )

        #expect(captured.source == .login)
        #expect(captured.variables["MODE"] == "-lc")
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func fallsBackToTheDefaultPathWhenTheShellFails() async throws {
        let dir = try TemporaryDirectory()
        let shell = try dir.script("broken-shell", "#!/bin/sh\necho 'zsh: corrupt history file'\nexit 1\n")

        let captured = await LoginShellEnvironment.capture(
            shell: shell, timeout: .seconds(2), baseEnvironment: ["HOME": "/tmp", "PATH": "/usr/bin"]
        )

        #expect(captured.source == .fallback)
        #expect(captured.path == LoginShellEnvironment.defaultPATH)
        #expect(captured.path.contains("/opt/homebrew/bin"))
        #expect(captured.path.contains("/usr/local/bin"))
        #expect(captured.variables["HOME"] == "/tmp")
    }

    @Test func fallsBackWhenTheShellCannotLaunch() async {
        let captured = await LoginShellEnvironment.capture(
            shell: "/nonexistent/shell", timeout: .seconds(1), baseEnvironment: minimalEnvironment
        )
        #expect(captured.source == .fallback)
    }

    @Test func parsesOnlyBetweenTheMarkers() {
        let output = Data("A=noise\0__S__X=1\0Y=two\nlines\0=bad\0__E__Z=after".utf8)
        let parsed = LoginShellEnvironment.parse(output, start: "__S__", end: "__E__")
        #expect(parsed == ["X": "1", "Y": "two\nlines"])
        #expect(LoginShellEnvironment.parse(Data("no markers".utf8), start: "__S__", end: "__E__") == nil)
    }
}
