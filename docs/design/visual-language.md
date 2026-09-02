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

Adopted: track colours (a row's track), white (the conversion playhead, §4.2.9 — *"the currently
playing step, which is lit up in white"*), blue (Advanced options, §4.2.14 — the 63 SHIFT functions
are silkscreened blue).

Not adopted: **red**. Nothing in this app is ever in an unsaved state. Do not invent one to justify
the colour.

Blue is a **marker**, not lettering — `#16B4E9` on the light ground fails contrast as text, so it
rules or dots a secondary section while the label stays in `ink`.

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
| `band` | `#0D0D0D` | `#0C0A0B` |
| `bandInk` | `#E9F0FF` | `#E9F0FF` |
| `ink` | `#14161A` | `#E7E9EC` |
| `mutedInk` | `#5A6068` | `#9199A1` |
| `rule` | `#C4C8CE` | `#34373C` |

The appearance control offers **Standard / Chroma / System**, not light / dark: both are real
products, and the question is which unit is on the user's desk. It follows the system by default.

## The objects

Named from device vocabulary, never from shape — see `CONTEXT.md`.

### The control band

A dark strip across the top of the content area carrying the file name, the direction and Convert.
It mirrors the panel's own matte black band, which holds the OLED, the knobs and the four track
displays above the coloured track zones.

It is what stops the light face being a white void with four coloured rows floating in it.

### The pattern map

Four tracks down, sixteen pattern slots across. Each row wears its track's colour.

### Slot cells

Three orthogonal channels, so no combination of states turns to mud:

| Channel | Means | Never means |
|---|---|---|
| **Fill** | content — the track hue at an intensity ramping with notes per step | anything about export |
| **Stroke** | intent — solid exports, dashed does not | anything about content |
| **Bottom rule** | length — a fraction of the cell width for 16 / 32 / 48 / 64 steps | |
| **The figure** | events switched on, SF Mono | |

Chain membership lives on the **chain rail** beneath the row, never inside a cell.

A slot cell **cannot show rhythm**. No per-step data reaches the summaries; density, length and
kind are all that exist. Do not add per-step plumbing to make a cell prettier.

### Row heads

A two-digit **pattern-number readout** in a dark well, after the hardware's four 7-segment displays
sitting above each coloured track zone.

**SF Mono, not a seven-segment face.** The placement and the role are the fidelity; imitating LCD
glyphs with dead segments is where this becomes costume.

Track 1 in drum mode is **badged on the row**; its cells are not restyled. Row 1 stays green
whether it is sequencing or drumming — that is what the device does.

### Limit meters

Segmented, filling toward a marked ceiling, figure in SF Mono. The one place a literal hardware
idiom is earned: the device's limits are genuinely hard ceilings, and metering against a ceiling is
what segmented LED metering is for.

The meter itself is pure quantity: lit segments, unlit segments, and a static cap at the ceiling.

**Only a refusal is marked.** Near (≥75%) takes `warning` and no glyph — the meter already says
how close the figure sits, so approaching a wall is emphasis on a quantity, not a status. Over
means the planner refused something, which *is* a status, and it takes `error` and
`exclamationmark.triangle` together — rule 2.

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

## Motion

**One thing moves: a white playhead across the pattern map while a conversion runs.** White is what
the device lights the currently playing step (§4.2.9). It is the one moment the app has nothing
else to show.

- Honour `reduce-motion`; fall back to the static progress view.
- Give it a floor, or a sub-second conversion flashes once and reads as a glitch.

**Nothing else in the app animates.** Everywhere else, motion is noise.

## The icon

Four rows of steps in the four track colours on the black band — a miniature of the app's own
pattern map and of the panel. Green-orange-yellow-red stays distinctive when the shapes blur at
16pt.

Do not depict the instrument itself: an off-white chassis with Arturia's coloured zones is a
picture of someone else's product (ADR 0002).

## Out of scope

**The CLI.** Its output is a byte-for-byte contract across two implementations held by three parity
scripts. The visual language stops at the window and the bundle icon. Do not extend it into
`port_parity.sh`.

**Finding text.** `Report` and its `render()` are printed by both CLIs and asserted on by
`ConversionTests` and `StagedPlanTests`. Change how findings look; never change what they say.
