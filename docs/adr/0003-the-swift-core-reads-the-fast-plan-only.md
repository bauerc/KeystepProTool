# The Swift core reads the fast plan only

Reading a project off the device exists twice in Python. `bulk_plan.iter_requests` reproduces MIDI
Control Center's own stream — 8,951 requests, one value each — and `bulk_fast.iter_requests`
coalesces the identical addresses into 2,044, then lets the melodic existence array settle the
note parameters it gates. `bulk_read` walks either, and `--mcc-plan` picks the slow one.

`KSPKit` gets the coalesced walk and nothing else. MCC's stream is not a feature; it is evidence.
Its whole job is to prove that the fast plan asks for the same 117,783 addresses MCC asked for, and
that proof is made once, in Python, against the two recall tapes — a second implementation of the
same walk would corroborate nothing the first has not already corroborated, and would need those
tapes replayed through a Swift transport that does not exist. It also costs about four times as
long against real hardware, so nobody would choose it.

## Consequences

**There is no `fast:` parameter anywhere in the Swift API.** A boolean whose false branch does not
exist is worse than no boolean: it reads as an unfinished feature and invites the next person to
implement the slow walk purely to make the flag honest. `BulkFast.iterRequests()` is the plan, and
its name says which one it is.

**`BulkPlan` is an address table, not a walk.** It carries the leaves and nothing that iterates
them in MCC's order, so the 8,951-request stream has no Swift expression to reach for. A Swift
device-read command, when one lands, has no `--mcc-plan` to expose.

**The two tables can drift, and a fixture is what catches it.** `tools/gen_bulk_plan.py`
regenerates the Python table from Arturia's descriptor on a firmware update; `BulkPlan.swift` is a
transcription and would not notice. `tests/fixtures/bulk_fast_requests.txt` is the whole coalesced
sequence as the Python plan produces it, and both suites assert against it — Python in
`test_bulk_fast.py`, Swift in `BulkFastTests.swift` — so a regenerated table that has not reached
Swift fails on both sides. The three parity scripts cannot help here: they diff CLI output, and the
read plan reaches no CLI in Swift.

## Considered options

**Port both walks**, rejected on the cost above: two consumers of the table, a Swift tape replay to
build, and no new fact established at the end of it.

**Port the fast walk behind `fast: Bool = true`**, rejected: the false branch would not exist. The
flag would be a promise the core does not keep.

**Leave the read plan in Python entirely**, rejected: a command body goes in `KSPRun` and both faces
must run the same one, so the plan has to be in `KSPKit` before the app can ever read a device. It
also keeps the port a translation of pure functions, which is the property the whole `swift/` tree
is arranged around.
