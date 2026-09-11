"""Freeze the Python CLI's answer to every parity-gate case into fixtures/reference/.

Run as ``uv run python tools/gen_reference.py``; fixtures/README.md says what each file pins.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
from collections.abc import Iterator
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

import mido
from midi_events import render

from ksp.lenient_json import canonical, dump_path, load_path

ROOT = Path(__file__).resolve().parent.parent
REFERENCE = ROOT / "fixtures" / "reference"
BIN = Path(sys.executable).parent
TEMPLATE = "swift/Sources/KSPRun/Resources/Default.KeyStepPro"
PROG = re.compile(r"^(ksp2midi|midi2ksp): ", re.MULTILINE)

EXPORT_FLAGS = (
    "",
    "--passes 1",
    "--no-swing",
    "--no-time-shift",
    "--include-stale --include-disabled",
    "--drum-channel 16",
    "--tracks 1,3",
    "--patterns 1-4",
    "--no-markers",
    "--repeat 2",
    "--flat-velocity fresh",
)
SPLIT_FLAGS = ("--split", "--split --repeat 2")
EXPORT_REFUSALS = (
    ("--tracks refused alike", "--tracks bad"),
    ("--tracks past Int, in a range", "--tracks 3-99999999999999999999"),
    ("--tracks bad and --drum-map bad", "--tracks bad --drum-map garbage"),
    ("--repeat past its limit", "--repeat 11"),
    ("--flat-velocity refused alike", "--flat-velocity 0"),
    ("--flat-velocity not a velocity", "--flat-velocity loud"),
    ("--flat-velocity past Int", "--flat-velocity 99999999999999999999"),
)
# (label suffix, flags) where the two differ; the flags are the label otherwise.
IMPORT_FLAGS: tuple[str | tuple[str, str], ...] = (
    "",
    "--no-swing-fit",
    "--no-time-shift",
    "--steps-per-beat 8",
    "--drum-track 1",
    "--drum-channel 1",
    "--drum-channel 3",
    "--drum-channel 1 --drum-track 1",
    "--no-drums",
    "--no-drums --drum-track 1",
    "--drum-channel 3 --no-drums",
    "--midi-track 1",
    "--route 1:2",
    "--route 3:1,4:2",
    "--route bad",
    "--route 1:9",
    "--route 1:2,3:2",
    "--route=-1:2",
    ("--route=Int.min", "--route=-9223372036854775808:1"),
    "--midi-track 1 --route 1:2",
    "--midi-tracks 1,2",
    "--midi-tracks 1-2",
    "--midi-tracks bad",
    "--midi-tracks 0",
    "--midi-tracks 99",
    "--midi-track 1 --midi-tracks 1",
    "--midi-tracks 1 --drum-track 2",
    "--midi-tracks 1,2 --route 2:1",
    "--midi-tracks 1,2 --route 3:1",
    "--flat-velocity fresh",
    "--flat-velocity 64",
    "--flat-velocity 0",
    "--flat-velocity loud",
    ("--flat-velocity past Int", "--flat-velocity 99999999999999999999"),
)
SIMPLE = "project_files/test_file_simple.mid"
CHORDS = "project_files/test_file.mid"
MERGES = (
    ("simple + chords", (SIMPLE, CHORDS), ""),
    ("chords + simple", (CHORDS, SIMPLE), ""),
    ("two files --midi-tracks 2", (SIMPLE, CHORDS), "--midi-tracks 2"),
    ("two files --midi-tracks 99", (SIMPLE, CHORDS), "--midi-tracks 99"),
    ("two files --route", (SIMPLE, CHORDS), "--route 2:1,1:2"),
    ("two files --midi-track", (SIMPLE, CHORDS), "--midi-track 1"),
)
TAPES = (("recall_tape.txt", 1), ("recall_project_2_tape.txt", 2))

# The gate's own Python half, verbatim: FakeDevice replays the tape in place of the device.
PULL = """
import pathlib
import sys

sys.path.insert(0, "tests")
from conftest import DeviceModel, FakeDevice, tape_values

from ksp_cli import pull

