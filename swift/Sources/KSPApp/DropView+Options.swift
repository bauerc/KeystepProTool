import AppKit
import KSPKit
import KSPMIDI
import KSPRun
import SwiftUI

/// The two option bands, one per direction.
extension DropView {
    /// The controls that reshape the export, in the section that shows what is being exported.
    /// Every one of them changes the .mid about to be written, which is why it sits here and not
    /// in a column of its own: a reader should never have to guess which controls reach the file.
    var exportOptions: some View {
        optionBand {
            Picker("Files", selection: $model.settings.splitPerPattern) {
                Text("One file for everything").tag(false)
                Text("One file per pattern slot").tag(true)
            }
            .labelsHidden()
            .frame(width: AppLayout.splitPickerWidth)
            .onChange(of: model.settings.splitPerPattern) { model.discardPreview() }
            .help("One file per pattern slot holds one slot each and starts at its own bar 1.")

            Picker("Step Skip", selection: $model.settings.stepSkip) {
                ForEach(Settings.StepSkip.allCases) { Text($0.label).tag($0) }
            }
            .frame(width: AppLayout.stepSkipPickerWidth)
            .onChange(of: model.settings.stepSkip) { model.discardPreview() }
            .help(
                "Auto expands the device's 16/32/48/64 cycle to four passes when a note "
                    + "skips part of it; 1 flattens the cycle to a single pass that plays "
                    + "every note whatever its mask. This is the device's own cycle, not "
                    + "copies of the export.")

            Stepper(value: $model.settings.repeatCount, in: Settings.repeatRange) {
                Text("Repeat ×\(model.settings.repeatCount)")
            }
            .frame(width: AppLayout.repeatStepperWidth)
            .onChange(of: model.settings.repeatCount) { model.discardPreview() }
            .help(
                "Lay the whole export down this many times end to end. This one is not the "
                    + "cycle beside it: it exists only in the .mid, and the device stores no "
                    + "such count, so no repeat of it can be written back to a project.")

            bandDivider

            keeps(
                velocity: \.replaceVelocity,
                velocityNote: "Untick to write every note and trigger at the fresh-note velocity, "
                    + "\(MIDIExport.defaultFlatVelocity), instead of the one it stores.",
                swing: \.replaceSwing,
                swingNote: "Untick to put every step on a flat grid instead of applying the "
                    + "delay the pattern's swing asks for.",
                timeShift: \.replaceTimeShift,
                timeShiftNote: "Untick to put every step on the grid instead of applying the "
                    + "offset the note stores.")
        }
    }

    /// The same band on the way in, and the reason the two are written apart: swing here means
    /// fitting the source's groove, not applying a delay the project already stores.
    var importOptions: some View {
        optionBand {
            Picker("Drums", selection: $model.drumChoice) {
                ForEach(model.drumChoices) { Text($0.label).tag($0) }
            }
            .frame(width: AppLayout.drumsPickerWidth)
            .onChange(of: model.drumChoice) { model.discardPreview() }
            .help(
                "Automatic searches one channel for a kit; None imports every track melodically. "
                    + "Sending a source track to Drums in the list above names one outright.")

            // Offered only while a channel is what the import searches: under None nothing is
            // searched, and a named source track is found without one.
            if model.drumSense.designation == .auto {
                Stepper(value: $model.settings.drumChannel, in: Settings.drumChannelRange) {
                    Text("Channel \(model.settings.drumChannel)")
                }
                .frame(width: AppLayout.drumChannelStepperWidth)
                .onChange(of: model.settings.drumChannel) { model.discardPreview() }
                .help(
                    "The source track sitting wholly on this channel becomes the drum track. "
                        + "General MIDI puts a kit on 10, but a DAW can export one anywhere.")
            }

            bandDivider

            keeps(
                velocity: \.ignoreVelocity,
                velocityNote: "Untick to write every note and trigger at the fresh-note velocity, "
                    + "\(MIDIExport.defaultFlatVelocity), instead of the source's own.",
                swing: \.ignoreSwing,
                swingNote: "Untick to leave every pattern straight at "
                    + "\(Constants.swingRangePercent.min)% instead of fitting it to the "
                    + "source's groove.",
                timeShift: \.ignoreTimeShift,
                timeShiftNote: "Untick to quantise every note hard to its step at a time shift "
                    + "of 0 instead of giving it the leftover it would otherwise keep.")
        }
    }

    /// The three substitutions, put the way the reader thinks about them rather than the way the
    /// runner takes them: a ticked box keeps what the file holds, and unticking one writes the
    /// device's own default over it.
    @ViewBuilder
    func keeps(
        velocity: WritableKeyPath<Settings, Bool>, velocityNote: String,
        swing: WritableKeyPath<Settings, Bool>, swingNote: String,
        timeShift: WritableKeyPath<Settings, Bool>, timeShiftNote: String
    ) -> some View {
        Text("Keep")
            .foregroundStyle(palette.mutedInk)
            .frame(width: AppLayout.keepLabelWidth, alignment: .leading)
        keep("Velocity", velocity, help: velocityNote, width: AppLayout.keepWidths[0])
        keep("Swing", swing, help: swingNote, width: AppLayout.keepWidths[1])
        keep("Time Shift", timeShift, help: timeShiftNote, width: AppLayout.keepWidths[2])
    }

    private func keep(
        _ title: String, _ substituted: WritableKeyPath<Settings, Bool>, help: String,
        width: CGFloat
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { !model.settings[keyPath: substituted] },
                set: {
                    model.settings[keyPath: substituted] = !$0
                    model.discardPreview()
                })
        )
        .frame(width: width, alignment: .leading)
        .help(help)
    }
}
