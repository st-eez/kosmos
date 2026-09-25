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
  `list-bindings` change nothing (`Query`). Any other request is a command
  (`Command.parse`).
- A bar snapshot is about 870 bytes of JSON and takes 30 µs to encode. It goes to
  SketchyBar's Mach port as one `--trigger` event with a zero timeout. The bar applies
  snapshots by sequence number and never queries Kosmos. A bar reads the snapshot's
  `version` first: a new version may rename or remove fields, and new fields can appear in
  any version.
- The message has the format SketchyBar's own CLI sends, which SketchyBar documents
  nowhere: the arguments joined by NUL, with one more NUL at the end, in one out of line
  descriptor.
- Hooks that launch programs exist only for rare events such as reload and profile change.
