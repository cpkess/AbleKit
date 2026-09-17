# Privacy

AbleKit can see your screen and operate your applications. That is a lot of trust to ask for, so
this document is specific about what happens to what it sees.

## The short version

- Reasoning runs **on your Mac**, using Apple Intelligence.
- Screenshots are held in memory for the step that needs them and are **never written to disk**.
- There is **no AbleKit account, no AbleKit server, and no telemetry**.
- Nothing is sent to another application unless you approve the exact text first.

## What AbleKit reads

Only when a task is running, and only what that step needs:

| | When |
|---|---|
| Frontmost application and window title | Every step |
| The Accessibility tree of the frontmost app | Every step |
| Selected text and clipboard contents | When user content is requested |
| A screenshot, and text recognised in it | **Only** when the app exposes no usable Accessibility information |
| Selected Finder paths | Only in Finder, and only where the app publishes them |

Screen capture is not the default path. AbleKit collects semantic context first and escalates to
capturing the screen only when that comes back empty — which is why the macOS recording indicator
stays dark for most of a task. That is not a promise about behaviour; it is what the code does, in
`AgentSession.collectContext()`.

## What AbleKit keeps

| | Kept? |
|---|---|
| Screenshots | No. Memory only, for the duration of one step |
| Accessibility snapshots | No. Memory only |
| Clipboard and selected text | No. Memory only |
| Step history for the running task | In memory; discarded when the task ends |
| Your recent goals | Yes — the text you typed, so the palette can suggest it. Clearable in Settings |
| Skills you save | Yes — readable JSON in Application Support |
| Preferences | Yes — `UserDefaults` |

Nothing in that list leaves your Mac.

## What leaves your Mac

One thing, and only when you approve it: **an AI bridge handoff**.

When a task asks Copilot something, AbleKit:

1. Extracts the relevant information **locally** — it does not send a screenshot.
2. Builds the prompt, with any screen context clearly labelled.
3. **Shows you the full text** and waits.
4. Sends it only if you agree, by typing it into the Copilot window you are already signed into.

The policy classifies every bridge call as consequential, so this confirmation is not something you
can accidentally skip. Consent to a handoff you have not read is not consent.

What happens to that text afterwards is governed by Microsoft's terms and your organisation's
policy, not by AbleKit.

## What AbleKit will not do

- Type into password or secure-text fields. Refused outright, not merely confirmed.
- Enter credentials, card numbers or other sensitive identifiers.
- Bypass application permissions, macOS security, enterprise authentication or corporate policy.
  AbleKit operates your already-authorised session; it has no access you do not already have.

## Logging

AbleKit always writes a little to the system log: that a task started and finished, how many steps
it took, which kind of action each step was, and whether it worked. None of that describes your
screen or what you asked for.

**Diagnostic Logging** (off by default) adds the goal you typed, the names of the controls AbleKit
acted on, and the reasons steps failed — which is what makes a problem diagnosable. Even then, text
AbleKit types or sends to another application is recorded only as a character count, and
screenshots, screen text and clipboard contents are never logged.

## Permissions

Both are granted by you in System Settings and revocable at any time.

- **Accessibility** — read controls by name and operate them.
- **Screen Recording** — see apps that expose nothing readable.

AbleKit degrades rather than failing silently: without Screen Recording it works from Accessibility
alone; without Accessibility it can open apps and files but cannot operate an interface, and it
says so.
