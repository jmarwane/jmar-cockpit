# Writing tools for Cue

Cue runs your command as `<shell> -c '<command>'`. It runs in the item's folder, with the environment captured from your login shell. stdin is `/dev/null`, so anything that waits for input gets end-of-file instead of hanging.

## Inputs arrive as environment variables

An input named `PORT` reaches the command as the environment variable `PORT`. Quote it when you use it:

```sh
npm run dev -- --port "$PORT"
```

Cue never pastes input values into the command text, so a value like `; rm -rf ~` stays a harmless string. The **port** and **address** fields are the exception: Cue fills in `$PORT` there itself, because it uses them for the check and for "Open". A port must resolve to a number from 1 to 65535.

## `CUE=1`

Every command Cue runs has `CUE=1` set. Use it to keep a script quiet, or to skip interactive bits, when Cue is the one running it:

```sh
if [ -n "$CUE" ]; then
  exec >/dev/null   # no chatter; Cue only needs the result line
fi
```

## Telling Cue what happened: `::cue result` and `::cue reason`

Cue reads two kinds of line from a command's output. If either appears more than once, the last one wins. Nothing else in the output is parsed.

- `::cue result <text>` is shown in the Done subtitle: `Done · saved streams.csv · 2m ago`.
- `::cue reason <text>` is shown when the run fails: `Failed · API quota exceeded`.

```sh
#!/bin/sh
out="streams-$(date +%F).csv"
if ! fetch-streams > "$out"; then
  echo "::cue reason the streams API didn't answer"
  exit 1
fi
echo "::cue result saved $out"
```

"Done" means exit code 0 and nothing more. Cue can't know whether the output is right, so print a result line that lets you judge at a glance.

## Status commands: exit codes

A service can use a **status command** as its check. Cue runs it with a 5-second limit and reads only the exit code:

| Exit code | Shown as |
|---|---|
| 0 | **On** |
| 1 | **Off** |
| anything else, a timeout, or a failure to run | **Unknown**, with the first line of stderr as the reason |

Use Unknown honestly. If you can't tell (the daemon you'd ask is down, say), exit 2 and print why on stderr.

### Example: a Docker container

```sh
# Exit 0 = running, 1 = stopped, 2 = Docker unreachable (shown as Unknown)
docker info >/dev/null 2>&1 || exit 2
[ "$(docker inspect -f '{{.State.Running}}' web-db 2>/dev/null)" = true ] && exit 0 || exit 1
```

Pair it with **Start** `docker start web-db` and **Stop by** command `docker stop web-db`. `docker start` returns as soon as it has asked Docker to start the container, and that's fine: Cue keeps checking until the status command says On, for up to 30 seconds.

### Why `docker ps -q -f name=web-db` is a bad check

`docker ps` exits 0 whenever Docker answers, whether or not any container matches. Its exit code only says "Docker is up", not "web-db is running", so Cue would show **On** for a stopped container. The filter changes what it prints, not how it exits. Check the container's state directly, as in the example above.

## Choosing a check

- **Its process is alive**: for commands that stay in the foreground, like `npm run dev` or `python -m http.server`. Cue only sees processes it started itself. A command that exits within 3 seconds counts as failed, because it probably started something in the background.
- **A port responds**: for anything that listens on a port. It's the simplest honest check, and it also notices a server you started yourself in Terminal.
- **A status command**: for everything else, especially services another manager owns (Docker, `brew services`, launchd).