tape, slot, template, output = sys.argv[1:5]
device = FakeDevice({int(slot): DeviceModel(tape_values(pathlib.Path(tape)))})
pull.UsbMidiTransport = lambda **_: device
sys.exit(
    pull.main(
        [output, "--slot", slot, "--template", template, "--no-identity", "--quiet", "--also-midi"]
    )
)
"""

Record = dict[str, object]


@dataclass(frozen=True)
class Case:
    direction: str
    label: str
    inputs: tuple[str, ...]
    flags: tuple[str, ...]


def samples(pattern: str) -> list[str]:
    return sorted(str(path.relative_to(ROOT)) for path in ROOT.glob(pattern))


def midi_cases() -> Iterator[Case]:
    for project in samples("project_files/*.KeyStepPro"):
        name = Path(project).name
        for flags in EXPORT_FLAGS:
            yield Case("export", f"{name} {flags}".rstrip(), (project,), tuple(flags.split()))
        for flags in SPLIT_FLAGS:
            yield Case("split", f"{name} {flags}", (project,), tuple(flags.split()))
    for label, flags in EXPORT_REFUSALS:
        yield Case("export", label, ("project_files/project_9.KeyStepPro",), tuple(flags.split()))
    for clip in samples("project_files/*.mid") + samples("analysis/captures/*.mid"):
        name = Path(clip).name
        for entry in IMPORT_FLAGS:
            suffix, flags = entry if isinstance(entry, tuple) else (entry, entry)
            yield Case("import", f"{name} {suffix}".rstrip(), (clip,), tuple(flags.split()))
    for label, inputs, flags in MERGES:
        yield Case("import", label, inputs, tuple(flags.split()))


def slug(label: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", label).strip("_-")


def write_json(path: Path, record: Record) -> None:
    path.write_text(json.dumps(record, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")


def cli(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(BIN / args[0]), *args[1:]], capture_output=True, text=True, cwd=ROOT, check=False
    )


class Store:
    """Artifact records; each distinct project's ``dump --json`` is written once, by hash."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.dumped: set[str] = set()
        listed = subprocess.run(
            ["git", "ls-files", "*.KeyStepPro"], capture_output=True, text=True, cwd=ROOT
        ).stdout.split()
        self.tracked = {
            hashlib.sha256((ROOT / name).read_bytes()).hexdigest(): name
            for name in reversed(listed)
            if not (ROOT / name).is_symlink()
        }

    def artifact(self, path: Path) -> Record:
        if path.suffix == ".mid":
            return {"events": render(mido.MidiFile(path))}
        if path.suffix != ".KeyStepPro":
            raise ValueError(f"{path.name}: no reference form for this kind of file")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest in self.tracked:
            return {"same_as": self.tracked[digest]}
        with self.lock:
            fresh = digest not in self.dumped
            self.dumped.add(digest)
        if fresh:
            dumped = cli("ksp-dump", str(path), "--json")
            if dumped.returncode:
                raise RuntimeError(f"ksp-dump {path.name}: {dumped.stderr}")
            (REFERENCE / "projects" / f"{digest}.json").write_text(dumped.stdout)
        return {"sha256": digest}


