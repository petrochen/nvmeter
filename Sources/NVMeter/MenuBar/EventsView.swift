import SwiftUI

struct EventsView: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let events = monitor.alerts.events
        VStack(spacing: 0) {
            HStack {
                Text("Events").font(.title3.weight(.semibold))
                Text("last \(AlertCenter.maxEvents)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { monitor.alerts.clearEvents() }.disabled(events.isEmpty)
            }.padding(14)
            Divider()
            if events.isEmpty {
                ContentUnavailableView("No events yet", systemImage: "bell",
                                       description: Text("Temperature, SMART and connection alerts show up here. Rules are in Settings."))
            } else {
                List(events) { e in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(e.severity.color).frame(width: 9, height: 9).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(.callout.weight(.semibold))
                            Text(e.body).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(e.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { if let id = e.driveID, monitor.drives.contains(where: { $0.id == id }) { monitor.selection = id; monitor.tab = .drives } }
                }
            }
        }
    }
}
