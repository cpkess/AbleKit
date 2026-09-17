# Changelog

All notable changes to AbleKit are recorded here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- The menu bar menu did nothing: Ask AbleKit, Settings and Setup all silently failed. Settings
  and Setup now open reliably, and Setup can be reopened at any time from the menu.
- Finished tasks no longer keep going. Asked to open an app, AbleKit opened it and then tried to
  open it again until it gave up and reported a failure. It now stops once the goal is done.
- An app referred to by an old name (such as "System Preferences") is no longer mistaken for the
  wrong app after it opens.

### Changed

- Permissions granted to one AbleKit build now carry over to later ones.

## [0.1.0]

The first foundation release. The goal of 0.1 is to prove the architecture, not to be broadly
capable — reliability over breadth.

### Added

- **Agent loop** — single-step planning against live context, with routing, validation, a safety
  gate, execution and verification on every step.
- **Capability tiers** — native macOS APIs, Accessibility, and visual interaction, chosen
  automatically in that order of preference. A planned click on a control that advertises `AXPress`
  is upgraded to an Accessibility press; a planned coordinate is upgraded to the innermost control
  underneath it.
- **Apple Intelligence** — on-device reasoning behind an `IntelligenceProvider` protocol, using
  guided generation so the planner returns typed steps rather than prose.
- **Verification** — deterministic checks first, the model only for the ambiguous remainder. A
  check that cannot be made reports "inconclusive" and never a false success.
- **Safety** — actions classified routine, consequential or restricted. Consequential steps pause
  for confirmation immediately before they happen; AbleKit does not type into password fields.
- **Limits** — steps, wall-clock time, consecutive failures, repeated actions and frozen screens all
  end a task.
- **Copilot bridge** — asks Microsoft Copilot through its own interface and brings the answer back
  for later steps to act on. Only text is sent, and the exact text is shown before it leaves.
- **Skills** — saved, parameterised procedures expressed as intentions rather than recorded
  coordinates, stored as readable JSON.
- **Interface** — menu-bar utility with a recordable global shortcut, a Spotlight-style palette
  that collects a Skill's parameters before running it, a task HUD with Pause and Stop always
  available, a target overlay, and permission onboarding.
- **Developer panel** — the context, capability, refinement and verification behind each step.
- **Distribution** — Sparkle updates with EdDSA verification, a signed and notarised DMG, and a
  tag-triggered GitHub Actions release pipeline.
- **Terminal workflow** — a Makefile covering the whole lifecycle, so Xcode is never required:
  `make run` builds, installs and launches; `make release` produces a signed, notarised DMG and a
  signed update feed; `make status` reports what is configured and what is not.

### Known limitations

- The Copilot bridge has not been exercised against an installed Microsoft Copilot; its interface
  heuristics are tested against scripted interfaces only.
- Copilot's research mode may not be drivable through the interface. AbleKit keeps the abstraction
  and reports honestly when it has fallen back to a standard answer.
- Finder selection paths are read through Accessibility, so they are only available in applications
  that publish `AXURL`. AbleKit does not request Apple Events permission for this.

[Unreleased]: https://github.com/cpkess/AbleKit/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/cpkess/AbleKit/releases/tag/v0.1.0
