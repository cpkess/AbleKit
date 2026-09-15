# Architecture

## The shape of the thing

AbleKit is two pieces:

- **`AbleKitCore`** — a local Swift package holding everything that can be reasoned about and
  tested: the agent loop, the capabilities, the safety policy, the coordinate math, the Copilot
  bridge. It builds and tests with no app host, no window server and no permissions, which is why
  the test suite runs in under a second on a CI box.
- **`AbleKit`** — a thin Xcode app target: the menu bar, the palette, the HUD, onboarding, and the
  Sparkle updater.

The split is not ceremony. An agent that operates someone's desktop needs a test suite that can
exercise its failure paths — every limit, every refusal, every cancellation — without touching a
real mouse. Putting the logic in a package is what makes that possible.

## The loop

```
   User goal
       │
       ▼
  Collect context ──────────── semantic first; capture the screen only if that comes back empty
       │
       ▼
  Plan one step ────────────── guided generation, so the result is a typed action, not prose
       │
       ▼
  Route ────────────────────── choose the capability, and refine the action if a better one exists
       │
       ▼
  Validate ─────────────────── is this still true of the machine as it is now?
       │
       ▼
  Safety policy ────────────── allow, ask the user, or refuse
       │
       ▼
  Execute
       │
       ▼
  Observe and verify ───────── deterministically where possible
       │
       └──────────────────────► repeat, or finish
```

One step at a time, deliberately. A longer plan is mostly fiction by its third entry: the desktop
changes after every action, including in ways nobody predicted.

## Why the tiers are ordered

`CapabilityKind` is `Comparable`, and `CapabilityRouter` always picks the earliest tier that can do
the job.

| Tier | What it is | Why it is preferred |
|---|---|---|
| `native` | `NSWorkspace`, `FileManager`, URL handling | No interface is driven at all, so there is nothing to misidentify |
| `accessibility` | `AXPress` on a named control | Survives the window moving or the layout reflowing |
| `visual` | Synthetic input at a position | Works on anything, verifies nothing by itself |
| `bridge` | Another AI application | Reaches knowledge the desktop does not contain |
| `user` / `control` | Questions, waits, bookkeeping | Not desktop actions |

The interesting part is that the router **refines** before it routes. A planned
`click(element)` where the element advertises `AXPress` becomes `accessibilityAction(element,
"AXPress")`. A planned `click(point)` becomes a press on the innermost interactive control under
that point. This happens in one tested place, so the improvement applies regardless of which model
proposed the action — the preference is a property of the system, not a habit of the prompt.

## Coordinates

There is exactly one canonical space: **global, top-left origin, points**. It matches what `CGEvent`
and the Accessibility APIs use, which are the two systems that actually receive AbleKit's actions.

Three other spaces exist at the edges, and every conversion lives in `Geometry.swift`:

- **AppKit** — bottom-left origin. Used by `NSScreen` and `NSWindow`, so the overlay converts.
- **Capture pixels** — a captured image is some region of the screen at some pixel size;
  `CaptureGeometry` maps between them.
- **Vision normalized** — `0...1`, bottom-left origin. Scaled into the region and flipped.

Coordinate bugs are the most common cause of silent misclicks, and they are only debuggable if the
arithmetic happens in one place. That file has the densest tests in the project.

## Intelligence stays behind a protocol

Only `AppleIntelligenceProvider.swift` imports `FoundationModels`. Everything else sees
`PlannedStep` and `VerificationResult`.

The planner returns a `@Generable` struct, so the *shape* of a step is enforced by the schema rather
than parsed out of prose. It can still be *wrong* — an element id that has scrolled away, a key name
that means nothing — which is what `PlannedStepDecoder` is for: it turns each such mistake into a
sentence that can be fed back into the next planning turn, so a bad step costs one retry instead of
a misclick.

`LanguageModelSession.GenerationError` is used rather than the newer `LanguageModelError` so the
project still compiles against the macOS 26 SDK, which is AbleKit's deployment target.

