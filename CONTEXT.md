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

**Percussion**:
Of a source track being imported: it carries MIDI channel 10, where General MIDI puts drums. Says
what the file holds, never what the device will do with it — only one percussion part becomes
drums, so the app badges that one _Drums_ and any other _Percussion_.
_Avoid_: drum track for a source track that is not the one being imported as drums

**Conductor track**:
Of a MIDI file being imported: the track carrying the file's tempo and time signature and no
notes, which is what `midi_export` writes as track 1 of every export. Nothing is imported from it,
so the app badges it _Tempo_ — the word a DAW puts on the same track, where "conductor" is the
word this codebase writes.
_Avoid_: title track, track 0, tempo track for a track that also holds notes

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

## The app's surfaces

What the app draws has no name on the device — the KeyStep Pro has no screen that shows any of it.
These are therefore coined, and coined from the device's nouns rather than from their shape, so a
UI word can never collide with a format word. See
[the visual language](docs/design/visual-language.md) for how each one looks.

**Pattern map**:
The app's view of a Project as four tracks down by sixteen Pattern slots across. It maps Patterns
to Pattern slots, which is why it is not named after its shape.
_Avoid_: grid, pattern grid, matrix, timeline

**Slot cell**:
One Pattern slot within the Pattern map, and whatever Pattern occupies it.
_Avoid_: grid cell, tile, square

**Chain rail**:
The bar drawn beneath a Pattern map row showing the span its Chain covers.
_Avoid_: chain bar, chain line

**Limit meter**:
One gauge of how close a conversion sits to one of the device's hard limits.
_Avoid_: gauge, limit bar

**Control band**:
The dark strip across the top of the app's content area, after the panel's own matte black band —
the one carrying the display, the knobs and the four track displays above the coloured track zones.
_Avoid_: header, toolbar, title bar
