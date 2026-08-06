# Per-machine setup

Two people work on this repo under two different Apple developer teams. Everything that
differs between those two machines lives in one gitignored file, so no push can reassign the
other person's settings.

## First time on a machine

1. Create `ios/Config/Signing.local.xcconfig`:

   ```
   DEVELOPMENT_TEAM = YOUR_TEAM_ID
   VVDEMUS_BUNDLE_ID = com.yourprefix.vvdemus.app
   ```

   Find your team id with `security find-identity -v -p codesigning` — it is the `OU` of your
   Apple Development certificate.

2. `cd ios && xcodegen generate`

3. Open `VVDemus.xcodeproj`.

## VVDEMUS_BUNDLE_ID never changes

The bundle id is the app's identity on your phone, and iOS keys the app's container to it.
Change it and the next install is a **brand-new app with empty defaults** — no play history,
no downloads, no radios — while the real data sits in a container under the old id, still on
the phone but unreachable from the new app. Nothing is migrated for you.

So: whatever value you use the first time, keep forever. Use the one your phone already has.

A device build refuses to run while the placeholder id from `Signing.xcconfig` is still in
effect, precisely so a missing local file cannot quietly install a second app. Simulator
builds are exempt, so a fresh clone can still run the test suite with no local file.

### Recovering data stranded under an old bundle id

If it has already happened, don't delete anything — the old app still holds the data. Either
point `VVDEMUS_BUNDLE_ID` back at the old id and redeploy (the old app is simply updated in
place, data intact), or lift the container across:

```sh
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier <old.bundle.id> \
  --source Library/Preferences --destination ./out
# ...then `copy to` the same path under the new identifier.
```

`xcrun devicectl list devices` gives the UDID. This works because these are development
builds; it will not work against an App Store install.

## The .xcodeproj is not in git

It is generated from `project.yml` by XcodeGen. It used to be tracked, and it was how the two
machines' signing settings kept overwriting each other: Xcode rewrites that file whenever it
"fixes" signing for you and bakes in whichever `DEVELOPMENT_TEAM` it finds.

Run `xcodegen generate` after cloning, and after any change to `project.yml`. Schemes are
declared in `project.yml`, so they are regenerated too — don't edit them in Xcode.
