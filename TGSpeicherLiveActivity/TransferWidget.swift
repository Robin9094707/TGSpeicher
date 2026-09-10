import ActivityKit
import WidgetKit
import SwiftUI

@main
struct TGSpeicherActivityBundle: WidgetBundle {
    var body: some Widget { TransferWidget() }
}

struct TransferWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TransferActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: context.state.nightMode ? "moon.stars.fill" : "arrow.up.circle.fill")
                        .font(.title2).foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.nightMode ? "TGSpeicher · Nachtsicherung" : "TGSpeicher · Uploads").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(context.state.fileName).font(.headline).lineLimit(1)
                    }
                    Spacer()
                    Text(context.isStale || context.state.paused ? "Pause" : "\(Int(context.state.fraction * 100))%")
                        .font(.headline.monospacedDigit())
                }
                ProgressView(value: context.state.fraction).tint(.cyan)
                HStack {
                    Text(context.isStale ? "App öffnen, um den Status zu aktualisieren" : context.state.detail).lineLimit(1)
                    Spacer()
                    if !context.isStale { Text(context.state.speed).monospacedDigit() }
                }.font(.caption2).foregroundStyle(.secondary)
                if context.state.backupTotal > 0 {
                    Label("Fotosicherung \(context.state.backupCompleted)/\(context.state.backupTotal) · \(context.state.pending) Uploads warten", systemImage: "photo.stack")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .activityBackgroundTint(Color.black.opacity(0.88))
            .activitySystemActionForegroundColor(.white)
            .widgetURL(URL(string: "tgspeicher://transfers"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.nightMode ? "Nachtsicherung" : "Upload", systemImage: context.state.nightMode ? "moon.stars.fill" : "arrow.up.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.isStale || context.state.paused ? "Pause" : "\(Int(context.state.fraction * 100))%")
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.state.fileName).font(.subheadline.weight(.medium)).lineLimit(1)
                        ProgressView(value: context.state.fraction).tint(.cyan)
                        HStack {
                            Text(context.isStale ? "App öffnen" : context.state.detail).lineLimit(1)
                            Spacer()
                            if context.state.backupTotal > 0 { Text("Fotos \(context.state.backupCompleted)/\(context.state.backupTotal)") }
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.nightMode ? "moon.stars.fill" : "arrow.up.circle.fill").foregroundStyle(.cyan)
            } compactTrailing: {
                Text(context.isStale || context.state.paused ? "Ⅱ" : "\(Int(context.state.fraction * 100))%")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.cyan)
            } minimal: {
                Image(systemName: context.isStale || context.state.paused ? "pause.circle" : "arrow.up.circle.fill").foregroundStyle(.cyan)
            }
            .widgetURL(URL(string: "tgspeicher://transfers"))
            .keylineTint(.cyan)
        }
    }
}
