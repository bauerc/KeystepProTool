## Project Requirements

This is the list of Project Requirements one could expect to implement for the Swift/MacOS desktop application for exporting KeyStepPro project files to MIDI and vice versa.

For exporting KeyStepPro Project to MIDI:
* As a user I should be able to define the following for an output MIDI file:
    * The file location
    * The name
    * If certain sequences should be combined together
    * If I want a certain sequence to repeat/loop a certain number of times within reasonable limits (no more than 10)
    * Modify how step-skip masks are respected or expanded
    * To exclude certain MIDI metadata from export such as velocity/time shift/swing/etc and replaced with defaults
    * reasonable defaults for all of the above if I choose not to define them
