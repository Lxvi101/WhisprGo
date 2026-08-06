# WhisprGo agent instructions

These instructions are repository-specific and are mandatory for release work. Keep this file current whenever signing, notarization, Sparkle, packaging, or GitHub release behavior changes.

## Project and release identity

- App: native macOS SwiftUI menu-bar app built with Swift Package Manager.
- Deployment target: macOS 14 or newer; practical runtime target is Apple silicon.
- GitHub repository: `Lxvi101/WhisprGo`.
- Release branch/feed branch: `main`.
- Bundle identifier: `com.whisprgo.app`.
- Developer ID identity: `Developer ID Application: Levi Dan Berger (59UPSTU6WZ)`.
- Apple Team ID: `59UPSTU6WZ`.
- `notarytool` Keychain profile: `WhisprGo-notary`.
- Sparkle Keychain account: `com.whisprgo.app`.
- Sparkle feed: `https://raw.githubusercontent.com/Lxvi101/WhisprGo/main/appcast.xml`.
- Sparkle public EdDSA key: `68FIbJ2UCSDf2KmLOI+dMWlBoHr12pgvSxu9nipLRzg=`.

The Developer ID private key, notarization credentials, Sparkle private key, GitHub token, Apple ID, and certificate-export password must remain in macOS Keychain or the user's credential store. Never print, export, commit, or request these secrets. The public Sparkle key is intentionally committed in `Packaging/Info.plist`.

## Required release security

Published builds must use Developer ID signing, Hardened Runtime, Apple notarization, stapling, Sparkle archive signing, and a signed Sparkle feed. Never publish an ad-hoc-signed build.

`Packaging/WhisprGo.entitlements` is mandatory and must contain:

```xml
<key>com.apple.security.device.audio-input</key>
<true/>
```

Apple's Hardened Runtime blocks microphone/Core Audio input without that entitlement even when `NSMicrophoneUsageDescription` exists. Apply the entitlement to the main WhisprGo app only. Do not apply it to Sparkle's nested helpers. Sign nested Sparkle code from the inside out and never use `codesign --deep` for signing; `--deep` is acceptable for verification.

Accessibility/global hotkeys and text insertion rely on the user's Accessibility consent and do not require a distributable app entitlement. Do not add Apple Events automation, App Sandbox, JIT, or library-validation exceptions unless code is added that demonstrably requires them.

The 1.2.0 release was the first Developer ID bridge and omitted Audio Input; 1.2.1 repairs that mistake. Macs upgrading from older ad-hoc builds can have stale Microphone or Accessibility TCC records whose old code requirement no longer matches the stable Developer ID requirement. That is a one-time migration issue: ask the user to disable/re-enable WhisprGo in the relevant Privacy & Security pane, or obtain explicit approval before using `tccutil reset`. Never silently reset privacy consent. Future Developer ID-signed updates keep the same designated requirement.

## Preflight before every release

Start from a clean `main` synchronized with `origin/main`. Inspect all changes and do not stage unrelated user work.

Confirm local credentials without revealing them:

```sh
security find-identity -v -p codesigning
xcrun notarytool history --keychain-profile WhisprGo-notary
gh auth status
.build/artifacts/sparkle/Sparkle/bin/generate_keys -p --account com.whisprgo.app
```

The signing-identity output must contain the exact Developer ID identity above. The notarization history command must authenticate successfully. GitHub must be authenticated as an account with write access to `Lxvi101/WhisprGo`. `generate_keys -p` must return the public key already stored in `Packaging/Info.plist`; if it differs, stop instead of rotating the update key.

If the Developer ID identity is missing, the certificate and matching private key must be imported together (normally from a password-protected `.p12`) into the login Keychain. A `.cer` alone is insufficient. Never ask the user to paste the `.p12` password into chat or a command that would expose it.

## Versioning and validation

For each release, update both values in `Packaging/Info.plist`:

- `CFBundleShortVersionString`: user-facing semantic version, also used for the tag and DMG name.
- `CFBundleVersion`: monotonically increasing integer used by Sparkle to compare builds.

Keep the tag in the form `v<CFBundleShortVersionString>`. Before packaging, run:

```sh
plutil -lint Packaging/Info.plist
plutil -lint Packaging/WhisprGo.entitlements
zsh -n Scripts/build-app.sh Scripts/build-dmg.sh Scripts/build-release.sh Scripts/generate-appcast.sh
git diff --check
swift test --configuration release
```

Do not run performance benchmarks unless the user requests them. A code-review performance audit is separate from release correctness checks.

## Build, sign, notarize, and staple

The supported release entry point is:

```sh
zsh Scripts/build-release.sh
```

Defaults used by the script:

