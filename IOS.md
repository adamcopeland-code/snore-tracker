# Snore Tracker for iPhone

This is the web app wrapped in a native iPhone app (Capacitor). A custom Swift plugin
records the microphone. The recording continues when the screen is locked.
The web app is not changed. The root files (`index.html` and others) are the only source.
The same files still run from GitHub Pages.

Note: this project was made on Linux. It was not built or run on a Mac or an iPhone before you
got it. Expect to fix small build errors on the first build. See "If the build fails".

## What you need

- A Mac with the newest Xcode from the Mac App Store. Open Xcode one time and accept the license.
- Node.js 22 or newer (`node -v`). Install it from nodejs.org if needed.
- An iPhone with iOS 16 or newer, and a USB cable.
- An Apple ID. A free one is enough.

## Steps

1. Get the code and open a terminal in the project folder:

   ```
   git clone https://github.com/adamcopeland-code/snore-tracker.git
   cd snore-tracker
   git checkout ios-app
   ```

2. Install the packages:

   ```
   npm install
   ```

3. Copy the web files into the app and update the iOS project:

   ```
   npm run sync
   ```

   Run this command again each time you change `index.html`.

4. Open the project in Xcode:

   ```
   npx cap open ios
   ```

   Xcode downloads the Capacitor Swift package on the first open. Wait until the progress bar at the top is done.

5. Set the signing team:
   1. In the left list, click the blue **App** project.
   2. Under **Targets**, click **App**, then the **Signing & Capabilities** tab.
   3. Turn on **Automatically manage signing**.
   4. In **Team**, choose **Add an Account...** and sign in with your Apple ID. Then choose your name (Personal Team).
   5. If Xcode says the bundle identifier is not available, change **Bundle Identifier** to a unique name,
      for example `com.yourname.snoretracker`.

6. Connect the iPhone with the cable. Unlock it and tap **Trust**.
   Turn on **Developer Mode** on the iPhone: **Settings > Privacy & Security > Developer Mode**.
   This switch shows after the iPhone is connected to Xcode. The phone restarts.

7. At the top of Xcode, pick your iPhone in the device list (not a simulator).
   The simulator has no useful microphone and no background test.

8. Press **Run** (the play button). The first install can take a few minutes.

9. On the iPhone, the first launch can say **Untrusted Developer**. Go to
   **Settings > General > VPN & Device Management**, tap your Apple ID, and tap **Trust**.
   Then open the app again.

10. In the app, go to Settings and tap **Test microphone**. Tap **Allow** when iOS asks.
    The level bar must move when you speak.

## Install limits

- A free Apple ID: the app stops working after 7 days. To use it again, connect the iPhone
  and press **Run** in Xcode again. Your saved nights stay on the phone when you install over the old app.
  Do not delete the app from the iPhone, because that deletes the data. Export your nights from
  the app first if you are not sure.
  You can have 3 apps like this on one iPhone.
- An Apple Developer account (99 USD per year) removes the 7 day limit. The app is then valid
  for one year, and you can use TestFlight.

## Use it

Plug in the charger. Put the phone near your bed. Tap **Start recording**. You can lock the
screen with the side button, or leave it on. The unlocked screen shows the dim clock and does not
go to sleep while recording. At the end, press and hold **Hold to stop**.

## Test that background recording works

Do this test before you trust the app for a whole night.

1. Start a recording. Make some noise, for example talk or clap, so that the timeline has data.
2. Lock the phone with the side button. Leave it locked on the charger for 5 minutes.
   Make a noise at about 1 minute and at about 4 minutes.
3. Unlock the phone. The app must still show the recording clock with the correct elapsed time.
4. Hold **Hold to stop**. Open the night.
5. Look at the timeline. There must be no gap. Every minute must have data, and the noise must show at
   about minute 1 and minute 4. Also check that the clips list shows clips and that **Play** works.
6. Then do one full test night and check the same things in the morning.

If there is a gap, look at the Xcode console (run from Xcode with the cable on). The plugin writes
lines with the category `SnoreMic` for interruptions, route changes, restarts and silence.
Lines from the web view start with `SnoreMic`.

How the app copes with a paused web view: the Swift plugin keeps every 100 ms measurement in memory.
When the web view runs again, the app fetches the missed measurements and counts them. The timeline then
has no gap. The plugin holds only the last 30 seconds of audio for clips. A snore that the web view counts
later than that gets no clip. This is a known limit.

Phone calls and alarms stop the microphone. The plugin starts it again when they end.

## Files

- `capacitor.config.ts`: app id `com.adamcopeland.snoretracker`, app name, web folder `www`.
- `scripts/sync-web.mjs`: copies the root web files to `www/` (ignored by git). `npm run sync` runs it and `cap sync ios`.
- `ios/App/App/SnoreMicPlugin.swift`: the Capacitor plugin (audio session, engine, events, interruptions).
- `ios/App/App/SnoreAudio.swift`: level and FFT analysis, and rolling 10 s AAC segment files.
- `ios/App/App/SnoreBridgeViewController.swift`: registers the plugin.
- `ios/App/App/Info.plist`: microphone text and the `audio` background mode.
- `assets/` and `npm run assets`: icon and splash sources. The command makes them again from `icon-512.png`.

## Update

After you change `index.html`, run `npm run sync` and press **Run** in Xcode.
Bump the `CACHE` name in `sw.js` for the web version, as in the README.

## If the build fails

- No Mac was used to build this project. Compile errors in `SnoreMicPlugin.swift` or
  `SnoreAudio.swift` are possible. Read the red message in Xcode, or send it to Claude.
- `allowBluetooth` can show a deprecation warning in new Xcode versions. It is only a warning.
- If Xcode cannot find the `Capacitor` module, use **File > Packages > Reset Package Caches**, then build again.
- If the web view is blank, run `npm run sync` again. The folder `ios/App/App/public` is made by that command.
