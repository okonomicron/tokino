# iOS build and testing

## What needs a Mac, and what does not

The brief asks for the MacBook to be used only when genuinely necessary. This is
the honest accounting.

| Task | Needs your Mac? | Where it happens |
|---|---|---|
| Writing Swift, SwiftUI, tests | No | Cloud container |
| Compiling and testing `TokinoKit` | No | Linux, every push, free |
| Compiling the iOS app | No | GitHub macOS runner, free while public |
| Running simulator unit tests | No | GitHub macOS runner |
| Simulator screenshots | No | macOS runner |
| **Apple Developer enrolment** | Browser only | — |
| **Enabling Xcode Cloud the first time** | **Yes, once, ~15 min** | Xcode on your Mac |
| Signing, TestFlight, App Store submission | No, once Xcode Cloud is set up | Xcode Cloud |
| Testing background scanning for real | No Mac, but needs your **iPhone** | TestFlight build |

**No Apple Developer membership is required for anything in Milestone 1 or 2.**
Building and running simulator tests needs no account; only signing and
TestFlight distribution do. That is why `ios.yml` passes
`CODE_SIGNING_ALLOWED=NO`.

## Why the Xcode project is generated

`ios/project.yml` is the source of truth. A `.pbxproj` is not reviewable or
editable as text from a Linux container, and merge conflicts in one are
miserable. XcodeGen turns the YAML into a project.

```bash
cd ios && xcodegen generate
```

CI does this on every run, so the generated project is always consistent with the
manifest. It is **not** committed.

One consequence: when Xcode Cloud is set up in M3, a project file must exist
locally at that moment, so the one-time Mac task is `brew install xcodegen`,
`xcodegen generate`, then create the first workflow.

## CI workflows

### `.github/workflows/ci.yml` — Linux, every push

Four jobs, all free:

- **tokinokit** — `swift build` and `swift test` in `swift:6.4.3-noble`.
- **backend** — pytest against a real `pgvector/pgvector:0.8.7-pg16` service
  container, including the migration and adversarial RLS tests.
- **secrets** — `scripts/scan-secrets.sh` over full history.
- **lint** — ruff on the backend, plus a YAML parse of `project.yml` so a
  malformed manifest fails here rather than burning a macOS job.

### `.github/workflows/ios.yml` — macOS

Installs XcodeGen, generates the project, then builds and runs the test bundle
on a simulator.

Runs on every push **while the repository is public**, because standard
GitHub-hosted runners are free for public repos and do not draw down included
compute. If the repo becomes private, included compute is $12/month on GitHub
Free — roughly 193 macOS minutes at $0.062/min — so change the triggers to
`workflow_dispatch` and tags only. The workflow header says this too.

## The plan for Xcode Cloud (Milestone 3)

Xcode Cloud includes **25 compute hours a month** with Apple Developer Program
membership, roughly 8× GitHub's allowance, and handles signing and TestFlight
without any certificate wrangling. Once it is set up it becomes the primary
path for distribution, and `ios.yml` stays as the free pull-request gate.

Setup, once, on your Mac:

```bash
brew install xcodegen
```

```bash
cd ios && xcodegen generate && open Tokino.xcodeproj
```

Then in Xcode: Product → Xcode Cloud → Create Workflow. This also connects the
repository. The App Store Connect API cannot do either step, which is the one
genuine Mac dependency in the project.

## What is not yet verified

**The iOS target has never been compiled.** Nothing in this container can build
for iOS, and no macOS run has happened yet. So as of Milestone 1:

- `TokinoKit` is verified: 86 tests under Swift 6.4.3 on Linux.
- `ios/project.yml` is verified only as well-formed YAML.
- `ios/Tokino/**` and `ios/TokinoTests/**` are **unverified**. The first macOS
  CI run is what will prove, or disprove, that they compile.

This is exactly why the iOS target exists in Milestone 1 rather than Milestone 2:
free macOS CI means SwiftUI gets compiled from its first line instead of
accumulating unverified for weeks.

Background scanning cannot be verified in the simulator at all — background
tasks do not run there. That waits for a TestFlight build on your iPhone in M3.
