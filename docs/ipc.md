# IPC and bar

- The socket lives in a 0700 directory under Application Support. Peers are checked with
  `getpeereid`, and all I/O runs off the main actor.
- Each message on the socket is a frame: a 4 byte length in network byte order, then that
  many bytes of JSON body. A client sends one request,
  `{"args":["workspace","3"],"protocol":1}`. The server answers with one response,
  `{"exitCode":0,"stderr":"","stdout":"pong"}`, and closes, unless the response is held
  (below). A request with another protocol version gets an error response.
- The queries `ping`, `version`, `state`, `list-workspaces`, `list-windows` and
  `list-bindings` change nothing (`Query`). `handover [record version]`, which
  `script/install.sh` sends, arms a quit within 5 s to leave the hidden windows to the
  Kosmos that starts next ([hiding.md](hiding.md)). `peek <window id>` is the CLI's half of
  `kosmos peek`, below, and `claim` the half of `kosmos open`. Any other request is a
  command (`Command.parse`).
- `kosmos open [-a <app> | -b <bundle id>] [<file or URL>...] [open's options]` opens
  something for an agent: its new windows go to the agent workspace
  ([displays.md](displays.md)), and the app stays in the background. The CLI sends
  `{"args":["claim","-a","Preview"],"protocol":1}`, or `-b` with the bundle id, or the
  first file, made absolute and a folder's ending with a slash, or URL; `-e` claims
  TextEdit, and `-t` and `-f` claim nothing. Kosmos finds the app as `open` would
  (`AgentOpen`), by any name LaunchServices knows, claims the new windows of its bundle id,
  as the app spells it, for 10 s, and answers with it.
  - Kosmos finds a file's app by the type its name gives, without reading the file: reading
    one in ~/Downloads, ~/Documents or ~/Desktop asks TCC on Kosmos's main thread, which
    once held it 5.3 s, past the CLI's 5 s wait (2026-10-08). A file's own Open With choice
    goes unseen.
  Then the CLI runs `/usr/bin/open -g` with its arguments and exits with its status, so
  `open` runs whatever Kosmos answers. A URL a running browser opens as a tab opens no
  window, so it lands in the user's browser window, in the background.
- `kosmos peek <window id> -- <command> [args...]` runs the command while Kosmos shows a
  window it conceals past its display's edge ([hiding.md](hiding.md)), and exits with the
  command's status: 128 plus the signal's number when a signal ended it, 127 when the
  command is not found and 126 when it could not run. The command runs whatever Kosmos
  answers, so agents wrap every screenshot without checking first.
  - The CLI sends `{"args":["peek","87286"],"protocol":1}`. For a window Kosmos does not
    conceal it answers at once with a plain response and closes, one round trip, and the
    command runs as it is.
  - For a concealed window it answers once the window shows, with `"held":true` in the
    response, and keeps the connection. The CLI runs the command, then sends
    `{"args":["ended","0"],"protocol":1}` with its status, and Kosmos ends the peek,
    answers and closes. A close before that ends the peek too, so a CLI killed during its
    command ends it at once. The socket is close on exec, so the command never holds it
    open.
  - A response's stderr says why a peek did not happen, or ended before the command, and
    the CLI prints it: a lock, a display change not yet applied, or a config reload, for
    example.
  - The CLI waits up to 30 s for the first answer, as a peek waits behind others of up to
    10 s each. Should Kosmos not answer, the command runs without a peek and the CLI says
    so; with Kosmos not running it says nothing, as nothing is concealed.
  - The server's side is `Reply.hold`: a handler that returns one gets the args of the
    client's next request, or nil when the client closes or sends no valid request, and the
    response it returns goes back before the close.
- A bar snapshot is about 870 bytes of JSON and takes 30 µs to encode. It goes to
  ZenithBar's Mach port, `io.github.st-eez.zenithbar`, as the JSON alone, with a zero
  timeout (~/Projects/Personal/zenithbar). Kosmos pushed to SketchyBar's port too until
  SketchyBar retired on October 6, 2026; each push to it then cost two failed bootstrap
  lookups, about 100 µs. A bar asks Kosmos for a snapshot with `kosmos state` only when it
  starts and after a wake ([integrations.md](integrations.md)). A bar reads the snapshot's
  `version` first: a new version may rename or remove fields, and new fields can appear in
  any version.
- A send that fails is tried once more 250 ms later, with the newest snapshot: the zero
  timeout fails while the bar's message queue is full, and a restarting bar has no port
  yet. No failure has been seen, as failures were logged at debug level, which the live log
  of September 24 to 26, 2026 did not keep. The first failure of a streak logs at notice
  level, and so does the send that ends it, with the streak's length and whether a retry
  sent it, so a Mac without ZenithBar logs once for it. The retry goes unless that log shows
  a retry ending a streak.
- A send that times out leaves Kosmos the message back: the kernel maps a new copy of the
  payload into Kosmos and adds a reference to the bar's send right. `send` in
  `CKosmos/KosmosBar.c` destroys it, or each timed out send would leak a page and a port
  reference; a C program with the same message took a send right from 1 reference to 101
  over 100 timed out sends.
- Each message carries its payload in one out of line descriptor. `kosmos-probe displays`
  still queries SketchyBar for its display numbers, in the format its own CLI sends, which
  SketchyBar documents nowhere: the arguments joined by NUL, with one more NUL at the end.
