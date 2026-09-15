# Releasing

The goal is that shipping a release is: update the changelog, tag, push.

```bash
git tag v0.1.0
git push origin v0.1.0
```

That triggers `.github/workflows/release.yml`, which tests, archives, signs, notarises, staples,
builds the DMG, signs the Sparkle appcast, and publishes a GitHub Release.

Getting to that point takes some one-time setup.

## One-time setup

### 1. Developer ID certificate

You need a **Developer ID Application** certificate (not "Apple Development"), from an Apple
Developer Program membership.

Export it from Keychain Access as a `.p12` with a password, then:

```bash
base64 -i DeveloperID.p12 | pbcopy
```

Store as repository secrets:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE` | The base64 from above |
| `MACOS_CERTIFICATE_PASSWORD` | The `.p12` password |
| `SIGNING_IDENTITY` | e.g. `Developer ID Application: Example Ltd (ABCDE12345)` |
| `DEVELOPMENT_TEAM` | The 10-character team ID |

Find the identity string with:

```bash
security find-identity -v -p codesigning
```

### 2. App Store Connect API key (for notarization)

An API key is used rather than an Apple ID and app-specific password: it is scoped, revocable, and
does not put an account password into CI.

Create one at App Store Connect ▸ Users and Access ▸ Integrations, with the **Developer** role.
Download the `.p8` — it can only be downloaded once.

```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

| Secret | Value |
|---|---|
| `AC_API_KEY` | The base64 `.p8` |
| `AC_API_KEY_ID` | The key ID |
| `AC_API_ISSUER_ID` | The issuer UUID |

### 3. Sparkle signing key

This is the key that proves an update came from you. **Losing it means no existing installation can
ever be updated again.** Generate it once, on a trusted machine, and back it up somewhere durable.

```bash
xcodebuild -resolvePackageDependencies -project AbleKit.xcodeproj -clonedSourcePackagesDirPath .build/spm
./scripts/generate-keys.sh
```

Then:

1. Put the **public** key into `Configs/Info.plist` as `SUPublicEDKey` and commit it.
   Until that is set, AbleKit refuses every update — the correct default, not a bug.
2. Store the **private** key as the `SPARKLE_PRIVATE_KEY` secret:
   ```bash
   ./scripts/generate-keys.sh --export
   ```

Sparkle's current key format is the base64 of a 32-byte seed. The scripts pass it to `sign_update`
in a temporary file rather than on the command line, because arguments are visible to every process
on the machine through `ps`.

### 4. Runner image

The workflows default to `macos-26`, which is needed for the Foundation Models SDK. If a different
image or a self-hosted runner is required, set the repository **variable** `MACOS_RUNNER`.

## Cutting a release

1. Add a section to `CHANGELOG.md` headed `## [x.y.z]`. The workflow extracts it for the release
   notes and for the Sparkle update dialog, so write it for users.
2. Commit.
3. Tag `vx.y.z` and push.

The version comes from the tag. The build number is the commit count, which guarantees it increases
— Sparkle will not offer an update whose build number has not gone up.

## Testing the pipeline without publishing

Run the workflow manually with **dry run** checked. It builds, signs and notarises, uploads the DMG
and appcast as workflow artifacts, and publishes nothing.

## Doing it by hand

```bash
xcodebuild archive -project AbleKit.xcodeproj -scheme AbleKit -configuration Release \
  -destination 'generic/platform=macOS' -archivePath build/AbleKit.xcarchive \
  MARKETING_VERSION=0.1.0 CURRENT_PROJECT_VERSION=1

xcodebuild -exportArchive -archivePath build/AbleKit.xcarchive \
  -exportPath build/export -exportOptionsPlist Configs/ExportOptions.plist

export SIGNING_IDENTITY="Developer ID Application: ... (TEAMID)"
export AC_API_KEY_PATH=~/private_keys/AuthKey_XXXX.p8
export AC_API_KEY_ID=XXXXXXXXXX
export AC_API_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

./scripts/sign-and-notarize.sh build/export/AbleKit.app Configs/AbleKit.entitlements
./scripts/build-dmg.sh build/export/AbleKit.app 0.1.0 dist
./scripts/sign-and-notarize.sh dist/AbleKit-0.1.0.dmg

export SPARKLE_PRIVATE_KEY="..."
./scripts/generate-appcast.sh dist/AbleKit-0.1.0.dmg 0.1.0 1 notes.txt dist/appcast.xml
```

## Verifying a release

```bash
# Signed, notarised, and accepted by Gatekeeper
codesign --verify --deep --strict --verbose=2 /Applications/AbleKit.app
spctl --assess --type execute --verbose /Applications/AbleKit.app
xcrun stapler validate /Applications/AbleKit.app
```

`spctl` should say `accepted` and `source=Notarized Developer ID`.

## Things that go wrong

| Symptom | Cause |
|---|---|
| `errSecInternalComponent` while signing | The keychain is locked, or `set-key-partition-list` was not run |
| Notarization rejects nested code | Sparkle's framework was not signed before the outer bundle. `sign-and-notarize.sh` signs inside-out for this reason |
| "damaged and can't be opened" | Not notarised, or the ticket was not stapled |
| No update offered | The build number did not increase, or `SUPublicEDKey` is empty |
| `sign_update` rejects the key | Wrong format — it wants the base64 of a 32-byte seed |
