# IPC and bar

- The socket lives in a 0700 directory under Application Support. Peers are checked with
  `getpeereid`, and all I/O runs off the main actor.
- A bar snapshot is about 870 bytes of JSON and takes 30 µs to encode. It goes to
  SketchyBar's Mach port as one `--trigger` event with a zero timeout. The bar applies
  snapshots by sequence number and never queries Kosmos. A bar reads the snapshot's
  `version` first: a new version may rename or remove fields, and new fields can appear in
  any version.
- Hooks that launch programs exist only for rare events such as reload and profile change.
