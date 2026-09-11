# The app's visual language

How *Key Step Pro Plus* looks, and why. The decisions and their alternatives are in
[ADR 0002](../adr/0002-the-app-wears-the-devices-visual-language.md); this is the working
reference. The values live in `swift/Sources/KSPApp/DesignTokens.swift`, which is the only place
in `KSPApp` a colour or a dimension is written.

Sources are Arturia's KeyStep Pro manual v2.5.2 and their own product imagery. A section number
below is a section of that manual.

## The stance

**Native chassis, instrument core.** The window, the toolbar, the buttons, the pickers and the
focus rings are ordinary macOS. The *domain* surfaces — the pattern map, the limit meters, the
source routing — render the way the hardware renders them. Identity lives in the data, not in the
chrome.

Controls keep the **system accent**. The device palette owns data surfaces only. Never override the
accent colour on a focus ring or a selection: it is a user setting with accessibility weight.

## The four hard rules

These are the rules a later change is most likely to break by accident.

### 1. Hue never carries text contrast

Track 3 is `#FACC00`. On the standard unit's `#E8E9ED` ground it is unreadable as text. So a track
hue is always a **fill** that black or white ink sits on — the way the painted panel zones carry
black legends — and never the colour of the lettering itself.

`DeviceColor.ink(on:)` picks the ink by relative luminance. Use it; do not hard-code black or white
against a track colour.

This is also what lets **one** set of track values serve both faces, rather than two tuned sets.

### 2. Status never relies on hue

Track 2 is orange and Track 4 is red — exactly the hues a warning and an error want. A finding row
can sit directly beside either.

So **the glyph and the sort order carry severity**, and colour only agrees with them. Errors sort
above warnings. `Palette.warning` and `Palette.error` are deliberately duller and darker than the
track hues they may neighbour.

A reader must be able to tell a warning from an error with the colour removed.

### 3. The numerals are the device's

Every figure reads as the device's screen shows it, in SF Mono:

| | |
|---|---|
| Gate | `0.5` `2` `3.5` `64` — steps, not milliseconds |
| Time shift | `−4` … `+50` — signed, centred on 0 |
| Note | **`C3` is MIDI 60.** Not C4 |
| Velocity | `100` — bare, 0–127 |
| Randomness | `80` — bare percentage |
| Swing | `50`–`75` — absolute percentage |

This follows [ADR 0001](../adr/0001-device-vocabulary-is-canonical.md): if the device's words are
canonical, so are its numbers. **`C3` is not a bug.** Do not "fix" it to the general-MIDI
convention.

### 4. Only colours with a referent

The device's grammar is: **track colour = identity · white = now · blue = secondary function ·
red = unsaved edits**.

