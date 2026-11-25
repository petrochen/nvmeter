import Foundation

/// Command line modes of the history store (no window):
///
///     NVMeter --dump-db-stats [--hide-serials]     row counts and first / last seen per drive, as JSON
///     NVMeter --set-name <key> <name>              set a custom drive name (key = "id" in --dump)
///     NVMeter --reset-name <key>                   restore the default name
///     NVMeter --record <seconds>                   sample once per second without a window, then flush and exit
///     NVMeter --compact                            run the roll-up / prune pass now
///     NVMeter --db <path>                          use another database file (any mode, also the GUI)
enum StoreCLI {
    /// Returns true when a store mode ran and the process should exit.
    static func runIfRequested() -> Bool {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--db"), i + 1 < a.count { HistoryStore.overridePath = a[i + 1] }
        let store = HistoryStore.shared
        if let e = store.openError { FileHandle.standardError.write(Data("History database error: \(e)\n".utf8)) }

        if a.contains("--dump-db-stats") {
            var st = store.stats()
            if UserDefaults.standard.bool(forKey: "hideSerials") {
                st.path = "(hidden)"
                for i in st.drives.indices { st.drives[i].key = DriveKey.masked(st.drives[i].key) }
            }
            printJSON(st)
            return true
        }
        if let i = a.firstIndex(of: "--set-name") {
            guard i + 2 < a.count else { print("usage: --set-name <key> <name>"); return true }
            store.setName(key: a[i + 1], name: a[i + 2]); store.flush()
            print("Name for \(a[i + 1]) set to \(a[i + 2])")
            return true
        }
        if let i = a.firstIndex(of: "--reset-name") {
            guard i + 1 < a.count else { print("usage: --reset-name <key>"); return true }
            store.setName(key: a[i + 1], name: nil); store.flush()
            print("Name for \(a[i + 1]) reset")
            return true
        }
        if a.contains("--compact") { store.compact(); print("compacted"); return true }
        if let i = a.firstIndex(of: "--record"), i + 1 < a.count, let secs = Double(a[i + 1]) {
            record(seconds: secs, store: store)
            return true
        }
        return false
    }

    private static func record(seconds: Double, store: HistoryStore) {
        let sampler = Sampler()
        let recorder = HistoryRecorder(store: store)
        let end = Date().addingTimeInterval(seconds)
        var n = 0
        while Date() < end {
            let snaps = sampler.tick()
            recorder.ingest(snaps, refreshedSMART: sampler.lastTickRefreshed)
            n += 1
            Thread.sleep(forTimeInterval: 1)
        }
        store.flush()
        print("Recorded \(n) ticks")
    }

    static func printJSON<T: Encodable>(_ v: T) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(v) { FileHandle.standardOutput.write(d); print() }
    }
}
