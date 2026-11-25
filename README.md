# NVMeter

A native macOS app that is "CPU-Z / CrystalDiskInfo for SSDs on Mac, with iStat-style graphs".
Swift + SwiftUI + Swift Charts, one self-contained `.app`, no runtime dependencies.
Working name; v0.1.

- **Drives tab**: every physical disk with health badge, temperature, model / serial / firmware / capacity,
  interface (for example `PCIe 4.0 x1 via USB4 40 Gb/s, OWC Express 4M2`), all NVMe SMART attributes with a
  coloured status dot, total TB written / read, power-on hours and the volumes on the disk (APFS aware).
- **Graphs tab**: live temperature (with the drive's warning / critical thresholds) and read / write MB/s per
  drive plus a total row. Windows: 5 min, 30 min, 2 h. History is in memory only (v0.1).
- SMART is polled every 5 s (Settings, Cmd+,), throughput every 1 s. Disks that appear or disappear are picked
  up live.

## Strictly read-only, no privileges

NVMeter never writes to a disk, needs no sudo, no kernel extension and no helper. It never runs `smartctl`,
`iostat`, `diskutil` or Python. Everything comes from public macOS APIs:

| What                                                          | Source                                                                                                              |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| SMART / health log, Identify (warning / critical temperature) | `IONVMeSMARTInterface` (IOCFPlugIn, `kIONVMeSMARTUserClientTypeID`), the same interface smartmontools uses on macOS |
| Throughput                                                    | IORegistry `IOBlockStorageDriver` -> `Statistics`, differenced every second (decimal MB/s)                          |
| PCIe link                                                     | `IOPCIExpressLinkStatus` / `IOPCIExpressLinkCapabilities` on the NVMe PCI function                                  |
| Enclosure / USB4 / USB                                        | IORegistry Thunderbolt switch (`Thunderbolt Entry ID` on the bridge above the drive) and `IOUSBHostDevice`          |
| Volumes                                                       | IORegistry descendants of the whole-disk `IOMedia` + DiskArbitration (APFS physical store -> container -> volumes)  |

If an enclosure falls back to USB, macOS exposes no SMART for the drive. NVMeter still lists the disk with
throughput and shows a warning such as `Connected at USB 10 Gb/s: SMART unavailable, expect ~1 GB/s`.

### Not pure Swift: one tiny C shim

`Sources/CNVMe` (about 60 lines of C) wraps Apple's COM-style `IONVMeSMARTInterface` vtable from
`NVMeSMARTLibExternal.h`. Swift cannot import the `CFUUIDGetConstantUUIDWithBytes` macros or call the
CFPlugIn COM interface cleanly. The shim only opens the plug-in and issues two read-only calls
(`SMARTReadData`, `GetIdentifyData`); all parsing and all logic is Swift.

## Build and run

Requires Xcode 26+ command line tools (Swift 6 toolchain), macOS 14+.

```sh
make build      # swift build -c release
make app        # assembles build/NVMeter.app, strips xattrs, ad-hoc codesigns
make run        # make app + open it
make dump       # make app + print the JSON dump
```

### CLI mode

```sh
build/NVMeter.app/Contents/MacOS/NVMeter --dump
```

prints one JSON document with everything the app knows about every disk (SMART fields, link, connection,
volumes, a 2 second throughput sample, health rows) and exits. Useful for verification and scripting.

`NVMeter --screenshot <dir>` renders both tabs of the app window into PNG files and quits (used for
testing; needs no Screen Recording permission).

## Layout

```
Sources/CNVMe      C shim around IONVMeSMARTInterface
Sources/NVMeter    Swift app: Registry, SMARTReader, DriveScanner, Sampler, Health, Monitor, SwiftUI views
Resources          Info.plist
```

## Known limitations (v0.1)

- History is not persisted; it restarts with the app.
- SMART needs a transparent NVMe path. USB bridges (and some TB/USB4 enclosures in USB mode) hide it.
- Counters above 64 bit saturate (never happens in practice).
- Thunderbolt link speed is derived from the lane adapter's current speed / width; asymmetric 120 Gb/s links
  are shown as 80 Gb/s at most.

## License

MIT
