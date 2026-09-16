# Releasing

Everything is driven from the terminal. Xcode is never required.

```bash
make release VERSION=0.1.0    # build, sign, notarise, and sign the update feed
make publish VERSION=0.1.0    # tag it and put it on GitHub Releases
```

That is the whole routine, once the one-time setup below is done. `make status` will tell you at
any point which parts are configured and which are not.

## What a release actually is

Two files, both attached to a GitHub Release:

| File | Purpose |
|---|---|
| `AbleKit-x.y.z.dmg` | What a person downloads, drags to Applications, and opens |
| `appcast.xml` | What an already-installed copy reads to discover the update |

AbleKit's feed URL is `releases/latest/download/appcast.xml`, so **publishing the release is what
ships the update**. There is no update server to deploy and nothing else to push.

## One-time setup

### 1. Update signing key

This proves an update came from you. Sparkle verifies it before unpacking anything, which is what
stops a compromised release host from shipping arbitrary code to every installation.

```bash
make sparkle-keys
```

The private key goes into your login keychain; the public key is written into `Configs/Info.plist`
for you. Commit that file — until the key ships inside a build, AbleKit refuses every update, which
is the correct default rather than a bug.

**Back it up now.** Losing this key means no existing installation can ever be updated again.

```bash
scripts/generate-keys.sh --export   # writes sparkle-private-key.txt, mode 600
```

Store it somewhere durable, and as the `SPARKLE_PRIVATE_KEY` repository secret if you want releases
to run on CI. Then delete the file.

### 2. Developer ID certificate

You need a **Developer ID Application** certificate — "Apple Development" cannot notarise. Check
what you have:

```bash
security find-identity -v -p codesigning
```

`make dmg` uses the first Developer ID it finds; override with `RELEASE_IDENTITY=...` if you have
more than one.

### 3. Notarization credentials

Without notarization, Gatekeeper refuses to open the app on any Mac that has never seen it — and
tells the user it is *damaged*, which reads as "this is malware" rather than "this is unsigned".

Create an App Store Connect API key (App Store Connect ▸ Users and Access ▸ Integrations, with the
**Developer** role) and download the `.p8`. It can only be downloaded once.

Then store it, once:

```bash
xcrun notarytool store-credentials AbleKit \
  --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 \
  --key-id XXXXXXXXXX \
  --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

`make notarize` finds that profile automatically. Nothing else needs configuring.

## Cutting a release

1. Add a section to `CHANGELOG.md` headed `## [x.y.z]`. It becomes the GitHub release notes *and*
   the text shown in the update dialog, so write it for users.
2. Commit.
3. ```bash
   make release VERSION=x.y.z
   make publish VERSION=x.y.z
   ```

`publish` refuses to upload a DMG that is not notarised and stapled, because publishing one would
tell everyone who downloads it that the app is damaged.

The build number is the commit count, so it always increases — Sparkle will not offer an update
whose build number has not gone up.

## Doing it in pieces

```bash
make release-build VERSION=0.1.0   # Release build, Developer ID signed
make dmg VERSION=0.1.0             # + disk image, signed
make notarize VERSION=0.1.0        # + notarised and stapled
make appcast VERSION=0.1.0         # + signed update feed
```

## Releasing from CI instead

`.github/workflows/release.yml` does the same thing on a `v*.*.*` tag, using the same scripts. It
needs these repository secrets: `SIGNING_IDENTITY`, `MACOS_CERTIFICATE`,
`MACOS_CERTIFICATE_PASSWORD`, `DEVELOPMENT_TEAM`, `AC_API_KEY`, `AC_API_KEY_ID`, `AC_API_ISSUER_ID`,
`SPARKLE_PRIVATE_KEY`. It checks they are all present before starting the build rather than failing
at notarization twenty minutes in.

Run it manually with **dry run** checked to exercise the whole pipeline without publishing.

## Verifying what you shipped

```bash
spctl --assess --type execute --verbose /Applications/AbleKit.app
xcrun stapler validate dist/AbleKit-0.1.0.dmg
```

`spctl` should say `accepted` and `source=Notarized Developer ID`.

To confirm the update feed is signed with the key that actually ships in the app:

```bash
make status
```

## Things that go wrong

| Symptom | Cause |
|---|---|
| "damaged and can't be opened" | Not notarised, or the ticket was not stapled |
| Notarization rejects nested code | Something inside `Frameworks/` was signed after the bundle. `sign-app.sh` signs inside-out for exactly this reason |
| `errSecInternalComponent` while signing | The keychain is locked |
| No update offered | The build number did not increase, or `SUPublicEDKey` is empty |
| `sign_update` cannot find a key | `make sparkle-keys` has not been run on this machine |
| Permissions forgotten after every build | The app was ad-hoc signed. `make status` reports this |
