# IPC and bar

- The socket lives in a 0700 directory under Application Support. Peers are checked with
  `getpeereid`, and all I/O runs off the main actor.
- Each message on the socket is a frame: a 4 byte length in network byte order, then that
  many bytes of JSON body. A client sends one request,
  `{"args":["workspace","3"],"protocol":1}` or `{"protocol":1,"subscribe":true}`. The
  server answers with one response, `{"exitCode":0,"stderr":"","stdout":"pong"}`, and
  closes, or for a subscription sends the response, then one frame per published snapshot
  until either side closes. A request with another protocol version gets an error
  response.
- The queries `ping`, `version`, `state`, `list-workspaces`, `list-windows` and
  `list-bindings` change nothing (`Query`). `handover [record version]`, which
  `script/install.sh` sends, arms a quit within 5 s to leave the hidden windows to the
  Kosmos that starts next ([hiding.md](hiding.md)). Any other request is a command
  (`Command.parse`).
- A bar snapshot is about 870 bytes of JSON and takes 30 µs to encode. It goes to
  SketchyBar's Mach port as one `--trigger` event with a zero timeout. The bar asks Kosmos
  for a snapshot only when it starts, with `kosmos state` ([integrations.md](integrations.md)).
  A bar reads the snapshot's `version` first: a new version may rename or remove fields,
  and new fields can appear in any version.
- A send that fails is tried once more 250 ms later, with the newest snapshot: the zero
  timeout fails while the bar's message queue is full, and a restarting bar has no port
  yet. No failure has been seen, as failures logged at debug level, which the live log
  of September 24 to 26, 2026 did not keep. Each failure logs at notice level with what
  the retry did, and the retry goes unless that log shows a retry going through.
- The message has the format SketchyBar's own CLI sends, which SketchyBar documents
  nowhere: the arguments joined by NUL, with one more NUL at the end, in one out of line
  descriptor.
