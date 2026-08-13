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

@Test func deviceNameMatchesTheFileDialect() {
    #expect(KSPKit.deviceName == "KeyStepPro")
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

Four targets:

| Target | Is | Depends on | Builds on Linux |
|---|---|---|---|
| `KSPKit` | the format core; port of `src/ksp/` minus MIDI | **nothing** | yes |
| `KSPMIDI` | the Standard MIDI File layer | `KSPKit`, `SwiftMIDIFile` | no |
| `KSPSwiftCLI` | the `ksp-swift-cli` binary; port of `src/ksp_cli/` | `KSPMIDI`, `ArgumentParser` | no |
| `KSPKitTests`, `KSPMIDITests`, `KSPSwiftCLITests` | tests for each | | respectively |

`swift-midi-file` supports Apple platforms only. Rather than let that decide where the whole port
can be tested, `Package.swift` uses `#if os(Linux)` to drop the bottom three rows on Linux. `KSPKit`
therefore has **zero third-party dependencies**, and the bulk of the port (milestones M9–M11) builds
and tests on GitHub's Linux runners, which bill at 1× instead of macOS's 10×.

**So do not add a dependency to `KSPKit`.** That is the whole point of it. `swift-argument-parser`
does run on Linux, but it is declared inside the same `#else` because `KSPSwiftCLI` is the only
target that wants it and that target is gated off there anyway — no reason to make the Linux job
fetch a package it cannot use.

`KSPSwiftCLITests` tests an executable target, which SwiftPM allows only when the module has an
`@main` type rather than a `main.swift`. That is why the entry point is a `struct` in
`KSPSwiftCLI.swift` and not top-level code.

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
