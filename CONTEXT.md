# KeyStep Pro Tool

Converts Standard MIDI files ↔ Arturia KeyStep Pro projects. Its language is the device's: where
the front panel, MIDI Control Center and this codebase disagree on a word, the device wins. See
[ADR 0001](docs/adr/0001-device-vocabulary-is-canonical.md) for the authority order and how far it
binds. Terms under `_Avoid_` are the words other sources use for the same thing — recorded so they
can be found, not so they can be written.

## Structure

**Project**:
A stored KeyStep Pro project — what the device saves and loads, and what a `.KeyStepPro` file
holds.
_Avoid_: slot, project slot

**Track**:
One of the four sequencer tracks in a Project. Never used bare for a drum track.
_Avoid_: sequence track

**Drum track**:
One of the twenty-four drum sounds, each with its own track of triggers. Always written in full —
a bare "track" is a sequencer track.
_Avoid_: lane, drum lane

**Track mode**:
Whether a track runs as a sequencer, an arpeggiator or drums. It belongs to the Project, not to a
Scene.

**Pattern**:
The note information a track plays, laid out across steps.

**Pattern slot**:
A position within a track that holds a Pattern.

**Step**:
A grid position within a Pattern.

**Pool** *(coined here — the device has no word for this)*:
The per-Pattern store its events live in.

## Events

**Note**:
A melodic event. It carries a pitch.

**Trigger**:
A drum event. It names a drum track instead of carrying a pitch.
_Avoid_: hit, drum note

## Arrangement

**Chain**:
A series of Patterns one track plays one after another in a fixed order. A track has a single
Chain at a time, and creating a new one replaces it. A Chain persists when its Project is saved,
but cannot be saved as an object of its own.

**Scene**:
A snapshot of the Patterns and Chains current in all four tracks, together with each track's mute
status and which track is selected — so one Scene carries four independent Chains, one per track.
Scenes are stored in the Project.

**Export repeat**:
How many times a whole export is laid down end to end in the exported file, up to ten. Ours rather
than the device's: no hardware control sets it and no Project stores one, so it exists only in the
`.mid` and only `--repeat` names it. Not Step skip, whose "repeats" are the device's four sequences
*within* one Pattern.
_Avoid_: loop, pass

## Timing and expression

**Beat**:
The musical quarter note, as MIDI means it. Arturia's manual sometimes uses "beat" loosely for a
step; that use is not canonical here.

**Gate**:
How long a Note sounds, measured in steps.

**Swing**:
The delay applied to a Pattern's even steps.

**Time shift**:
A Note's offset from the step it sits on.

**Step skip**:
Which repeats of a Pattern a Note plays on.