Adopted: track colours (a row's track) and white (the conversion playhead, §4.2.9 — *"the
currently playing step, which is lit up in white"*).

Not adopted: **red** and **blue**. Nothing in this app is ever in an unsaved state; do not invent
one to justify red. Blue marked the Advanced options while there was a mode to mark. Once every
option was drawn beside what it changes (#287), blue had nothing left to say, and a blue rail
beside a heading only competed with the system accent, which is what the reader acts on. A heading
holds its rank by size and the space above it. Do not bring either colour back as decoration.

## The palette

### Track colours — both faces, unchanged

Manual §1.4: *"Green for Track 1, Orange for Track 2, Yellow for Track 3 and Red for Track 4."*
Painted on the panel and lit on the step buttons.

| | Hex | |
|---|---|---|
| Track 1 | `#01A986` | a teal-leaning green, not a pure one |
| Track 2 | `#FB5C26` | |
| Track 3 | `#FACC00` | the hard one on the light ground — see rule 1 |
| Track 4 | `#E0002E` | |

Fixed. Chroma firmware allows reassignment; the app does not (ADR 0002).

### The two faces

Light is the **standard unit** — an off-white metal wedge with a matte black control band. Dark is
the **Chroma** — a dark grey shell with icy blue indicators. Both authored; neither derived.

| Role | Standard | Chroma |
|---|---|---|
| `ground` | `#E8E9ED` | `#1C1D20` |
| `surface` | `#DADDE0` | `#242629` |
| `well` | `#0D0D0D` | `#0C0A0B` |
| `wellInk` | `#E9F0FF` | `#E9F0FF` |
| `ink` | `#14161A` | `#E7E9EC` |
| `mutedInk` | `#5A6068` | `#9199A1` |
| `rule` | `#C4C8CE` | `#34373C` |
| `laneWash` | `0.7` | `0.18` |

The appearance control offers **Standard / Chroma / System**, not light / dark: both are real
products, and the question is which unit is on the user's desk. It follows the system by default.

## The objects

Named from device vocabulary, never from shape — see `CONTEXT.md`.

### The title bar

The file name and the direction are the window's own title and subtitle, which is where macOS
names a document. **No strip crosses the top of the content.** A band skinned as the panel's matte
black, under a native toolbar, is chrome dressed as the device — the one thing the stance rules out
— and on the standard face it read as white, then black, then white.

The panel's black survives where the device earns it: a lit readout well.

It names the **document** in every phase, the finished one included. What the run made is the
pane's to announce; the band saying it as well would say it twice.

### The action bar

A bar across the foot of the content area, carrying where the result lands on the left and the dry
run beside the phase's action on the right. It is ordinary macOS: the surface ground, a rule above
it, and a commit action at the trailing end, which is where the platform puts one.

**The dry run sits beside the button that obeys it.** Whether a run writes anything is one
decision with Convert, which reads *Dry run* while it is on, so the switch and the button are one
group rather than a switch in one column and its consequence in another.

**Where it lands sits beside the button that writes it.** The folder is quiet and gives way first
— the head of a path is what a reader can spare, and the name is what they just typed. Choose…
edits the destination the staged direction writes into, and a refused file says it has none rather
than naming a path the app has already declined to write.

**Once it is written, it says where the file is.** The folder the run's files sit in takes the
landing's place, beside **Reveal in Finder**, which shows them there. The Finder comes up only when
asked: a window raised over the result on every run would hide the one thing the run was for.

**The action slot is never empty.** It carries whatever the phase's action is — Cancel and Convert
while a file is staged, Reveal in Finder and Convert another when one is written, and **Open…**
while nothing is. An
empty window that offers no way to fill it puts the only entrance in the menu bar, where a user
looking at the window will not find it; the keyboard has ⌘O and the mouse has this. Wherever the
action bar moves, the idle entrance moves with it.

The bar's height is fixed. A run in flight has no action to offer and no landing to promise, and a
chassis that drops out from under the window for the seconds a conversion takes is worse than an
empty one.

### The result

A finished run leads its pane: a status glyph a size above anything else in the window, what it
wrote beside it in the band title's size — the file's name, or how many files — and the runner's
own account of the run underneath in `mutedInk`.

**Success is marked**, with `success` and `checkmark.circle` together. A run that wrote a file is a
status, and the one the app exists for, so rule 2 holds as it does for a refusal: the glyph says
it and the colour agrees. A failure takes `error` and the triangle, and its account stays in
`ink` — nobody should have to squint at what went wrong.

### Cards

**One container, worn everywhere.** The device-read panel and each phase of a conversion sit on one
card: the `surface` fill at `cardRadius`. The phases are the **Source** the app reads, the
**Result** it would write, and, on the way in, the **Device limits** it would cost. The review
found the panel wearing a card and the main screen wearing nothing, so a reader met two structural
languages in one app. Now the shape of the task shows before a word of it is read.

A heading stands **above** its card, in `TypeScale.header`, and holds its rank by size and the
space above it — never by a coloured rail. Inside a card, the arrange lanes and the note shapes
recess their axis to `ground`, so the span a track leaves unplayed still reads against the card.

The card's padding comes out of every row inside it, which is why those rows are held to
`minimumCardContentWidth` rather than to the pane.

### The option band

One row under a rule inside the Source card, directly under the source it acts on: the drum
designation and channel under a source track list, the split, Step Skip and Repeat under a pattern
grid, and in both cases **Keep — Velocity, Swing, Time Shift** after a rule.

**A control sits inside what it changes.** A column of options beside the window says nothing about
which of them reach the file; a control under the thing it reshapes says it by structure, and needs
no styling to carry the distinction. What no conversion decides — the appearance, the default
destinations, how long a finding list runs — is not in the window at all, but in Settings (⌘,).

**The ticks say keep, not ignore.** The runner takes these as substitutions — replace the velocity,
ignore the swing — but a reader is deciding what survives the trip. A ticked box keeps what the
file holds; unticking one writes the device's own default over it. The sentence each control used
to carry underneath is its hover text, because a row cannot hold a paragraph per control.

**Every control in the band is held to a fixed width**, summed in `AppLayout` and asserted against
`minimumContentWidth`, for the reason `trackColumnWidths` is: the band is one row inside a pane
that scrolls vertically only, so a control added to it and left out of the sum is clipped in
silence.

### The pattern map

Four tracks down, sixteen pattern slots across. Each row wears its track's colour.

The idle window draws it **empty but present** — the same four rows and sixteen slots, in the track
colours under the density floor, with the drop prompt on a plate over them. The app's first
impression is then its own object rather than a system dialog's file glyph, the window explains
itself at a glance, and there is something for the conversion playhead to cross. A file dragged
over the window lights the map rather than washing the pane: the drop target is the instrument
coming up.

### Slot cells

Three orthogonal channels, so no combination of states turns to mud:

| Channel | Means | Never means |
|---|---|---|
| **Fill** | content — the track hue at an intensity ramping with notes per step | anything about export |
| **Stroke** | intent — solid exports, dashed does not | anything about content |
| **Bottom rule** | length — a fraction of the cell width for 16 / 32 / 48 / 64 steps | |
| **The figure** | events switched on, SF Mono | |
| **Ring** | clickable — the system accent, under the pointer only | anything about content or export |

Chain membership lives on the **chain rail** beneath the row, never inside a cell.

On the export map a slot cell **cannot show rhythm**. The project summary carries density, length
and kind and nothing finer. Do not add per-step plumbing to make a cell prettier — where rhythm
belongs is the arrange lanes below.

The import side is the exception, because the plan it is read off holds every note it places. A
held cell there **draws its own Pattern** in place of a figure: a thumbnail in the cell's ink,
across the Pattern's own steps, on one pitch window for the whole run so the halves of a split
meet at the same height. The length rule still says how long it runs. An empty cell keeps its em
dash.

### The arrange lanes

Four lanes under the map, one per device track, on **one shared time axis** — the map's own origin
and width, so a lane sits under the row it belongs to. It answers what a grid of equal columns
cannot: how the four tracks sit against each other in real time.

Everything positional comes from the export's own `Arrangement`; the view scales ticks into the
axis and decides nothing about where a Pattern falls.

| Channel | Means | Never means |
|---|---|---|
| **Position and width** | the geometry — a region starts at its slot's boundary and runs the length **its own track** plays | anything about export |
| **Fill** | identity, and held versus empty — the track hue washed over the ground at the face's `laneWash`, `inert` where the Pattern renders no event | density |
| **Marks** | the notes — one bar per event, placed by the tick it is written at and by pitch | velocity |
| **Grid lines** | the run's own clock: a faint line every beat, an accented one every bar | a step of any one Pattern |
| **C3 line** | MIDI 60, where the lane's window reaches it | |
| **The figure** | which Pattern the region is, SF Mono | |
| **Boundary rules** | where one Pattern gives way to the next, drawn over the regions | |

**A region is drawn at its own length inside the shared span, never stretched to fill it.** A track
looping shorter than its neighbours is the instrument working, and the gap it leaves is the whole
reason these lanes exist — the same thing the `track-lengths-differ` finding says in prose.

**The marks are where the file puts the notes, not where the grid does.** Swing and time shift are
baked into the written ticks, so a Pattern stored as a clean sixteen steps can land a note a whole
beat late — `project_5.KeyStepPro`'s third kick is written at tick 4321, not 3840. The grid is
what makes that visible, and it has **two weights**: a faint line every beat and an accented one
every bar — four beats, the 4/4 the export writes — so sixteen beats read as four groups at a
glance and a kick a beat late sits plainly past the bar line it belongs on. It runs on the run's
clock, not restarted per Pattern, and where lines would crowd closer than 8 points both weights
step out by fours.

Pitch is **fitted to each lane**, never narrower than an octave, and the range is named under the
track in the device's numerals — `C2–D2` — so a mark's height means what the words beside it say.
A fixed window drew a track of three neighbouring pitches as one flat line. Marks are drawn in the
block's own ink, not the track hue, so they stay legible on either face, and they are **dropped
entirely** below a width where they would outnumber the points available. Nothing here is
editable, and no mark is ever labelled with a note name.

### The note shape

What the import would lay down, drawn under the grid that counts it: one per device track the plan
fills, **pitch up, steps across**, a region per Pattern and a bracket under each —
`pattern 1 · 16 steps` — so a run needing three Patterns reads as three.

It is the arrange lane's object seen from the other side, and draws the same way: the track's wash,
ink marks, the two-weight grid under them and the C3 line through them. Three things differ, each because
the import has something the export does not.

- **Steps, not ticks.** A note sits on the step the planner put it on, held for its gate. The
  grid rules every step and accents every beat, so a sixteen-step Pattern reads as four groups of
  four — steps 5, 9 and 13 open them — counted from each Pattern's own first step, as the device
  counts them.
- **The pitch labels stand beside it** where the map's drum badge would, naming the lowest pitch,
  the highest and `C3`. `C3` is placed first, since it names the one line across the shape; a
  label that would overprint one already placed is dropped and left to the range under the name.
- **Every shape of a plan shares one step axis.** The longest run fills the map's width and a
  shorter one is drawn shorter, for the reason a lane region is never stretched.

A note is held inside its own Pattern: the device loops at the last step rather than sustaining
into the next.

**The wash is authored per face, not shared.** A hue washed at `0.18` over the Chroma's dark grey
keeps nearly all its saturation — dark teal, olive — and over the standard unit's off-white the
same wash is a pastel that reads as no track at all. The standard face's `0.7` is the least at
which every track wears its hue at least as strongly as it does on the Chroma, while all four still
take dark ink. `DesignTokensTests` holds both halves of that.

### Row heads

A two-digit **pattern-number readout** in a dark well, after the hardware's four 7-segment displays
sitting above each coloured track zone.

**SF Mono, not a seven-segment face.** The placement and the role are the fidelity; imitating LCD
glyphs with dead segments is where this becomes costume.

**A well is lit only while it has something to read out.** A track playing no Pattern shows `--` in
an unlit well — `surface`, a `rule` round it, `mutedInk` — so an idle map, or a project that uses
two tracks, does not hang four black pills down the edge of the standard face.

Track 1 in drum mode is **badged on the row**; its cells are not restyled. Row 1 stays green
whether it is sequencing or drumming — that is what the device does.

### Limit meters

Segmented, filling toward a marked ceiling, figure in SF Mono. The one place a literal hardware
idiom is earned: the device's limits are genuinely hard ceilings, and metering against a ceiling is
what segmented LED metering is for.

The meter itself is pure quantity: lit segments, unlit segments, and a static cap at the ceiling.

**Only a refusal is marked — on a meter.** Near (≥75%) takes `warning` and no glyph, because the
meter already says how close the figure sits: approaching a wall is emphasis on a quantity, not a
status. Over means the planner refused something, which *is* a status, and it takes `error` and
`exclamationmark.triangle` together — rule 2.

### The verdict line

The block leads with one line above the five meters — `Fits`, `Fits, 2 limits close`,
`3 patterns over` — so the answer arrives before the detail, and what went is counted in the unit
its own wall is measured in. Only the three walls the planner can refuse at carry a figure here;
the two it can merely truncate to never do.

It is marked in **all three** states, unlike a meter, and this is not a slip: the line carries no
quantity of its own, so with the colour removed the glyph is the only thing left to read the
status off — rule 2 again.

**The limits are feedback, never an option.** Whether a loop fits a 64-step pattern is what a
reader who does not know the hardware most needs, so the block is always whole.

### Finding rows

What the conversion found, one row each, under a disclosure that says how many there are.

A leading severity glyph in a fixed-width column — `exclamationmark.circle` for a warning,
`exclamationmark.triangle` for an error — so the text blocks align and severity survives the
colour being removed. **Errors sort above warnings**, and inside one severity the report's own
order holds: the planner walked the sites in it.

Figures inside the prose are lifted into SF Mono (rule 3). A line that names a file is left
alone — `M6-song.mid` has a digit in it that is not a figure — which is why the failure headline
is the one headline set plainly.

The order is the window's alone. `Report.render()` prints in the report's own order on both CLIs,
which is the contract the section below closes on.

### The import side

Colour follows the destination. A source track is `inert` until routed, then takes its device
track's colour. The segmentation row it feeds already wears that colour, so routing is visible as
the source row acquiring the colour of the row it lands in.

## Copy

**A label is the documentation.** A control, a grid or a meter carries its name and nothing
underneath it — no legend, no caption, no sentence saying what a click does. A cell that can be
clicked says so with its ring, not with a line under the map.

**Say a number once.** The Result's header gives the length, so no line under the grid restates
it; a limit's site is named on the first meter found there and left off the ones below it; the Read
button names the slot, so no line under the slots does.

**Do not caption what the picture already says.** A struck, dashed cell is left out, an unticked
Keep writes the default, and a routed source track wears its device track's colour. None of them
gets a line saying so.

**Explanation lives in help.** What a control does beyond its label is its hover text, where it is
there when wanted. What the app *found* is not explanation, and stays in the window: a finding, a
refusal, a warning that nothing would be written, a folder it fell back to. Nobody hovers to learn
that something went wrong.

## What is spoken

VoiceOver reads the window in the window's own words, with the drawing said aloud.

**A label names; a value says what is drawn.** A slot cell is labelled `Pattern 3`, and its value is
what its fill, figure and length rule show: `76 notes held, 8 switched on, 16 steps`. A limit meter
is its name and `48 of 64, close to the limit` — the status its colour and glyph carry, in words,
because rule 2 has to hold for a reader who sees neither. The models write these as `spoken`,
beside the tooltip each is read off, and `aloud` turns a tooltip's `·` and `—` into pauses and
`1-2` into `1 to 2`.

**A track is one group.** A row of the pattern map, a lane, a source track and a row of the
import's grid are each one element, labelled with the track's whole line — `Track 1, drum, on
pattern 1, 2 patterns, 32 triggers switched on` — so a reader moves track by track. Its cells stay
inside it, so whatever can be clicked is still reachable one by one.

**Help is the hint.** `.help` sets the accessibility hint as well as the tooltip, so a control's
hover text is spoken on focus. An element assembled from drawn parts has no control underneath to
lend it one, which is why its value carries the tooltip's facts.

**Decoration is hidden.** Rails, meter segments, grid lines, marks and the figures over a grid that
cannot be clicked are left out of the tree: the row or the value already says what they draw, and a
stop that says nothing new is a stop in the way.

## Motion

**One thing moves: a white playhead across the pattern map while a conversion runs.** White is what
the device lights the currently playing step (§4.2.9). It is the one moment the app has nothing
else to show.

- Honour `reduce-motion`; fall back to the static progress view.
- Give it a floor, or a sub-second conversion flashes once and reads as a glitch. The floor is held
  **before** the first step and never open after the last: a chase held open would gate the result,
  and a failure the user needs to see, on the animation. The conversion finishes when it finishes,
  and the chase is cut short.
- The chase's clock is the view's own. Nothing the conversion does may wait on it.

**Nothing else in the app animates.** Everywhere else, motion is noise.

## The icon

Four rows of steps in the four track colours on the panel's black band — a miniature of the app's own
pattern map and of the panel. Green-orange-yellow-red stays distinctive when the shapes blur at
16pt.

The rows run **four, two, three and two steps** — the device's own 64 / 32 / 48 / 32 pattern
lengths, so the icon carries the same thing the arrange lanes do: four tracks looping at lengths
of their own. No row is ever shorter than two steps, or its hue drops out of the sequence at
16pt, and below 64px a row's steps are drawn merged, where a 4px cell would close its own gaps.

Drawn by `tools/make_app_icon.py` and packed by `iconutil` from `scripts/bundle_app.sh`. The
hues it reads are this document's, and `tests/test_app_icon.py` holds it to them.

Do not depict the instrument itself: an off-white chassis with Arturia's coloured zones is a
picture of someone else's product (ADR 0002).

## Out of scope

**The CLI.** Its output is a byte-for-byte contract across two implementations held by four parity
scripts. The visual language stops at the window and the bundle icon. Do not extend it into
`port_parity.sh`.

**Finding text.** `Report` and its `render()` are printed by both CLIs and asserted on by
`ConversionTests` and `StagedPlanTests`. Change how findings look; never change what they say.
