# The device's vocabulary is canonical

Three sources name the same concepts differently — the KeyStep Pro's front panel and Arturia's
manual, MIDI Control Center's labels, and this repository's own identifiers — and they disagree in
ways that were silently corrupting the docs. We took Arturia's wording as canonical, because the
hardware is the one party that cannot change its mind and is where a user meets the vocabulary
first-hand. MCC's and the repo's words are recorded as alternatives, never used as the name.

## Consequences

**The docs and the code deliberately say different things.** `CONTEXT.md` says *drum track* and
*trigger*; `ksp/` and `KSPKit` say *lane* and *note*. That is the decision, not an oversight.
The glossary binds prose, documentation, UI text, diagnostics and newly written code immediately;
existing identifiers are recorded as alternatives and renamed only when their file is already open
for other reasons. There is no standalone rename PR, ever.

The reason is the parity contract. The two CLIs' output is byte-for-byte identical by design, held
by three scripts that fingerprint both implementations. Any rename reaching a diagnostic string or
a CLI option is therefore a two-core commit plus a parity re-fingerprint — real cost, for a change
no user can observe. Paying it forward on new code is free; paying it backwards is not.

**Shipped CLI surfaces do not move.** `--slot` names what the glossary calls a Project, and
`--drum-map` / `drumMapSpec` names drum tracks. Both stay.

**When a device term collides with a MIDI-standard term** for a different concept, the MIDI
standard keeps the word and the device sense takes a qualified name. Half this tool's output is a
`.mid` file read by software that has never heard of a KeyStep Pro, and MIDI's meanings are fixed
by a spec that outranks any one manufacturer. There is no current instance: Arturia uses *step*
for a grid position and *beat* for the quarter note, so the two vocabularies already agree.

## Considered options

**MCC's vocabulary**, rejected: it is a third party's rendering of Arturia's concepts, and it
introduced *lane*, a word the manual uses only as a DAW analogy.

**The repo's existing identifiers**, rejected: they are the least authoritative of the three and
the source of the collisions — a single *note* covering both melodic and drum events, and *slot*
used for three different things where Arturia sanctions one.

**Renaming the code to match**, rejected on cost: see the parity contract above.
