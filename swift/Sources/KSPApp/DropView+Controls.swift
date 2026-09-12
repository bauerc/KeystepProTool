import AppKit
import KSPKit
import SwiftUI

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

struct Playhead<Content: View>: View {
    @ViewBuilder let map: (Int?) -> Content
    @State private var start = Date()

    var body: some View {
        TimelineView(.periodic(from: start, by: Chase.step)) { context in
            map(Chase.column(after: context.date.timeIntervalSince(start)))
        }
    }
}
