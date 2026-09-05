# Contributing to Mind

Thanks for taking a look. Mind is deliberately small, so the bar for a change
is less "does it work" and more "does it keep the app calm".

## Getting set up

You need macOS 14+ and Xcode 16 or newer. There are no dependencies to install
and no project file to open — it is a plain Swift package.

```sh
git clone https://github.com/wes/mind.git
cd mind
./scripts/make-dev-cert.sh   # once, so calendar access survives rebuilds
./build.sh --run
```

**Always test through the app bundle, never the bare binary.** `swift build`
produces an executable with no `Info.plist`, no bundle identifier and no
signature, so macOS will not grant it calendar access and it silently sees zero
events. `./build.sh --run` builds the bundle and launches it.

Two environment variables make development bearable:

```sh
MIND_DEMO=9 dist/Mind.app/Contents/MacOS/Mind      # fake agenda, first event 9m out
MIND_SHOTS=./shots dist/Mind.app/Contents/MacOS/Mind  # render every phase to PNG, then quit
```

Demo mode never touches EventKit, so you can watch the whole escalation without
rearranging your actual day and without a permission prompt.

If the panel insists your calendar is empty and you disagree:

```sh
open -n --env MIND_DIAGNOSE=/tmp/mind.txt dist/Mind.app && sleep 3 && cat /tmp/mind.txt
```

Launch that through `open`, not straight from the shell — macOS attributes
calendar access to the *responsible* process, so a Mind started from your
terminal inherits your terminal's permission and reports `denied` even when the
app is fully authorised.

## The shape of the code

```
Sources/Mind/
  App/          AppKit shell: delegate, floating panel, menu bar, shot renderer
  Calendar/     EventKit reading and the urgency model
  Scene/        The animated world: palettes, particles, and the toasters
  Support/      Preferences, app state, and copy
  Views/        SwiftUI: the ambient panel, its responsive layout, preferences
```

Two boundaries are worth preserving:

- `Urgency.evaluate` is the only place that knows about time. It turns "next
  meeting at 3pm" into a phase and an intensity from 0 to 1.
- `SceneModel` takes only that intensity and has no idea what a calendar is.
  That is why the Motion preview can drive the entire scene from a slider.

If you find yourself reaching for the current date inside `SceneModel`, or for
an `EKEvent` inside `Scene/`, the change probably belongs somewhere else.

## Pull requests

- Branch from `main`, keep the change focused, and open a PR.
- CI builds the bundle on every PR. It does not sign or notarize — those need
  secrets that forks cannot see, and that is expected.
- Write the commit subject as what the change does for a person using the app,
  not what you edited. `Tell an empty calendar apart from an unsynced account`
  beats `Update CalendarService.swift`.
- Match the surrounding style. There is no linter; the existing code is the
  spec.

## Things to know before proposing a feature

Mind is an ambient app. Its whole value is that you can ignore it. Anything that
demands attention — notifications, sounds, modal windows, badges — is working
against the point. Preferences already have five tabs, which is arguably four
too many, so new settings need to earn their place.

The app **only ever reads** your calendar. A change that creates, edits, or
deletes events will not be merged.

## Reporting bugs

Open an issue with your macOS version, whether the build is a release DMG or
locally built, and the output of `MIND_DIAGNOSE` if it is calendar-related. A
screenshot of the panel helps for anything visual.
