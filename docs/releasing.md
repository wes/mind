# Releasing Mind

Everything ships from GitHub Actions. Nothing is built or signed on a laptop,
which means a release is reproducible from a commit and does not depend on
whose machine has which certificate.

## The two channels

| | What triggers it | Where it lands |
| --- | --- | --- |
| **nightly** | any push to `main` that touches code | the rolling [`nightly`](https://github.com/wes/mind/releases/tag/nightly) pre-release, replaced each time |
| **release** | pushing a `v*` tag | a permanent release, marked latest |

Both are built the same way — universal, Developer ID signed, hardened runtime,
notarized by Apple and stapled. The only difference is where the DMG is
published and what the notes say. That is deliberate: if notarization is going
to break, it breaks on an ordinary push to `main` rather than on the evening you
were trying to ship.

Documentation-only pushes are skipped, so editing the README does not spend ten
minutes of macOS runner time and two notarization submissions.

## Cutting a release

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist` and merge that to
   `main`.
2. Tag it:

   ```sh
   git tag v1.2.0 && git push origin v1.2.0
   ```

The workflow warns if the tag and the plist disagree, and builds the tag's
version regardless. If you would rather type a version than make a tag, run the
Release workflow by hand from the Actions tab.

## Notarizing by hand

You should not need to, but it is the same two scripts CI runs:

```sh
./build.sh --universal --require-signing --version 1.2.0
./scripts/notarize.sh dist/Mind.app       # staple the app
./scripts/make-dmg.sh 1.2.0
./scripts/notarize.sh dist/Mind-1.2.0.dmg # staple the image
```

The app and the image each get their own ticket. Notarizing only the image
covers the copy inside it, but the moment someone drags that copy to
`/Applications` it is a separate file with no ticket of its own — and on a
machine that cannot reach Apple, Gatekeeper then has nothing to check.

For local runs, store your notarization credentials once:

```sh
xcrun notarytool store-credentials mind \
    --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 \
    --key-id XXXXXXXXXX \
    --issuer 00000000-0000-0000-0000-000000000000
```

`notarize.sh` picks that profile up automatically.

## The five secrets

CI needs a certificate to sign with and a key to notarize with. Neither can be
derived from the other, so there are two groups.

### Signing: the Developer ID certificate

Requires a paid Apple Developer Program membership. In Keychain Access, find
**Developer ID Application: Your Name (TEAMID)**, expand it so the private key
is included, right-click → **Export**, save as `.p12`, and give it a password.
Exporting without the private key is the usual mistake — the certificate alone
cannot sign anything.

```sh
base64 -i DeveloperID.p12 | pbcopy
gh secret set MACOS_CERTIFICATE_P12 --repo wes/mind        # paste
gh secret set MACOS_CERTIFICATE_PASSWORD --repo wes/mind   # the export password
```

Then delete the `.p12`. It is the one file that would let someone else sign
software as you.

| Secret | What it is |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | base64 of the `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | the password you exported it with |

Developer ID certificates last five years. When one expires, every build fails
at the signing step; create a new one in the Apple Developer portal and repeat
the above.

### Notarizing: an App Store Connect API key

An app-specific password also works, but an API key is better: it is scoped,
revocable on its own, and does not break when you change your Apple ID password
or its two-factor device.

In [App Store Connect → Users and Access → Integrations →
Keys](https://appstoreconnect.apple.com/access/integrations/api), create a key
with the **Developer** role. You get three things, and the `.p8` can only be
downloaded once.

```sh
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
gh secret set APPLE_API_KEY_P8 --repo wes/mind      # paste
gh secret set APPLE_API_KEY_ID --repo wes/mind      # the 10-character key ID
gh secret set APPLE_API_ISSUER_ID --repo wes/mind   # the issuer UUID, shown above the key list
```

| Secret | What it is |
| --- | --- |
| `APPLE_API_KEY_P8` | base64 of the `AuthKey_*.p8` |
| `APPLE_API_KEY_ID` | the key's 10-character ID |
| `APPLE_API_ISSUER_ID` | the issuer UUID for your team |

To rotate, create a new key, set the three secrets, then revoke the old one.

## When it goes wrong

**"No 'Developer ID Application' identity in the imported certificate."** The
`.p12` was exported without its private key, or it holds an *Apple Development*
or *Apple Distribution* certificate instead. Only a Developer ID Application
certificate can sign software for distribution outside the App Store.

**"--require-signing needs a Developer ID certificate."** `build.sh` fell back
to ad-hoc, which means the keychain step did not take effect. Look at the
earlier "Load the Developer ID certificate" step. The guard exists so a release
fails here rather than publishing a DMG nobody can open.

**Notarization rejected.** The script prints Apple's own log, which names the
offending binary and reason. Almost always one of: the hardened runtime missing
(`--options runtime`), a missing secure timestamp (`--timestamp`, which needs
network access at signing time), or an unsigned nested binary.

**The DMG opens with a warning anyway.** Check the ticket actually attached:

```sh
xcrun stapler validate ~/Downloads/Mind-1.2.0.dmg
spctl --assess -t open --context context:primary-signature -vv ~/Downloads/Mind-1.2.0.dmg
```

A file that was notarized but not stapled still passes on a machine that can
reach Apple, and fails on one that cannot — so test this offline if you want the
honest answer.

**Apple is slow.** Notarization normally takes a couple of minutes. The scripts
wait up to 30. If [Apple's developer system
status](https://developer.apple.com/system-status/) shows a notary incident,
there is nothing to fix on this end.
