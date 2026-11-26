# Instructions for AI coding agents

NVMeter is a native macOS app (Swift 6, SwiftUI, Swift Charts, Swift Package Manager, no Xcode project) that
monitors NVMe / SATA drives and their enclosures. README.md explains the features and the data sources; its
"Layout" section maps the source folders.

## Build and check

```sh
make app          # builds build/NVMeter.app (ad-hoc signed)
swift test        # unit tests, must pass
build/NVMeter.app/Contents/MacOS/NVMeter --dump --hide-serials   # JSON of every drive: quick end-to-end check
```

Fix every compiler warning you introduce. Add a unit test for any parser, calculation or rule you add
(`Tests/NVMeterTests`). UI changes: attach light and dark screenshots to the pull request, made with
`--screenshot <dir> --hide-serials --demo-names --db <scratch.sqlite> --seed-demo`.

## Rules that protect users' drives and data

- NVMeter is read-only. Nothing may write to a disk, change a volume or run a privileged tool, except the Speed
  Test (temporary files in `.nvmeter-speedtest/`, always removed) and the Volumes controls, both started by the user.
  No `sudo`, no kernel extension, no helper tool, no new shell-outs (the only one is `lsof`).
- Open the NVMe SMART user client for one read and close it right away (`SMARTReader.withHandle`). macOS allows one
  open client per device; holding it locks out smartctl, DriveDx and other NVMeter processes. Reads from all NVMeter
  processes take turns through `smart.lock`.
- `Sampler` and `DriveScanner` are not safe to run concurrently inside one process: the app runs one, the MCP server
  serializes sampling through a queue. Keep it that way.
- Never wake sleeping hard drives (see `ATA.swift`). Do not add polling that touches the disks themselves more often
  than SMART already does.
- No personal data in the repository: no drive serial numbers, volume names, user paths or hostnames in code,
  tests, fixtures or screenshots. Masks: `--hide-serials`, `--demo-names`.
- MCP tools that change state (`speed_test`, `volume`) must keep requiring `confirm: true`.

## Performance

The app lives in the menu bar all day: about 1 % CPU with the window closed (README, "Footprint"). Do not build or
update views while the main window is hidden (`WindowState`), only redraw the menu bar item when its text changes,
and re-read volume lists on DiskArbitration events, not on a timer. Measure CPU before and after a change that runs
every tick (`ps -o cputime`, `top -stats cpu,idlew`).

## Style

Match the surrounding code: small files per feature folder, plain Swift, comments that explain why. User-facing
text in English, short and concrete. Brand names and logos only to identify hardware (README, "Vendor logos").
