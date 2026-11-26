import Foundation

/// `NVMeter --mcp`: a Model Context Protocol server over stdio (JSON-RPC 2.0, one message per line).
/// stdout carries protocol messages only; diagnostics go to stderr.
enum MCPServer {
    static let protocolVersion = "2025-06-18"

    static let instructions = """
        NVMeter: live and historical state of the Mac's NVMe / SATA drives and their external enclosures \
        (SMART health, temperature, wear, PCIe link per enclosure slot, USB4 / Thunderbolt / USB mode, volumes, \
        temperature and throughput history, events, connect checks, SMART snapshots). \
        Start with list_drives; refer to a drive by its volume name, BSD name (disk10) or model. \
        History exists only for the time the NVMeter app was running. \
        speed_test and volume change state: they only describe what they would do until called with confirm: true, \
        which must reflect an explicit yes from the user. Serial numbers are hidden unless include_serials is true.
        """

    @MainActor private static var inFlight = 0
    @MainActor private static var inputClosed = false

    static func run() -> Never {
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                DispatchQueue.main.async {
                    inFlight += 1
                    Task { @MainActor in await handle(line); inFlight -= 1; if inFlight == 0 && inputClosed { exit(0) } }
                }
            }
            DispatchQueue.main.async { inputClosed = true; if inFlight == 0 { exit(0) } }   // finish pending calls first
        }
        dispatchMain()
    }

    @MainActor static func handle(_ line: String) async {
        guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]); return
        }
        if let batch = obj as? [[String: Any]] { for m in batch { await message(m) }; return }
        guard let m = obj as? [String: Any] else { return }
        await message(m)
    }

    @MainActor static func message(_ m: [String: Any]) async {
        let id = m["id"]
        let method = m["method"] as? String ?? ""
        let params = m["params"] as? [String: Any] ?? [:]
        guard let id, !(id is NSNull) else { return }          // notification (initialized, cancelled, ...)
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            reply(id, ["protocolVersion": requested ?? protocolVersion,
                       "capabilities": ["tools": ["listChanged": false]],
                       "serverInfo": ["name": "nvmeter", "title": "NVMeter", "version": appVersion],
                       "instructions": instructions])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": MCPTools.definitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let (text, isError) = await MCPTools.call(name, args)
            reply(id, ["content": [["type": "text", "text": text]], "isError": isError])
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    @MainActor static func reply(_ id: Any, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }

    @MainActor static func send(_ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        d.append(0x0A)
        FileHandle.standardOutput.write(d)
    }
}
