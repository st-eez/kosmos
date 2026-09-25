# Distribution

- Kosmos ships the way AeroSpace does: a zip on GitHub releases holding `Kosmos.app` and
  `bin/kosmos`, installed with a cask from Kosmos's own Homebrew tap. The cask removes the
  quarantine attribute and links the CLI. There is no App Store build; its sandbox forbids
  controlling other apps' windows.
- Builds are signed with one stable certificate, so the designated requirement and the
  Accessibility grant survive updates. An ad hoc signature changes with every build and
  makes macOS ask for Accessibility again.
- Notarization needs a Developer ID certificate. Adding it would remove the need to strip
  quarantine.
- The app icon is a plain `.icns`, checked in as `Resources/Kosmos.icns` and copied into the
  bundle. `script/icon.swift` draws it from vectors at every size, inside the macOS 27 icon
  mask whose measurements it states, and regenerates the file when the design changes. The
  format was compared in the Dark icon style at 16 to 128 px: macOS 27 showed the `.icns` at
  full size because its artwork fills the mask, where it shrinks an `.icns` that does not
  onto a grey rounded square, and an Icon Composer `.icon` with one flat layer, compiled by
  `actool` into `Assets.car`, rendered the same artwork at the same size. The other icon
  styles were not tested. The `.icon` format can come when Kosmos has more than one
  appearance to show.
