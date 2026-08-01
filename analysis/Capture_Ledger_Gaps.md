# Capture ledger — outstanding values

**What this is.** The captures for B0, Tier 1, Tier 3 and Tier 4 have been run and their results
are decoded and folded into [`KeyStepPro_Format_Spec.md`](./KeyStepPro_Format_Spec.md). Those
tests are done and have been removed from
[`Hardware_Test_Protocol.md`](./Hardware_Test_Protocol.md), which now covers only unfinished work.

A handful of things were never written down at the desk, and **cannot be recovered from the
files**. Each one below is a question only a person at the device (or with the notes from that
session) can answer.

**How to use it.** Answer in the **Your answer** box on the right. Leave a box blank rather than
guessing — a blank is honest, a guess gets believed. When a row is answered, fold it into the
spec and delete the row.

> **Do not fill a *displayed value* in from the stored value.** Whether the two agree is the
> entire point of the question. If you no longer remember what the display read, write
> `don't recall` — that is a useful answer and a fabricated one is not.

---

## 1. Reproducibility — how the captures were exported

| # | ***Question*** | Why it matters | Your answer |
|---|---|---|---|
| 1.1 | ***What exact route did you use to get a project off the device and into a `.KeyStepPro` file?*** (e.g. sync from KSP into MCC → Project menu → Save As → which folder) | The protocol asks for this to be recorded once so the captures are reproducible. Nobody can repeat a capture without it, and the whole corpus depends on the route being the same each time. | On the physical keyboard, it Save and Project at the same time. Click the encoder button next to the display to save. Using MCC, click the project that was saved (been using the Project 2 slot) and select the 'Recall From' button on the MCC UI. Then using linux commands used `mv` to moved the saved and renamed project file to the project directory, for example  From: /Library/Arturia/MIDI Control Center/Templates/KeyStepPro/T2gatetable.KeyStepPro
  To:   /Users/cameronbauer/repos/KeystepProTool/project_files/captures/T2-gate-table.KeyStepPro |

---

## 2. Displayed values — the numbers that only existed on the screen

These are the cases where the file records a stored number and the *displayed* number was never
noted. The stored value is already in the spec; what is missing is what the device called it.

| # | ***Question*** | Stored value (from the file) | Your answer |
|---|---|---|---|
| 2.2 | ***What ARP octave did the display show before and after you changed it in T3.4?*** | `100` field at bits 4–6 went 1 → 2 | The ARP Octave is NOT a display value on the device UI. It is a selection on the physical keys starting on the second physical octave. The default value was 0 (the C#3 key). I held the SHIFT button on the device and hit the D3 key to select ARP Octave +1 as marked on the device physically. The device has 5 values for ARP Octave, -1 0 +1 +2 +3|
| 2.3 | ***In D4, what step counts did the display show — for the lane you shortened, and for the others?*** | `51` = 11 and 15 | Step Count for the short one was marked as 12. The rest were marked as 16. To get this behaviour I had to select Poly mode in Track 1 Drum mode. This was done by holding the SHIFT key and pressing what would E2 key. The Seq/Drum Mode options are Mono and Poly. Mono would be on the D#2 key|
| 2.4 | ***In D2, what were the four pitches of the chord you played?*** | `109` = 48, 52, 55, 59 | C2, E2, G2, B2|
| 2.5 | ***Place one note with the Gate display reading `5.25` and export.*** Not a recall question — a 30-second capture. | `110` should store **36** | |

**Why 2.3 is worth answering.** It tests a decoding assumption: if D4's display read `12` and
`16`, that confirms `51` is 0-based — which the spec currently states as an inference. (The old
2.1 asked what gate the T1.1 fresh note displayed; it read `0.5`, which confirms the gate ladder's
`7 → 0.5` entry from a second session. Folded into spec §6.1 and removed.)

**2.5 is the one gap the gate sweep left.** Every other entry in the 128-value ladder is either
transcribed or pinned by a boundary probe; stored `36` is derived because that note was
over-turned by one detent during the sweep. One note closes it.

---

## 3. Device behaviour — things the file cannot show

The file records the end state. These questions are about what the device *did*, which is only
visible while it is happening.

| # | ***Question*** | Context | Your answer |
|---|---|---|---|
| 3.1 | ***After you toggled step 5 off in D1, did the device UI still show that step as containing something?*** | You already recorded that beat 5 **did not sound** — that is the key result and it is banked. This asks whether the UI distinguishes "step off, note still stored" from "step empty". | No. The device showed nothing. The 5 step key is a physical button. You can turn it on and off by pressing it. If it is on, it is lit up. If it is up it is off. It is impossible to overwrite the button. If you press a new pitch and then press and hold 5 it will merely turn on the old note. To fully erase it you must hold the ERASE button on the device and press the physical step button|
| 3.2 | ***In D3, when you hit the 192-note limit, did the device refuse the next hit, or overwrite an existing one?*** | You recorded the 192-note error message. Refuse vs overwrite decides what a writer must do when source material is too dense — reject the file, or drop notes and warn. | The device refused the next hit and immediately displayed the error message on the display. |
| 3.3 | ***In D2, when you added the 4th note to the chord, did the device give any feedback, or did it just accept it?*** | The file shows it accepted, in slot 1 ordinal 4. If the device said nothing, then there is no 3-note limit at all and the old "poly slots cap at 3" note was simply wrong. | No feedback. To add the note, the device had to enter Step Edit mode (a physical button) and then press the new note to add it to the others. Step Edit is not on by default and turns off if you switch to a different project and switch back|

---

## 4. One thing to check at the desk, no capture needed

| # | ***Question*** | Why it matters | Your answer |
|---|---|---|---|
| 4.1 | ***Do you still have the notes from the 2026-07-31 session, or is what is in the files all that survives?*** | Decides whether section 2 is answerable at all, or whether those four values need their captures re-run. | What is the 7 31 session? All the notes in the files when I imported the midi dumps to Logic Pro were exactly as I entered them into the Keypad Pro|

---

## Already answered — nothing needed

Recorded here so nobody re-runs them looking for a blank:

- **B0.2** — the two untouched exports are byte-identical. No keys drift on their own.
- **D1** — beat 5 did not sound with its step-active flag clear. This is the finding the whole
  step-active change rests on.
- **D3** — the device showed a 192-note limit error once three lanes held 64 notes each.
- **T2** — the gate ladder: `stored = detent − 1`, 128 entries, 0.0625–64 steps, drum identical.
  The 64 transcribed displays are in `gate_display_sweep.txt`; only stored `36` is outstanding
  (2.5 above).
