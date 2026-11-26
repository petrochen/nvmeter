# Changelog

All notable changes, newest first. Versions follow [semantic versioning](https://semver.org); until 1.0 a minor
version can change behaviour. Each release section below is used as the GitHub release notes.

## 0.10.0 (2026-11-26)

First release published as a signed and notarized app (Developer ID: ESCUDIX LTD), universal (Apple silicon and
Intel).

- README for people who work with external drives, with screenshots, and a comparison with the apps NVMeter
  replaces.
- Contributor guides: `AGENTS.md` for AI coding agents, `CONTRIBUTING.md`, issue and pull request templates, CI.

## 0.9.1 (2026-11-26)

- Drives menu with ⌘0 (startup drive) to ⌘9; holding ⌘ shows the numbers in the sidebar.

## 0.9.0 (2026-11-26)

- Fixed: drives could not be selected with the mouse in the sidebar. Rename moved to the context menu and
  double-click.
- `--demo-names` for screenshots; screenshot mode no longer touches the app's state.

## 0.8.0 (2026-11-26)

- Agent skill for Claude Code and Codex (`make install-skill`).
- Only one app instance; SMART reads of all NVMeter processes take turns.
- Lower footprint: about 1 % CPU with the window closed (was about 6 %). Volumes re-read on DiskArbitration
  events, no redraws of a hidden window, menu bar item redrawn only when its text changes.

## 0.7.0 (2026-11-26)

- MCP server (`NVMeter --mcp`): drives, details, history, events, enclosures, snapshot compare, reports; speed test
  and volume actions only with `confirm: true`.

## 0.6.0 (2026-11-26)

- Volumes: unmount without ejecting, mount, mount read-only, remount read-only or read-write, and "Always mount
  read-only" per drive.
- Fixed: a busy volume (EBUSY) was reported as a raw error instead of listing the apps that hold it.

## 0.5.0 (2026-11-26)

- Connect check: when a drive connects, NVMeter compares it with its previous visit (use on other machines, unsafe
  shutdowns with eject awareness, new errors, wear, connection) and saves a SMART snapshot.
- Offers to start at login on first launch.

## 0.4.0 (2026-11-26)

- Speed Test live loop with write and read dials, time, write and temperature limits, and a resolution by frame rate
  grid per codec.
- Drive detail split into Overview, History and Speed Test.

## 0.3.0 (2026-11-25)

- History database, menu bar item and alerts, enclosure view with per-slot PCIe links and shared bandwidth, drive
  reports (PDF, JSON, Markdown), SMART snapshots, speed test with SLC cache cliff detection, SATA SMART, RAID status.
- SMART is opened per read so smartctl, DriveDx and other apps keep working alongside NVMeter.
