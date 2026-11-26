# Contributing

Bug reports, ideas and pull requests are welcome, and so is code written with an AI assistant. The project ships
[AGENTS.md](AGENTS.md) so that Claude Code, Codex, Cursor and similar tools pick up its rules on their own.

## Good first contributions

- Results from hardware we have not seen yet: SATA drives behind Thunderbolt docks, RAID sets, other USB4 and
  Thunderbolt enclosures, 80 Gb/s links. Open an issue with `NVMeter --dump --hide-serials` attached.
- Vendor detection or logos for drives that show up as a text badge.
- Video data rates for codecs and cameras the speed test does not list yet, with a source.

## Pull requests

1. `make app` and `swift test` pass, with no new warnings.
2. You ran the change on a real Mac with real drives, and the pull request says on which hardware.
3. UI changes come with light and dark screenshots (see AGENTS.md for the masking flags).
4. No serial numbers, volume names or other personal data in code, tests or screenshots.
5. One topic per pull request. Describe what changed and how you checked it; if an AI wrote most of the code, say
   so and say what you reviewed yourself.

Anything that writes to disks, changes volumes or needs elevated rights gets a careful review and may be declined:
read-only by default is the point of the app.

By contributing you agree that your contribution is released under the project's MIT license.