## Verification is a ladder

"Never assume an action succeeded" and "prefer deterministic automation over AI" meet here:

1. **Ask the system.** After activating an app, either it is frontmost or it is not. No model needed.
2. **Ask the screen.** If nothing observable changed at all, that is strong evidence on its own —
   except for scrolling, which legitimately changes nothing at the end of a view.
3. **Ask the model**, for the genuinely ambiguous remainder.

Most steps are settled at rung one, which makes verification nearly free and, more importantly,
correct. A check that cannot be made returns `inconclusive` — a real answer, not a hedge.

## Safety

Every proposed action passes through `ActionPolicy`, and `Executor` is the only thing that calls a
capability. The gate is narrow on purpose: "AbleKit did not send that email on its own" should be a
property of the architecture, not of careful coding.

Classification looks at what an action does *and what it does it to*. Pressing a button is routine;
pressing one labelled "Delete Account" is not. Because AbleKit prefers semantic targets, the label
is usually available — a second, quieter argument for the Accessibility-first design.

Matching is whole-word, so "Send" is caught and "Resend" is not, and the detector is deliberately
conservative: a false confirmation costs one keystroke, a false go-ahead can cost an unsendable
email.

## The Copilot bridge

```
AbleKit  →  CopilotBridge  →  CopilotSurface  →  Copilot's own window
```

`CopilotSurface` is a protocol, which is what lets the hard part be tested on a machine with no
Copilot installed. The hard part is not typing — it is knowing **when an answer has finished**.
Chat interfaces give no reliable completion signal, so `ResponseStabilityDetector` watches for the
text to stop changing while the interface is not busy, and separates "still arriving" from "settled"
from "never started".

The reply also has to be told apart from the conversation that was already on screen. A clean prefix
match is the reliable case; when the transcript has reflowed, the whole text is returned rather than
guessing at a boundary and truncating the answer.

### Research mode

`CopilotMode` exists from the start because Copilot's deeper research mode is a different
interaction with the same surface, not a different bridge. Whether it can be driven depends on the
build in front of you. If the affordance is not found, `BridgeResult.modeFallbackReason` says so and
the answer is reported as standard — an answer the user believes was researched, but was not, is
worse than no answer.

### What is sent

Only text, never a screenshot. Desktop information is extracted locally, labelled, and shown to the
user in full before it leaves. The policy classes any bridge call as consequential, so the
confirmation is not optional.

## Skills

A Skill is a list of **intentions**, not recorded events:

```
Open the tracker and find {programme}
Put it into edit mode
Update the status field
Save                             (done when: the entry is no longer in edit mode)
```

Replaying `click(673, 482)` against next quarter's layout produces a confident, wrong click. An
intention is re-planned against whatever is actually on screen today, which is the entire point.

`SkillRunner` renders a Skill into a goal; the agent loop is otherwise unchanged. Storage is one
JSON file per Skill in Application Support — few, small, user-owned, and portable between Macs
without a database or a daemon.

## Limits

An agent that cannot stop itself is not something to leave running on someone's Mac. Every one of
these ends a task:

| Limit | Catches |
|---|---|
| Step count | A task that is going nowhere slowly |
| Wall clock | A task that is going nowhere quickly |
| Consecutive failures | A plan that cannot work |
| Repeated actions | A planner that cannot see its last attempt failed |
| Repeated screen states | Actions that report success but change nothing |

Loop detection collapses element targets to their *label and role* rather than their snapshot id,
because ids are regenerated on every snapshot — without that, clicking the same button five times
would look like five different actions.

## Pause and stop

Checked between every phase and inside waits, which are stepped in 50ms slices so "Stop" means now.

A step already in flight is allowed to finish and be recorded: a dispatched click cannot be
recalled, and a history that omitted it would misrepresent what happened. What pausing guarantees is
that no *further* step begins.
