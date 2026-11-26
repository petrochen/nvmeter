# Reading NVMe SMART and enclosure data

What is normal and what deserves attention. Thresholds come from the NVMe base specification and from how drives
behave in practice; drive vendors' own tools may judge slightly differently.

## Health log fields

| Field                               | Normal               | Attention                              | Bad                                                                                             |
| ----------------------------------- | -------------------- | -------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Critical warning                    | 0x00                 | -                                      | any bit set: spare low, temperature, reliability degraded, read-only mode, backup device failed |
| Available spare                     | 100 %                | dropping                               | at or below its threshold (often 10 %): replace the drive                                       |
| Percentage used (wear)              | grows slowly         | > 80 %                                 | >= 100 % (rated endurance used; the drive may keep working, plan a replacement)                 |
| Media and data integrity errors     | 0                    | -                                      | any non-zero value, and any growth: back up, then replace                                       |
| Error information log entries       | any                  | fast growth together with media errors | -                                                                                               |
| Unsafe shutdowns                    | grows over the years | sudden growth with mounted volumes     | -                                                                                               |
| Warning / critical temperature time | 0 or small           | growing                                | minutes above critical                                                                          |

- **Wear** is the drive's own estimate against its rated TBW; 0-10 % after years is typical for home use.
- **Error log entries** often count harmless rejected commands (for example probes from macOS or an enclosure bridge):
  not a fault on their own.
- **Unsafe shutdowns** count power loss without a shutdown command. Many USB4 / Thunderbolt / USB enclosures cut power
  even after a clean eject, so a high count (for example 9 of 13 power cycles) is common and harmless. NVMeter's connect
  check tells the cases apart: ejected first (harmless), pulled while mounted (warn the user), unknown.
- **Data units** are 1000 x 512 bytes; NVMeter already converts to bytes / TB.
- **Temperature** limits come from the drive itself (Identify: WCTEMP warning, CCTEMP critical, typically 70-85 and
  80-90 °C). Judge against those, not a generic number. 30-55 °C under normal use is fine; under sustained writes
  60-70 °C is common; throttling starts near the warning limit.

## Links and enclosures

- PCIe per-lane payload: Gen3 ~0.9 GB/s, Gen4 ~1.8 GB/s, Gen5 ~3.5 GB/s (NVMeter uses 90 % of the raw rate).
- 4-bay USB4 / Thunderbolt enclosures (OWC Express 4M2 and similar) give each slot **x1** behind a PCIe switch:
  "Gen4 x1 of Gen4 x4" is by design, not a fault. A slot below its siblings or below what it showed before is.
- USB4 / Thunderbolt 3 / 4 at 40 Gb/s tunnel about 3.8 GB/s in theory, ~3 GB/s in practice, shared by all slots.
- On a plain USB connection (cable, port, hub, or the enclosure's USB mode) macOS hides SMART and speed drops to
  ~1 GB/s (10 Gb/s) or ~0.45 GB/s (5 Gb/s). NVMeter reports it as a USB disk with a warning.

## Speed tests

- Quick: sequential write and uncached read of a 5 GB file; the write is often inside the SLC cache.
- Sustained: keeps writing until the SLC cache is full; the speed after the "cliff" is what long recordings get.
  QLC drives drop a lot, especially when the drive is more than ~75 % full.
- Live loop: write and read again and again; shows thermal throttling and cycle-to-cycle stability.
- Random 4K QD1 is what small-file work and app launches feel like; QD32 is a best case.
