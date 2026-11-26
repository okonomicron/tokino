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

## Verification status

As of Milestone 1, on run 3 of the iOS workflow:

- `TokinoKit`: **verified.** 89 tests under Swift 6.4.3 on Linux, locally and in CI.
- `ios/project.yml`: **verified.** XcodeGen 2.48.0 generates the project.
- `ios/Tokino/**` and `ios/TokinoTests/**`: **verified.** Compiled for
  `arm64-apple-ios-simulator`, linked against TokinoKit, and all 5 XCTest cases
  passed on an iOS 26 simulator. Build and test took 3m07s.

Getting here took three runs, and the two failures were worth having:

1. TokinoKit declared `platforms: [.iOS(.v26)]` and tools version 6.2, which
   forced the whole package to need Xcode 26 and failed against the runner's
   default Xcode 16.4.
2. A hardcoded `iPhone 17` destination, now replaced by discovery.

Both were wrong assumptions about an environment this container cannot inspect,
which is the argument for compiling early rather than accumulating unverified
SwiftUI for weeks.

**Still unverifiable here:** background scanning. Background tasks do not run in
the simulator at all, so `BGContinuedProcessingTask` behaviour waits for a
TestFlight build on a real iPhone in M3.
