# Swift for people who have never touched a Mac toolchain

Written for someone fluent in Python or Java who has never shipped anything on macOS. It covers the
toolchain, the build system and dependency management, and it uses this package as the worked
example. It does not teach the Swift *language* — that is [the official
book](https://docs.swift.org/swift-book/), and it reads quickly if you know Java.

The one-line version: **Swift's tooling looks like Go's, works like Rust's Cargo, and is bundled
like a JDK.**

---

## 1. The toolchain

### There is no `pyenv` here

A Swift toolchain is one monolithic install: compiler, standard library, package manager, formatter,
debugger, test runner. It is closer to installing a JDK than to `pip install`. You do not create a
per-project environment — there is nothing like a virtualenv, because Swift compiles to a native
binary and links its dependencies in. The "environment" is the toolchain plus `.build/`.

On macOS the toolchain arrives one of two ways:

| | **Command Line Tools (CLT)** | **Full Xcode** |
|---|---|---|
| Size | ~1 GB | ~15 GB |
| Install | `xcode-select --install` | App Store |
| Gets you | `swift`, `swiftc`, `swift-format`, `lldb`, SDKs | all that, plus the IDE, simulators, Interface Builder, signing and notarisation tooling |
| Enough for | libraries, CLIs, servers — everything in this package today | GUI apps, and shipping anything to another human |

This repo is deliberately CLT-only until M13, when the GUI arrives. See §6 for the one place that
bites you.

`xcode-select -p` prints which toolchain is *active*. It is a machine-global pointer, roughly
`JAVA_HOME` for Apple's tools:

```sh
xcode-select -p                    # /Library/Developer/CommandLineTools  (CLT)
                                   # /Applications/Xcode.app/Contents/Developer  (Xcode)
sudo xcode-select -s /path/to/other # switch it
swift --version                    # what you actually have
```

`xcrun <tool>` resolves a tool relative to that active developer directory. You will see it in
error messages more often than you type it.

> **Multiple versions.** Apple's answer is "install several Xcodes and switch with `xcode-select`",
> which is as heavy as it sounds. [`swiftly`](https://github.com/swiftlang/swiftly) is the real
> version manager (think `pyenv`/`rustup`) if you ever need parallel toolchains. This project pins
> nothing locally and just uses whatever `swift --version` reports; CI pins via a container image.

### Linux is a first-class target

Swift is not Mac-only. `swift:6.2` on Docker Hub is an official Linux image with the same compiler
and SwiftPM. That is what CI here uses, and it is why §5 cares so much about which targets are
portable. What is *not* portable is Apple's frameworks — CoreMIDI, SwiftUI, AppKit — and any package
that depends on them.

---

## 2. The build system: SwiftPM

`swift build` is Maven, Gradle and pip rolled into one, and it ships with the compiler. There is no
separate install and no plugin ecosystem to configure.

### `Package.swift` is a program, not a config file

This is the biggest conceptual jump from `pom.xml` or `pyproject.toml`. `Package.swift` is **Swift
source code that SwiftPM compiles and runs** to produce a package description. The first line is a
magic comment declaring which manifest API version to compile against:

```swift
// swift-tools-version: 6.0
```

Because it is code, you can compute things. This package does exactly that — it builds its target
list with an `#if os(Linux)` conditional so the manifest itself is different on Linux. You cannot do
that in a `pom.xml`. The flip side: a typo in the manifest is a *compile error*, and manifest
compilation is a real build step you will occasionally wait for.

### Targets, products, modules

Three words that mean overlapping things:

- **Target** — a directory of source files compiled as a unit. **A target is also a module**, which
  is Swift's namespace and import unit. `import KSPKit` imports a target. Closest analogue: a Java
  package that is also a Maven module, or a Python package.
- **Product** — what the package exposes to the outside world: a `.library` other packages can
  depend on, or an `.executable` that produces a binary. A product bundles one or more targets.
  Think of a Maven artifact, or the `[project.scripts]` table in `pyproject.toml`.
- **Package** — the repository. One `Package.swift`, many targets.

Consumers depend on *products*; targets inside a package depend on *targets*.

### Directory layout is convention, not configuration

SwiftPM finds sources by path, Maven-style. Deviating means writing an explicit `path:` and is
rarely worth it:

```
Package.swift              # the manifest
Package.resolved           # the lockfile
Sources/<TargetName>/*.swift
Tests/<TargetName>Tests/*.swift
.build/                    # all build output; gitignored, safe to delete
```

`.build/` is `target/` or `__pycache__` — throwing it away costs you one rebuild and nothing else.

### The commands

```sh
swift build                # compile (debug by default)
swift build -c release     # optimised
swift run <product-name>   # build and execute an executable product
swift test                 # build and run tests
swift package clean        # or just: rm -rf .build
swift package dump-package # the manifest as JSON — useful when a conditional surprises you
```

Note `swift test` builds first, so a separate `swift build` in a CI script is redundant.

---

## 3. Dependencies

### `Package.swift` + `Package.resolved` = `pyproject.toml` + `uv.lock`

Exactly that split, with the same rationale:

- **`Package.swift`** declares *ranges* — "1.0.0 or newer, below 2.0.0".
- **`Package.resolved`** records the exact commit SHA each range resolved to. **It is committed**,
  same as `uv.lock` at the repo root. Without it, CI could quietly build against a different
  upstream commit than you did.

```swift
dependencies: [
    .package(url: "https://github.com/orchetect/swift-midi-file", from: "1.0.0")
]
```

`from: "1.0.0"` is semver-caret: `>= 1.0.0, < 2.0.0`. Other forms are `.upToNextMinor(from:)`,
`exact:`, `branch:`, `revision:` and `.package(path: "../local-thing")` for local development.

Then each target opts in individually — declaring a dependency at package level does **not** put it
on any target's import path:

```swift
.target(
    name: "KSPMIDI",
    dependencies: [
        "KSPKit",                                                  // a target in this package
        .product(name: "SwiftMIDIFile", package: "swift-midi-file") // a product from a dependency
    ]
)
```

### There is no PyPI or Maven Central

Dependencies are **git URLs**. There is no central registry, no publishing step, no `swift publish`.
You tag a release in your repo and that is the release. [Swift Package
Index](https://swiftpackageindex.com) is a search/metadata site over GitHub, not a host — nothing is
served from it.

Practical consequences:

- The *package* name (`swift-midi-file`, from the repo) and the *module* you import
  (`SwiftMIDIFile`) are usually different. Both appear in the manifest and it is a common trip-up.
- Deleting a dependency means removing it from the manifest **and** from every target that lists it.
- Package READMEs are the documentation. Read the compatibility table before assuming portability —
  that is precisely what decided this package's structure (§5).

```sh
swift package resolve          # fetch and write Package.resolved
swift package update           # re-resolve within the declared ranges, updating the lockfile
swift package show-dependencies # the resolved tree
```

---

## 4. Formatting and testing

### `swift-format` is `ruff format`

Bundled with the toolchain since Swift 6. Invoked as a subcommand of `swift`:

```sh
swift format --in-place --recursive --parallel Sources Tests Package.swift
swift format lint --strict --recursive --parallel Sources Tests Package.swift
```

Config lives in `.swift-format`, a JSON file found by walking up from each source file. This
package's overrides the default 2-space indent to 4 and sets a 100-column line length, matching the
repo's ruff settings.

Two traps: `lint` is a **subcommand**, not a `--lint` flag, and without `--strict` it prints
violations and still **exits 0**. A CI step missing `--strict` silently passes forever.

### Swift Testing is `pytest`; XCTest is `unittest`

Two frameworks coexist. **Swift Testing** is the modern one and what this package uses — free
functions with an attribute, plain expressions in assertions, parallel by default:

```swift
import Testing

@Test func keyBuildsTheGrammar() {
    #expect(Keys.key(125, 109, 1, 1, 10) == "125_109_1_1_10")
}

@Test(arguments: [1, 2, 3])            // parametrised, like @pytest.mark.parametrize
func isPositive(value: Int) {
    #expect(value > 0)
}
```

`#expect` records a failure and continues; `#require` throws and aborts the test, so use it to
unwrap optionals. `@Suite` groups tests, roughly a test class.

**XCTest** is the older, JUnit-shaped one: subclass `XCTestCase`, methods named `test*`,
`XCTAssertEqual`. You will meet it in older packages. It is not available in the Command Line Tools
at all — only in Xcode — which is one reason this package uses Swift Testing.

`@testable import KSPKit` in a test file gives access to `internal` declarations. Swift's default
access level is `internal` — visible within the module, invisible outside — so without `@testable`
your tests can only see what is marked `public`.

---

## 5. How this package is laid out, and why

Six targets:

| Target | Is | Depends on | Builds on Linux |
|---|---|---|---|
| `KSPKit` | the format core; port of `src/ksp/` minus MIDI | **nothing** | yes |
| `KSPMIDI` | the Standard MIDI File layer | `KSPKit`, `SwiftMIDIFile` | no |
| `KSPRun` | the command bodies and the bundled template | `KSPMIDI` | no |
| `KSPSwiftCLI` | the `ksp-swift-cli` binary: arguments and `@main` | `KSPRun`, `ArgumentParser` | no |
| `KSPApp` | the `ksp-app` binary: the SwiftUI drop window | `KSPRun`, `SwiftUI`, `AppKit` | no |
| `KSPKitTests` … `KSPAppTests` | tests for each | | respectively |

`swift-midi-file` supports Apple platforms only. Rather than let that decide where the whole port
can be tested, `Package.swift` uses `#if os(Linux)` to drop the bottom three rows on Linux. `KSPKit`
therefore has **zero third-party dependencies**, and the bulk of the port (milestones M9–M11, plus
M12's `Mutate.swift`) builds and tests on GitHub's Linux runners, which bill at 1× instead of
macOS's 10×.

**So do not add a dependency to `KSPKit`.** That is the whole point of it. `swift-argument-parser`
does run on Linux, but it is declared inside the same `#else` because `KSPSwiftCLI` is the only
target that wants it and that target is gated off there anyway — no reason to make the Linux job
fetch a package it cannot use.

The same rule decides where a *ported module* goes rather than only where a dependency does:
`mutate.py` imports no `mido`, so `Mutate.swift` is in `KSPKit`; `midi_export.py` and
`midi_import.py` both do, so they are in `KSPMIDI` whole. From M12 `swift.yml` runs a second job on
`macos-latest`, because it is the only one that can see `KSPMIDI` and above at all.

### Why `KSPRun` is a library and `KSPSwiftCLI` is only a face

**SwiftPM forbids a non-test target from depending on an executable target.** A test target may
`@testable import` one, which is why `KSPSwiftCLITests` works, but an ordinary target cannot link
one at all. So every line that lived in `KSPSwiftCLI` was reachable from exactly one place: the
`ksp-swift-cli` binary.

That was fine until M13. The app has to run the *same* `convert` the CLI runs — the parity scripts
compare the Swift against the Python byte for byte, and a second implementation in the app would be
outside that net on the day it drifted. So the command bodies moved down into `KSPRun` and both
faces call them:

```
KSPKit  <-  KSPMIDI  <-  KSPRun  <-  KSPSwiftCLI   (@main, ArgumentParser)
                             ^
                             +------  KSPApp       (M13, SwiftUI)
```

`KSPSwiftCLI` keeps the `ParsableCommand` structs, `RootCommand`, `ExitStatus` and `@main`. A
command's body — anything that reads a file, decides an exit code or builds a message — goes in
`KSPRun`. Each runner's `Options`, and the one `RunResult` all three return, are `public` and
`Sendable` there, with spelled-out initialisers, because a public struct's memberwise initialiser
is internal and every caller is now in another module. `KSPRun` is also declared as a `.library`
product, not just a target, so both faces link it by name.

`KSPApp` turned out to need no Xcode at all. The Command Line Tools SDK ships `SwiftUI.framework`,
`AppKit.framework` and `UniformTypeIdentifiers.framework`, and a `.app` is a directory with an
`Info.plist` — so the GUI is an ordinary `executableTarget` and `scripts/bundle_app.sh` does the
wrapping and the ad-hoc signing. `xcodebuild`, `actool` and `ibtool` are the only things missing
from a CLT install, and a hand-assembled bundle needs none of them. `bundle_app.sh` is deliberately
**not** in `validate.sh`, which compiles the target through `KSPAppTests` instead.

`RunResult` carries the run twice over. `stdout`/`stderr`/`code` are the terminal's view, rendered
inside `KSPRun` so the CLI stays a shell — `emit(_:)` in `KSPSwiftCLI` is the only place they reach
a stream — and so the parity scripts keep comparing text this module produced. `diagnostics` (a
`KSPKit.Report`) and `destinations` are the same run said structurally, for a caller with no
terminal: M13.2's app lists findings through `Report.render(verbose:)` and reveals what was
written, rather than re-parsing `stderr` or re-deriving the destination rule.

The model serialises through `JSONNode` rather than `Encodable`: `JSONEncoder` controls neither key
order nor the `120` vs `120.0` rendering of a whole-numbered `Double`, and both are load-bearing on
the parity contract.

`KSPRun` carries one resource: `Resources/Default.KeyStepPro`, MCC's factory default, which
`convert` overwrites when the user names no `--template`. The real bytes live there and
`src/ksp_cli/templates/Default.KeyStepPro` is a symlink to them, not the other way round — SwiftPM
copies a symlink *as a symlink* (measured, with both `.copy` and `.process`), which would leave a
dangling link in the bundle, while Python and hatchling follow one transparently.

### Inside `KSPApp`

**`KSPApp` owns no format logic** — only where a file goes, what it is called and which options the
window offers. SwiftUI lives in `DropView.swift` and `KSPApp.swift` and nowhere else in the target,
which is what leaves the rules themselves as plain types a test can call. Every mutable value lives
on the one `@MainActor` `AppModel`, which is Observation and AppKit, no SwiftUI.

**A new option is a property on `Settings` plus a line in each of its two mappings** onto
`ConvertRunner.Options` and `ExportRunner.Options`. An option left out of a mapping silently keeps
the runner's own default — and that is exactly what makes the app on defaults convert what the CLI
on defaults converts. Conversions run in a `Task.detached`, which is what the `Sendable` `Options`
and `RunResult` are for; so does the staged view's read of a dropped project, where `DropView`'s
`.task` asks `AppModel.summarise()`, which asks `Conversion.summarise` for a `SummaryState`.

**`SummaryRunner` is the deliberate exception to `RunResult`.** It returns a `ProjectSummary` and
renders no text at all. No CLI output to compare means no Python mirror and no parity gate, which
is the whole reason the preview work is affordable — so **a preview must never add a CLI flag**
(#115); giving it a subcommand would forfeit the exemption and pay full parity. Its counts say
*enabled*, never *audible*: they answer the two reasons a note is switched off, not the spec's six
reasons one might not play.

The preview is a track × pattern grid, and **what it decides lives in `PatternGrid.swift`**, not in
`DropView`: what a cell prints, which chained cells are joined, and — in `AppLayout` — every
dimension the window and the grid are both built from. That one enum is why the pattern axis fits.
The window resizes freely above a floor `AppLayout` names, and the extra width goes to the source
track's name — the 16-column grid stays fixed, because its chain rails are drawn at absolute offsets
and a stretching axis would slide them off their cells. The staged pane still scrolls vertically
only, so a row too wide for it is *silently clipped*; the fit tests are asserted against
`minimumContentWidth`, the pane at the narrowest the window goes, which is the one width a user
cannot resize their way out of. Change the sidebar and the test says so. **Every column a track row
draws is in `trackColumnWidths`** — the destination picker was drawn for a release without being
counted there, and hung 110 pt off the pane in silence until a test counted the columns.

`KSPSwiftCLI` has no `main.swift`. That is a choice, not a requirement: SwiftPM will happily let
`KSPSwiftCLITests` `@testable import` an executable target that uses top-level code, and the suite
passes either way. The entry point is an `@main` type because the exit-code mapping reads better as
a named `Entry` than as statements at the bottom of a file, and `@main` cannot coexist with
top-level code — `'main' attribute cannot be used in a module that contains top-level code` — so the
file name goes with it.

To see the effect, force the branch and dump the manifest:

```sh
sed 's/^#if os(Linux)$/#if true/' Package.swift > /tmp/p.swift  # (in a scratch copy)
swift package dump-package                                       # KSPKit + KSPKitTests, no deps
```

---

## 6. The one gotcha on a Mac without Xcode

**Run the tests via `../scripts/validate.sh`, not `swift test`.**

The Command Line Tools *do* ship Swift Testing, as `Testing.framework` under
`$(xcode-select -p)/Library/Developer/Frameworks`. What they do not do is put it on the compiler's
framework search path or the runtime's library path, and the `_Testing_Foundation` cross-import
overlay has no `.swiftinterface` there at all — so a test importing both `Testing` and `Foundation`
fails to compile. A bare `swift test` gives you `no such module 'Testing'` or `no such module
'_Testing_Foundation'`, neither of which hints at the cause.

Three flags bridge it, and `validate.sh` adds them automatically when it detects a CLT install:

```sh
-Xswiftc -F -Xswiftc "$CLT/Library/Developer/Frameworks"
-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
-Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks"
```

`-Xswiftc` / `-Xlinker` / `-Xcc` forward a flag to the compiler, linker or C compiler. They are the
escape hatch whenever SwiftPM has no first-class option for what you need. Under a full Xcode
install none of this is necessary and `validate.sh` adds nothing.

CI does not hit this: the Linux container has a complete toolchain, so `swift.yml` runs a plain
`swift test`.

---

## 7. Cheat sheet

| You know | Swift |
|---|---|
| `pyproject.toml` / `pom.xml` | `Package.swift` (but it is executable code) |
| `uv.lock` / `package-lock.json` | `Package.resolved` (committed) |
| `pip install` / `mvn dependency:resolve` | `swift package resolve` |
| `venv` | nothing — there is no per-project environment |
| `python -m build` / `mvn package` | `swift build -c release` |
| `pytest` | `swift test` |
| `ruff format` | `swift format --in-place` |
| `ruff check` | `swift format lint --strict` |
| `mypy` | the compiler; there is no separate type checker |
| `target/`, `__pycache__/` | `.build/` |
| `JAVA_HOME` | `xcode-select -p` |
| PyPI / Maven Central | git URLs; no registry exists |
| `import foo` finds a package | `import Foo` finds a **target/module** |
| public by default | `internal` by default; `@testable import` to reach it from tests |
