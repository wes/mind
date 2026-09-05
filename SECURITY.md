# Security

## What Mind can reach

Mind reads your calendar through EventKit and holds the results in memory. It
has no network code: it does not phone home, collect analytics, sync anything,
or check for updates. Your events never leave your Mac.

It requests exactly one entitlement,
`com.apple.security.personal-information.calendars`, which is the permission to
*ask* — you still have to say yes. Mind never creates, edits, or deletes
events.

Preferences are stored in the standard macOS user defaults for
`com.joedesigns.mind`. Nothing is written anywhere else, except when you
explicitly run a diagnostic dump with `MIND_DIAGNOSE=<path>`, which writes your
upcoming event titles to that file so you can read them.

## Verifying a release

Releases are built by GitHub Actions from a tagged commit, signed with a
Developer ID certificate, and notarized by Apple. To check a downloaded DMG:

```sh
spctl -a -t open --context context:primary-signature -v ~/Downloads/Mind-1.1.0.dmg
xcrun stapler validate ~/Downloads/Mind-1.1.0.dmg
codesign -dv --verbose=2 /Applications/Mind.app
```

The team identifier should read `288BJX6YHP`. Every release also publishes a
SHA-256 checksum alongside the DMG.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Report it privately
through GitHub's [security advisory
form](https://github.com/wes/mind/security/advisories/new), or email
wes@joedesigns.com.

Include what you found, how to reproduce it, and what an attacker could do with
it. You should get a first response within a few days. Mind is a small
single-maintainer project, so please be realistic about turnaround, but anything
that could expose calendar data or run code on someone's machine gets treated as
urgent.
