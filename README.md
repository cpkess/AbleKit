# AbleKit

A small, native macOS agent that can see what is on your screen and operate applications for you.

AbleKit exists for the software that AI cannot otherwise reach: the internal tool with no API, the
enterprise client that will never have an integration, the application whose information is visible
to you and to nothing else. If you can do it on your Mac, the goal is that you can teach AbleKit to
do it for you.

> **Status: early.** Version 0.1 is a foundation, not a finished product. The architecture is in
> place and tested; the range of tasks it completes reliably is still narrow. See
> [What actually works](#what-actually-works) for an honest account.

## What it is

AbleKit is a menu-bar utility. You press a shortcut, type what you want, and watch it work — with
Pause and Stop always within reach.

It is built around one idea: **prefer the most deterministic way to do a thing.**

```
Native macOS APIs      Opening an app is one system call, not a screenshot and a click.
        ↓
Accessibility          Press the button named "Save", not the pixel at (673, 482).
        ↓
Visual interaction     Only when an interface exposes nothing to work with.
```

Most desktop agents are a loop of *screenshot → model → coordinate → click*. AbleKit treats that as
the last resort rather than the whole design, because it is the least reliable option available and
the hardest to verify afterwards.

## Bridging AI systems

AbleKit is not trying to replace a system like Microsoft Copilot. It is trying to be the hands and
eyes around one.

```
Application A  →  AbleKit  →  Copilot  →  AbleKit  →  Application B
```

You can ask AbleKit to read something on screen, have Copilot reason about it with context AbleKit
does not have, and then act on the answer in a different application. AbleKit drives Copilot through
the interface you are already signed into — it assumes no enterprise API, and it bypasses nothing
you are not already permitted to do.

Before anything is sent, AbleKit shows you the exact text and waits for you to agree.

## Requirements

- Apple Silicon Mac
- macOS 26 or later
- Apple Intelligence enabled (all reasoning happens on your Mac)
- Xcode 26 or later to build from source

## Installing

Download `AbleKit-x.y.z.dmg` from [Releases](https://github.com/cpkess/AbleKit/releases), open it,
and drag AbleKit to Applications. Builds are signed and notarised, and update themselves through
Sparkle with cryptographic verification.

On first launch AbleKit asks for two permissions and explains what each one buys:

| Permission | Why | Without it |
|---|---|---|
| **Accessibility** | Read controls by name and operate them directly | AbleKit can open apps and files, but cannot operate any interface |
| **Screen Recording** | See apps that expose nothing readable | AbleKit works from Accessibility information alone |

## Privacy

- Reasoning runs on your Mac, using Apple Intelligence.
- Screenshots are analysed in memory and **never written to disk**.
- There is no AbleKit account, no AbleKit server, and no telemetry.
- Task history lives in memory and disappears when the task ends.
- Nothing is sent to another application unless you approve the exact text first.

See [docs/PRIVACY.md](docs/PRIVACY.md).

## What actually works

Honest scope for 0.1:

**Works and is covered by tests**
- The agent loop: observe, plan one step, route it, check it, execute, verify, repeat
- Choosing between native, Accessibility and visual capabilities, including upgrading a planned
  click into an Accessibility press when the control supports one
- Safety classification, confirmation before consequential steps, and refusal of credential entry
- Bounded execution: step, time, repetition, failure and frozen-screen limits
- Pause, resume and immediate stop
- Coordinate conversion across Retina and multi-display arrangements
- Skills: saved, parameterised procedures stored as readable JSON
- The Copilot bridge's conversation logic, including detecting when a streaming answer has settled

**Built, but not yet proven against the real thing**
- The Copilot bridge has not been run against an installed Microsoft Copilot. Its interface
  heuristics are tested against scripted interfaces only. Expect to adjust
  `CopilotInterfaceReader` for the build in front of you.
- Copilot's deeper research mode is abstracted but may not be drivable; AbleKit reports when it
  falls back rather than passing off a standard answer as a researched one.

**Not in 0.1**
- Learning a Skill by demonstration ("watch me do this")
- Unattended long-running automation
- Anything other than macOS

## Building

```bash
git clone https://github.com/cpkess/AbleKit.git
cd AbleKit
swift test --package-path AbleKitCore     # the core logic, no permissions needed
open AbleKit.xcodeproj                    # then Run
```

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Documentation

| | |
|---|---|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the pieces fit, and why they are arranged this way |
| [DEVELOPMENT.md](docs/DEVELOPMENT.md) | Building, testing, and where things live |
| [PRIVACY.md](docs/PRIVACY.md) | What AbleKit collects, keeps and sends |
| [SECURITY.md](docs/SECURITY.md) | Threat model and reporting |
| [RELEASING.md](docs/RELEASING.md) | Signing, notarising and shipping |

## Licence

MIT. See [LICENSE](LICENSE).
