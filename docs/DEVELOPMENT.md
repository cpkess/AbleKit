# Development

## Requirements

- Apple Silicon Mac, macOS 26 or later
- Xcode 26 or later

## Getting started

```bash
git clone https://github.com/cpkess/AbleKit.git
cd AbleKit
make run
```

`make run` builds, installs to `/Applications`, and launches. Installing rather than running from
the build directory is deliberate: a stable path and a stable signature are what let a permission
you grant once keep applying.

Run `make` on its own for everything else. The targets worth knowing:

| | |
|---|---|
| `make run` / `make restart` | Build, install, launch |
| `make logs` | Stream AbleKit's own log output |
| `make status` | Signing, install state, update configuration — start here when something is odd |
| `make test` | Core logic. Fast, no permissions, no app host |
| `make test-live` | Also exercise the real Apple Intelligence model |
| `make reset-permissions` | Clear AbleKit's TCC grants and start over |
| `make dmg` | A signed, installable disk image |

Xcode still works normally (`open AbleKit.xcodeproj`) if you want a debugger or the view hierarchy
inspector — the project is a normal one, not generated.

## Where things live

```
AbleKitCore/Sources/AbleKitCore/
  Shared/         Geometry — the one place coordinates are converted
  Actions/        DesktopAction, validation, mouse and keyboard controllers
  Context/        DesktopContext, the Accessibility snapshot, the collector
  Intelligence/   IntelligenceProvider, prompt building, the Apple Intelligence provider
  Agent/          AgentSession, the router, the verifier, loop detection
  Capabilities/   Native, Accessibility, Visual, Bridges
  Safety/         Classification, policy, permissions
  Skills/         Model, runner, store

AbleKit/
  App/            Entry point, delegate, state, settings, shortcut
  UI/             Palette, HUD, onboarding, settings, overlay, debug panel
  Updates/        Sparkle

Configs/          Info.plist, entitlements, export options
scripts/          DMG, signing, notarization, Sparkle keys and appcast
```

## Adding a source file

The app target uses a folder-synchronized group, so **a new file in `AbleKit/` is picked up
automatically** — `project.pbxproj` never needs editing. The same is true of the package.

## Working on the agent without a desktop

The most useful thing in the test suite is the set of simulated runs in `AgentSessionTests`. They
drive the whole loop with a scripted planner and a scripted desktop, so every termination path —
step limit, repeated action, frozen screen, declined confirmation, blocked action, unanswered
question — is exercised without a mouse moving.

The test doubles are in `TestDoubles.swift`:

| Double | Stands in for |
|---|---|
| `ScriptedIntelligence` | The planner. Returns a fixed sequence, or a closure for endless distinct steps |
| `ScriptedCollector` | The desktop. Varies its state by default, because a frozen screen legitimately reads as failure |
| `RecordingCapability` | Anything that touches the machine. Records instead of doing |
| `ScriptedUser` | Someone answering confirmations |

A note worth knowing: `ScriptedCollector` returns a slightly different window title each time unless
you pass `varying: false`. That is not a quirk — `Verifier` treats an entirely unchanged screen as
evidence that an action did nothing, so a double that returned a frozen desktop would make every
step fail verification. Opt into `varying: false` only in tests that are actually about being stuck.

## Permissions while developing

TCC identifies an app by its **designated requirement**. For a real signing identity that is
bundle id plus certificate, which does not change when you rebuild. For an *ad-hoc* signed app it
is the code-directory hash, which changes on every single build — so every rebuild looks like a
brand new application, the grant you just made belongs to the previous binary, and System Settings
quietly fills up with identical "AbleKit" entries that all point at dead code.

The project is therefore configured for automatic signing:

```
CODE_SIGN_STYLE  = Automatic
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = WZJ4ZPRH72
```

**Working on a different team?** Change `DEVELOPMENT_TEAM` in the target's build settings, or pass
`DEVELOPMENT_TEAM=YOURTEAM` to `xcodebuild`. Any Apple Development certificate will do — the point
is only that it is stable. CI passes `CODE_SIGNING_ALLOWED=NO` and is unaffected.

If permissions ever get into a confused state, clear AbleKit's own entries and grant once more:

```bash
tccutil reset Accessibility com.ablekit.AbleKit
tccutil reset ScreenCapture com.ablekit.AbleKit
```

**Screen Recording needs a relaunch.** `CGPreflightScreenCaptureAccess()` is resolved once per
process, so a running app keeps being refused after you allow it. Onboarding says so and offers a
Relaunch button rather than leaving you clicking Re-check. Accessibility takes effect immediately.

The app tells you rather than failing quietly: a missing permission surfaces in the palette and in
onboarding.

## The developer tools

Turn on Settings ▸ Automation ▸ "Show what AbleKit is working from". That does two things.

**In the task HUD**, a panel appears showing the context, the chosen capability, any refinement the
router applied, the verification result and timings. Computer-use behaviour is close to
undebuggable from the outside — when an agent does something unexpected, the question is always
*what did it think it was looking at?* This answers it.

**A Developer tab appears in Settings**, with two tools that do not require running a task:

- *Capture Context* reads the frontmost app through the same collector the agent uses, so what it
  shows cannot disagree with what the planner would have been given. Every control is listed with
  its id, role, label, frame and available Accessibility actions.
- *Highlight* and *Press* run a single action through the real pipeline — validation, safety policy,
  routing, execution — and show the resulting report. It is not a shortcut around `Executor`; a
  tester that bypassed the safety gate would be testing something other than what AbleKit does.

This is the fastest way to find out whether a permission is really granted, whether an app exposes
anything to Accessibility, and whether the coordinate math is landing where you expect. Note that
capture waits a moment first, so that the Settings window is not itself the app being inspected.

## Style

- Swift 6 language mode, strict concurrency, zero warnings.
- Design services behind protocols so they can be substituted in tests.
- Never fake an Apple API that does not exist. If something cannot be done because of an SDK,
  entitlement or platform limit, keep the abstraction, document the limitation, and build
  everything around it that does work.
- Inspect the SDK when unsure:
  ```bash
  SDK=$(xcrun --sdk macosx --show-sdk-path)
  grep -n "SystemLanguageModel" "$SDK/System/Library/Frameworks/FoundationModels.framework/Versions/A/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface"
  ```

## Tests

```bash
swift test --package-path AbleKitCore
swift test --package-path AbleKitCore --filter GeometryTests
```

Coverage worth maintaining: the agent state machine, capability selection and refinement, action
validation, the safety policy, retries and cancellation, loop detection, coordinate conversion, the
Copilot bridge's state transitions, and verification logic.
