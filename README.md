# Mind

A small, calm macOS app that sits in the corner of your screen and knows what's
coming next.

When your day is clear, it's a pastel gradient with a couple of toasters
drifting past. As a meeting approaches it wakes up: the flock thickens, the
colours warm, embers start rising, and in the last couple of minutes it turns
into fireworks. You never have to look at it directly — you just notice the
corner of your screen getting louder.

Mind **reads** your calendar through EventKit. It never creates, edits, or
deletes anything.

![Mind approaching a meeting](docs/approaching.png)

## Build and run

```sh
./build.sh --run          # release build → dist/Mind.app, then launch it
./build.sh --install      # also copy to /Applications
./build.sh --debug        # faster, unoptimised build
./build.sh --universal    # arm64 + x86_64
```

Requires Xcode 16 or newer and macOS 14+. The first launch asks for calendar
access and opens Preferences so you can pick which calendars to watch.

The bundle is **ad-hoc signed**, which is enough for macOS to grant it calendar
access. One consequence: an ad-hoc signature is a new identity every time you
rebuild, so macOS may ask for calendar permission again after a rebuild. That's
expected. (`Open at login` may also refuse for the same reason until the app is
signed with a real Developer ID and living in `/Applications`.)

## Releases

Tagging a version builds a universal DMG and publishes it:

```sh
git tag v1.0.1 && git push origin v1.0.1
```

There's also a manual run in the Actions tab if you'd rather type a version than
make a tag. Either way the artifacts land in a public Tigris bucket:

| | |
| --- | --- |
| This version | `https://mind-releases.t3.storage.dev/Mind-<version>.dmg` |
| Always the newest | `https://mind-releases.t3.storage.dev/Mind-latest.dmg` |
| Version manifest | `https://mind-releases.t3.storage.dev/latest.json` |

The repo is private; those download links are not. `latest.json` carries the
version, size, SHA-256 and source commit, so a future "check for updates" has
something to read.

The workflow needs two repo secrets, `TIGRIS_ACCESS_KEY_ID` and
`TIGRIS_SECRET_ACCESS_KEY`. They belong to a Tigris access key called `mind-ci`
scoped to Editor on the `mind-releases` bucket and nothing else. To rotate:

```sh
tigris keys rotate <key-id>
gh secret set TIGRIS_SECRET_ACCESS_KEY --repo wes/mind
```

## How it behaves

Everything in the app is driven by one number: **intensity**, from 0 to 1,
derived from how long until your next meeting.

| Time until | Phase | What you see |
| --- | --- | --- |
| Nothing on the horizon | Clear | A pale gradient, two clouds, one toaster |
| More than an hour | Distant | Slow drift, a soft "NEXT" and the time |
| Inside the *wake up* threshold | Approaching | More toasters, warmer sky, the fuse bar starts filling |
| Inside the *get busy* threshold | Imminent | A thick flock, flying toast, embers rising from the bottom |
| Inside the *panic* threshold | Critical | Fireworks, shockwaves, a tremor |
| Start time passed | Starting / In progress | A barrage, then it settles into "24m left" |

Each escalation fires a burst as punctuation, so a change of state catches your
eye without a notification.

Thresholds are yours to set — Preferences → Timing. Everything downstream
re-shapes itself around them.

## The panel

- **Drag anywhere** to move it; **drag the corner grip** to resize.
- **Right-click** for size presets, Preferences, and Quit.
- Sizes from a 200×92 sliver to a half-screen board. The layout re-tiers as it
  grows: countdown only → countdown and title → detail line and fuse → the
  upcoming schedule.
- If the next meeting has a video link, **click the panel to join it**.
- A menu bar item mirrors the countdown (`◔ 12m`, `◍ 4m`, `● Standup`).

## Preferences

| Tab | What's in it |
| --- | --- |
| General | Float on top, all Spaces, click-through, opacity, hide when clear, size presets, menu bar item, open at login |
| Calendars | Per-calendar on/off switches and the permission status |
| Timing | How far ahead to look, the three thresholds, all-day events, declined events, minimum duration |
| Appearance | Five palettes, agenda on/off, 24-hour clock, seconds in the final minutes |
| Motion | A live preview you can scrub through the whole intensity range, plus toasters / fireworks / shake / reduce-motion and density |

## Layout of the source

```
Sources/Mind/
  App/          AppKit shell: delegate, floating panel, menu bar, shot renderer
  Calendar/     EventKit reading and the urgency model
  Scene/        The animated world: palettes, particles, and the toasters
  Support/      Preferences, app state, and copy
  Views/        SwiftUI: the ambient panel, its responsive layout, preferences
Sources/MindIconGen/   Draws the app icon at build time
```

The two pieces worth knowing:

- `Urgency.evaluate` turns "next meeting at 3pm" into a phase and an intensity.
  It is the only place that knows about time.
- `SceneModel` owns every particle and takes only that intensity. It has no idea
  what a calendar is, which is why the Motion preview can drive it from a slider.

## Development

```sh
MIND_DEMO=9 dist/Mind.app/Contents/MacOS/Mind
```

Runs against a fabricated agenda whose first event is 9 minutes out, so you can
watch the whole escalation without rearranging your actual day. Demo mode never
touches EventKit, so it never triggers a permission prompt.

```sh
MIND_SHOTS=./shots dist/Mind.app/Contents/MacOS/Mind
```

Renders the real view at every phase and panel size to PNGs, then quits. This is
how the images in this README were made.

```sh
open -n --env MIND_DIAGNOSE=/tmp/mind.txt dist/Mind.app && sleep 3 && cat /tmp/mind.txt
```

Prints the permission state, every calendar Mind can see, and the events it
found in the horizon — the first thing to run when the panel says "clear" and
you don't believe it.

Launch that one through `open`, not straight from the shell. macOS attributes
calendar access to the *responsible* process, so a Mind started from your
terminal inherits your terminal's calendar permission instead of its own, and
will report `denied` even when the app itself is fully authorised.