class Sandbox:
    """What the gates redirect HOME to, and the check that none of its paths leaks into a file."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.spellings = {str(path), os.path.realpath(path)}

    def scrub(self, text: str, out: str) -> str:
        text = PROG.sub(
            "<prog>: ", text.replace(out, "<out>/").replace(str(self.path), "<sandbox>")
        )
        if any(spelling in text for spelling in self.spellings):
            raise RuntimeError(f"a temporary path survived the scrub: {text!r}")
        return text


def port_parity() -> int:
    count = 0
    for project in samples("project_files/*.KeyStepPro"):
        for mode, suffix in (("--json", ".json"), ("", ".txt")):
            dumped = cli("ksp-dump", project, *mode.split())
            if dumped.returncode:
                raise RuntimeError(f"ksp-dump {project} {mode}: {dumped.stderr}")
            (REFERENCE / "port_parity" / f"{Path(project).name}{suffix}").write_text(dumped.stdout)
            count += 1
    return count


def writer_parity(store: Store, sandbox: Sandbox) -> int:
    projects = samples("project_files/*.KeyStepPro")
    for project in projects:
        name = Path(project).name
        written = sandbox.path / "writer" / name
        written.parent.mkdir(exist_ok=True)
        dump_path(canonical(load_path(ROOT / project)), written)
        write_json(REFERENCE / "writer_parity" / f"{name}.json", store.artifact(written))
    return len(projects)


def pull_parity(store: Store, sandbox: Sandbox) -> int:
    directory = sandbox.path / "pull"
    directory.mkdir()
    for tape, slot in TAPES:
        output = directory / f"pulled_{slot}.KeyStepPro"
        arguments = (f"fixtures/{tape}", str(slot), TEMPLATE, str(output))
        pulled = subprocess.run(
            [sys.executable, "-c", PULL, *arguments],
            capture_output=True,
            text=True,
            cwd=ROOT,
            check=False,
        )
        if pulled.returncode:
            raise RuntimeError(f"pull over {tape}: {pulled.stderr}")
        artifacts = {
            path.name: store.artifact(path) for path in (output, output.with_suffix(".mid"))
        }
        record: Record = {"tape": tape, "slot": slot, "artifacts": artifacts}
        write_json(REFERENCE / "pull_parity" / f"slot_{slot}.json", record)
    return len(TAPES)


def midi_case(index: int, case: Case, store: Store, sandbox: Sandbox) -> Record:
    directory = sandbox.path / f"case-{index}"
    out = f"{directory}/py/"
    Path(out).mkdir(parents=True)
    command, name = {
        "export": ("ksp2midi", "out.mid"),
        "split": ("ksp2midi", ""),
        "import": ("midi2ksp", "out.KeyStepPro"),
    }[case.direction]
    ran = cli(command, *case.inputs, *case.flags, "-o", out + name)
    artifacts: Record = {}
    if ran.returncode == 0:
        artifacts = {path.name: store.artifact(path) for path in sorted(Path(out).iterdir())}
    shutil.rmtree(directory)
    return {
        "label": case.label,
        "direction": case.direction,
        "inputs": list(case.inputs),
        "flags": list(case.flags),
        "exit": ran.returncode,
        "stdout": sandbox.scrub(ran.stdout, out),
        "stderr": sandbox.scrub(ran.stderr, out),
        "artifacts": artifacts,
    }


def midi_parity(store: Store, sandbox: Sandbox) -> int:
    cases = list(midi_cases())
    names = [slug(case.label) for case in cases]
    if len(set(names)) != len(names):
        raise RuntimeError("two case labels share a file name")
    with ThreadPoolExecutor(os.cpu_count()) as pool:
        records = pool.map(
            lambda item: midi_case(item[0], item[1], store, sandbox), enumerate(cases)
        )
        for name, record in zip(names, records, strict=True):
            write_json(REFERENCE / "midi_parity" / f"{name}.json", record)
    return len(cases)


def main() -> int:
    if not samples("analysis/captures/*.mid"):
        print(
            "gen_reference: analysis/captures/*.mid is gitignored and absent here, so its cases "
            "would drop out of the references; run from a checkout that holds the captures",
            file=sys.stderr,
        )
        return 1
    with tempfile.TemporaryDirectory() as temporary:
        sandbox = Sandbox(Path(temporary))
        os.environ["HOME"] = temporary
        shutil.rmtree(REFERENCE, ignore_errors=True)
        for part in ("port_parity", "writer_parity", "midi_parity", "pull_parity", "projects"):
            (REFERENCE / part).mkdir(parents=True)
        store = Store()
        counts = {
            "port_parity": port_parity(),
            "writer_parity": writer_parity(store, sandbox),
            "pull_parity": pull_parity(store, sandbox),
            "midi_parity": midi_parity(store, sandbox),
        }
    summary = ", ".join(f"{gate} {count}" for gate, count in counts.items())
    print(f"gen_reference: {summary}; {len(store.dumped)} distinct projects dumped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
