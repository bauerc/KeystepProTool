# The app wears the device's visual language

*Key Step Pro Plus* looked sterile because it had no visual identity to be sterile against: every
style decision was inline in `DropView.swift`, the palette was whatever macOS supplied, and the
bundle shipped no icon at all. The obvious fix — invent a brand colour — would have made the app
look like some other tool. The KeyStep Pro already publishes a complete visual system in its own
manual, so we took that instead, on the same authority order [ADR 0001](0001-device-vocabulary-is-canonical.md)
gives words: the hardware is the one party that cannot change its mind, and it is where a user
meets the vocabulary first-hand.

The spine is the four track colours. Manual 2.5.2 §1.4: *"Green for Track 1, Orange for Track 2,
Yellow for Track 3 and Red for Track 4"* — silkscreened as painted zones on the panel and lit on
the step buttons, and §4.2.9 adds that *"this color-coding is consistently followed across the
entire front panel."* The app's pattern map is four rows of sixteen slots. It now wears the panel's
own colours in the panel's own order, and the identity costs nothing to invent because it was
never ours to invent.

## Consequences

**Only colours with a referent are adopted.** The device's grammar is track colour = identity,
white = now, blue = secondary function, red = unsaved edits. The first three map onto something
this app has: which track a row is, the playhead during a conversion, and the Advanced options.
**Red does not** — nothing here is ever in an unsaved state — so it stays out. Inventing an app
state to justify a colour is the failure mode this rule exists to prevent.

**Status may never rely on hue.** Track 2 is orange and Track 4 is red, which are the hues a
warning and an error would naturally take, and a finding row can sit directly beside either. So
severity is carried by glyph and sort order, and colour only agrees with them. `Palette.warning`
and `Palette.error` are deliberately duller and darker than the track hues they can neighbour.

**Hue never carries text contrast.** Track 3 is `#FACC00`, unreadable as text on the standard
unit's off-white ground. A track hue is always a fill that black or white ink sits on, the way the
painted zones carry black legends. This is what lets one set of track values serve both faces
instead of two tuned sets. It also demoted blue: at `#16B4E9` on `#E8E9ED` it cannot carry text, so
blue marks a secondary section rather than lettering it.

**Two faces, both authored.** The device ships as the off-white standard unit and the dark-grey
Chroma. Light mode is the standard unit, dark mode is the Chroma, and neither is derived from the
other. Because both are real products, the appearance control offers Standard / Chroma / System
rather than light / dark — the question is which unit is on the user's desk. It follows the system
by default.

**Track colours are fixed.** Chroma firmware lets an owner reassign them
(`Shift + Track → Track LED Color`). The app does not: it buys a settings surface, a persistence
concern and a palette that can no longer be designed against, for a feature almost nobody touches.
This is a decision, not an omission.

**The numerals are the device's.** Gates read `0.5 / 2 / 3.5 / 64`, time shift `−4 … +50`,
middle C is **C3**, and every figure is monospaced. This follows ADR 0001 directly: if the device's
words are canonical then so are its numbers, and a future session must not "fix" C3 to C4.

**The CLI is out of scope, permanently.** The two CLIs' output is a byte-for-byte contract held by
three parity scripts with Python as the reference implementation. Colourising terminal output would
mean changing two implementations in lockstep and re-fingerprinting three scripts, for a benefit
unrelated to how the app looks. The visual language stops at the window and the bundle icon.

**The preview grids remain the parity exemption they already were.** They emit no CLI text, so the
pattern map can change freely. `Report` and its `render()` are the opposite — both CLIs print them,
and `ConversionTests` asserts on `resultLine`, `previewLine` and finding fragments. The app changes
how findings *look*, never what they *say*.

## Considered options

**An invented brand accent**, rejected: it was the plan until the manual was read. A single amber
would have been one colour where the instrument has four, and would have made the pattern map look
like a generic file-converter's grid in a nicer hue.

**Arturia's own brand colour**, rejected on two grounds. It is not what anyone assumes: Arturia
themes each product family separately in their production CSS, and the KeyStep Pro carries
`--color-step-primary: #E0FB4A`, a lime — there is no "Arturia orange" in the current system. And
using a manufacturer's brand token in an unofficial tool that drives their hardware invites users
to read the app as first-party and blame Arturia for its bugs.

**Depicting the instrument**, rejected for the icon and the chrome: an off-white chassis with
Arturia's coloured zones is a picture of someone else's product, and is the closest this project
would come to trade dress. The abstraction — four rows of steps in the four track colours — is both
safer and more legible at 16pt.

**A full instrument-panel skin**, rejected: fake anodised surfaces and imitation LCD glyphs fight
macOS conventions, accessibility settings and both appearances, and read as costume. The app keeps
a native chassis — real sidebar, real toolbar, real controls — and puts the device's language on the
domain surfaces, which is where it means something.
