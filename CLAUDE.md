# VVDemus

## Never scaffold a throwaway app

Do not create a separate Xcode project to test a behaviour in isolation. It always looks like the
cheap option in the moment and it never is: the project is abandoned the same session, but the app
stays installed on a simulator indefinitely, under a bundle id nothing on disk explains any more.
`com.probe.navbar` sat on a simulator for months that way, and the only reason it was ever found
was someone going looking for something else.

Use, in order of preference:

1. **`VVDemusTests`.** Nearly everything worth probing is already reachable there. The decision
   types exist for exactly this reason — `PlaybackMirror`, `PeerOutputPolicy`'s successor,
   `castLiveness`, `BackgroundAudioPolicy` — each was pulled out of its owner so the interesting
   cases could be reached without a network, a second device, or waiting out a real grace window.
   If a behaviour is hard to test, extracting the decision is the fix, not a new app.
2. **The Connect server as a harness.** It drives the app under test from the command line:
   `POST /api/play`, `POST /api/seek`, poll `GET /api/state`. Seeking to `duration - 6` turns
   "what happens at the end of a track" into a six-second experiment. It also exposes state the
   UI would never show you, which is the cheapest bug detector this project has.
3. **A static server for web-remote work.** Serving `ios/VVDemus/WebUI/` with stub API routes
   removes the whole build/install/launch cycle and can force states a real phone will not
   produce on demand — 500s, headers-then-hang, out-of-order responses.

If a probe app is genuinely unavoidable, then in the same session: build it into the session
scratchpad rather than `~/Documents`, and `xcrun simctl uninstall` it before you finish. Do not
leave it for the sweep to find.

## The sweep

`/cleanup-stray-apps` removes probe apps, abandoned agent simulators, and the real app on
simulators that are not in use. It also runs automatically after `xcodebuild`/`simctl` commands,
throttled to once every two minutes.

It decides what is junk by asking whether a bundle id is declared by this project — read from
`ios/Config/Signing.local.xcconfig`, because `VVDEMUS_BUNDLE_ID` is per-machine by design (see
`ios/SETUP.md`). Other real projects on this Mac install apps to the same simulators, so anything
with a source tree behind it is protected by `.claude/cleanup-keep.txt`. Add to that file rather
than editing the script.

## Two apps, one fixed port

Both targets build from one source tree and both run `LocalControlServer` on port 51825, falling
forward up to eight ports when it is taken. A leftover Mac build is named **"Spotify β"** — so it
appears in `lsof` as `Spotify` and is easily mistaken for the real thing, while the simulator you
just installed to quietly binds 51826.

Before trusting anything you read over HTTP, confirm which instance is answering:

```sh
lsof -nP -iTCP -sTCP:LISTEN | grep -E '5182[5-9]|5183[0-3]'
curl -s http://127.0.0.1:<port>/api/peer/hello    # {"peerId","name"} — says which app this is
```

Use `127.0.0.1`, not `localhost`: the server binds IPv4 only, and a browser resolving `::1` first
fails outright while `curl` silently falls back and succeeds.

## Committing

Commit to `main`. Do not create a branch first and do not ask whether to branch, unless committing
to `main` is impossible — in which case say what blocked it and name the branch you used instead.
Pushing is always a separate step: only push when asked.
