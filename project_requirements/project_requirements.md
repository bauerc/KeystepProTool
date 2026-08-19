## Project Requirements

This is the list of Project Requirements one could expect to implement for the Swift/MacOS desktop application for exporting KeyStepPro project files to MIDI and vice versa.

For exporting KeyStepPro Project to MIDI:

- As a user when I interact with a UI I should be able to:
  - A "simple mode" which reasonably does a straight dump from one to the other format and handles edge cases gracefully (i.e. two or more KeyStepPro project files if one doesn't fit, fixed defaults)
  - Specify where an output file lands with distinct options for Midi files vs KeyStepPro files
  - For exporting a MIDI file from a KeyStepPro project:
    - A preview UI that will reasonably show me what tracks exist in the current project and how they line up to the project
    - Determine if certain tracks and/or patterns should be included/excluded from the output
    - Determine if I want multiple individual midi files or one midi file that contains them all
    - If certain sequences should be combined together
    - If I want a certain sequence to repeat/loop a certain number of times within reasonable limits (no more than 10) in the output file
    - Modify how step-skip masks are respected or expanded in the output file
    - To exclude certain MIDI metadata from export such as velocity/time shift/swing/etc and replaced with defaults
    - reasonable defaults for all of the above if I choose not to define them
  - For exporting a KeyStepPro project file from MIDI file(s):
    - Determine which parts of a midi track go to which track on the Keystep Pro
    - Determine which parts of a single midi track get split into which pattern numbers for a track, with an effective UI to mark and segment the midi file within the limits of the KeyPad Pros design
    - Load multiple MIDI files at a time to import
    - Determine which source tracks are treated as drums and which are not, since some DAWs such as Logic do not export drum parts on MIDI channel 10
    - Determine which MIDI channel automatic drum labelling listens to, rather than assuming channel 10
    - If a MIDI file contains more than 4 tracks, the ability to select which of the tracks will be exported by easily checking or unchecking a button/selection
    - Only be able to export no more than 192 midi notes per pattern
    - Only be able to export no more than 64 steps per pattern
    - To exclude certain MIDI metadata from export such as velocity/time shift/swing/etc and replaced with defaults

- As a developer I want:
  - An custom parser for KeyStepPro project files that can read them in a timely, byte efficient, and non-duplicative manner
  - A method to pull directly form the device via usb and immediately create both the KeyStepPro file AND the resulting midi file
