import ActivityKit
import SwiftUI
import WidgetKit

@main
struct FloatLingoWidgets: WidgetBundle {
    var body: some Widget {
        TranslationLiveActivity()
    }
}

/// Draws the newest translation in the Dynamic Island (long-press it to read the whole line)
/// and on the Lock Screen / as a banner on iPhones without a Dynamic Island.
struct TranslationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TranslationActivityAttributes.self) { context in
            LockScreenTranslationView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.pair, systemImage: "character.bubble.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.teal)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.status)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.translation.isEmpty ? "Waiting for text…" : context.state.translation)
                            .font(.title3.weight(.semibold))
                            .lineLimit(4)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !context.state.original.isEmpty {
                            Text(context.state.original)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "character.bubble.fill")
                    .foregroundStyle(.teal)
            } compactTrailing: {
                Text(context.state.translation.isEmpty ? context.state.status : context.state.translation)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 72)
            } minimal: {
                Image(systemName: "character.bubble.fill")
                    .foregroundStyle(.teal)
            }
        }
    }
}

struct LockScreenTranslationView: View {
    let state: TranslationActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(state.pair, systemImage: "character.bubble.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.teal)
                Spacer()
                Text(state.status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Text(state.translation.isEmpty ? "Waiting for text…" : state.translation)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(4)
                .minimumScaleFactor(0.7)
            if !state.original.isEmpty {
                Text(state.original)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .padding(16)
    }
}