- `WHISPRGO_SIGNING_IDENTITY="Developer ID Application"`
- `WHISPRGO_NOTARY_PROFILE="WhisprGo-notary"`

Override these only when the stored identity/profile genuinely changed. The script performs two notarization submissions intentionally:

1. Developer ID-sign the app and Sparkle framework/helpers with Hardened Runtime.
2. Zip and notarize the app, then staple the app ticket.
3. Build and sign the DMG from that stapled app.
4. Notarize and staple the DMG.
5. Verify the signatures and Gatekeeper assessments.

Expected output for version `X.Y.Z`:

- `.build/WhisprGo.app`
- `.build/WhisprGo-X.Y.Z.dmg`

Both notarization submissions must report `Accepted`. Then independently verify:

```sh
codesign --verify --deep --strict --verbose=2 .build/WhisprGo.app
codesign -d --entitlements :- .build/WhisprGo.app
xcrun stapler validate .build/WhisprGo.app
spctl --assess --type execute --verbose=4 .build/WhisprGo.app
xcrun stapler validate .build/WhisprGo-X.Y.Z.dmg
spctl --assess --type open --context context:primary-signature --verbose=4 .build/WhisprGo-X.Y.Z.dmg
hdiutil verify .build/WhisprGo-X.Y.Z.dmg
```

The app entitlement output must show `com.apple.security.device.audio-input = true`. Gatekeeper must report `accepted` with `source=Notarized Developer ID`.

## Generate and verify the Sparkle feed

After the final stapled DMG exists, run:

```sh
zsh Scripts/generate-appcast.sh
```

This command reads the private EdDSA key from the `com.whisprgo.app` Keychain account, signs the new DMG enclosure, updates `appcast.xml`, and signs the entire feed. It preserves up to three versions. Never hand-edit `appcast.xml` after generation; any modification invalidates the feed signature.

Verify the XML, signed feed, archive signature, and byte length before publishing:

```sh
xmllint --noout appcast.xml
.build/artifacts/sparkle/Sparkle/bin/sign_update --account com.whisprgo.app --verify appcast.xml
```

Read the newest enclosure's `sparkle:edSignature` from `appcast.xml` and verify the matching DMG with:

```sh
.build/artifacts/sparkle/Sparkle/bin/sign_update --account com.whisprgo.app --verify .build/WhisprGo-X.Y.Z.dmg '<edSignature>'
```

Also ensure the enclosure `length` exactly equals `stat -f%z .build/WhisprGo-X.Y.Z.dmg`, and its URL is:

```text
https://github.com/Lxvi101/WhisprGo/releases/download/vX.Y.Z/WhisprGo-X.Y.Z.dmg
```

## Commit, push, and publish on GitHub

Review `git status`, staged paths, and the complete diff. Stage only the intended release source, packaging scripts, entitlements, version change, and generated `appcast.xml`. Never stage `.build`, certificates, exported Sparkle keys, credential files, or temporary release notes.

Use a terse release commit such as:

```sh
git commit -m "Release WhisprGo X.Y.Z"
git push origin main
```

Create a public GitHub release with the notarized DMG only:

```sh
gh release create vX.Y.Z .build/WhisprGo-X.Y.Z.dmg \
  --repo Lxvi101/WhisprGo \
  --target main \
  --title "WhisprGo X.Y.Z" \
  --notes-file /path/to/release-notes.md
```

Release notes should explain user-facing changes and any one-time migration action. Do not attach the notarization ZIP, raw `.app`, private keys, symbols containing secrets, or build caches.

Immediately verify the public release:

```sh
gh release view vX.Y.Z --repo Lxvi101/WhisprGo --json url,tagName,isDraft,isPrerelease,targetCommitish,assets
shasum -a 256 .build/WhisprGo-X.Y.Z.dmg
```

The release must be public (`isDraft=false`, `isPrerelease=false` unless explicitly requested), target `main`, and contain exactly the expected DMG. The local SHA-256 must equal the asset digest returned by GitHub.

Finally fetch the public feed, confirm it exactly matches the committed feed, and confirm the new asset URL responds:

```sh
curl -fsSL -o /tmp/whisprgo-appcast-remote.xml https://raw.githubusercontent.com/Lxvi101/WhisprGo/main/appcast.xml
cmp appcast.xml /tmp/whisprgo-appcast-remote.xml
xmllint --noout /tmp/whisprgo-appcast-remote.xml
```

If the feed was pushed a few seconds before the GitHub asset became public, clients may briefly receive a missing asset and will retry later. Minimize this window. Do not declare the release complete until the repository is clean, `main` matches `origin/main`, notarization/Gatekeeper checks pass, Sparkle signatures verify, the feed is public, and the release asset digest matches.
