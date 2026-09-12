import AppKit
import KSPKit
import SwiftUI

/// The small controls the panes are built from, each with state of its own.
struct NameField: View {
    let prompt: String
    @Binding var text: String
    let palette: Palette
    @FocusState private var focused: Bool
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(palette.mutedInk))
            .textFieldStyle(.plain)
            .labelsHidden()
            .font(TypeScale.label)
            .foregroundStyle(palette.ink)
            .focused($focused)
            .padding(AppLayout.fieldPadding)
            .background(
                RoundedRectangle(cornerRadius: AppLayout.fieldRadius).fill(palette.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppLayout.fieldRadius)
                    .strokeBorder(palette.rule, lineWidth: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppLayout.fieldRadius)
                    .strokeBorder(Color.accentColor, lineWidth: AppLayout.fieldRingWidth)
                    .opacity(focused && activeState == .key ? 1 : 0)
            }
    }
}

/// What says a slot, a track name or a slot number is clickable, now that no sentence under the
/// grid does: the system accent rings it under the pointer, which is what the accent is for.
struct TickStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TickFace(configuration: configuration)
    }
}

struct TickFace: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .opacity(configuration.isPressed ? AppLayout.pressedOpacity : 1)
            .overlay {
                RoundedRectangle(cornerRadius: AppLayout.cellRadius)
                    .strokeBorder(Color.accentColor, lineWidth: AppLayout.hoverRingWidth)
                    .opacity(hovering ? 1 : 0)
            }
            .onHover { hovering = $0 }
    }
}

/// What runs the chase. The start is this view's own state, created when the working pane appears
/// and gone when it leaves, so no clock outlives the conversion it belongs to.
struct Playhead<Content: View>: View {
    @ViewBuilder let map: (Int?) -> Content
    @State private var start = Date()

    var body: some View {
        TimelineView(.periodic(from: start, by: Chase.step)) { context in
            map(Chase.column(after: context.date.timeIntervalSince(start)))
        }
    }
}
