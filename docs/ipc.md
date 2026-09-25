# IPC and bar

- The socket lives in a 0700 directory under Application Support. Peers are checked with
  `getpeereid`, and all I/O runs off the main actor.
- A bar snapshot is about 870 bytes of JSON and takes 30 µs to encode. It goes to
  SketchyBar's Mach port as one `--trigger` event with a zero timeout. The bar applies
  snapshots by sequence number and never queries Kosmos.
- The message has the format SketchyBar's own CLI sends, which SketchyBar documents
  nowhere: the arguments joined by NUL, with one more NUL at the end, in one out of line
  descriptor.
- Hooks that launch programs exist only for rare events such as reload and profile change.
