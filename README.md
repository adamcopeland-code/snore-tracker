# Snore Tracker

A personal snoring tracker that runs in your phone's browser. It records
through the microphone, detects snoring, scores the night, saves short
audio clips of the loudest snores, and tracks factors and remedies over
time. All data stays on your phone (IndexedDB). No account, no server.

The app is a single HTML file at the repo root plus a web manifest, a
service worker and icons.

## Host it with GitHub Pages (one time)

1. Open this repository on GitHub, then **Settings > Pages**.
2. Under **Build and deployment**, set **Source** to **Deploy from a branch**.
3. Pick the branch **main** and the folder **/ (root)**. Save.
4. After about one minute the app is live at
   `https://adamcopeland-code.github.io/snore-tracker/`.

The microphone only works over https, so open the Pages URL, not a raw file.

## Install it on your phone

- **iPhone:** open the URL in Safari, tap Share, then **Add to Home Screen**.
- **Android:** open the URL in Chrome, tap the menu, then **Add to Home screen**.

## Use it

1. Plug in the charger. Place the phone within 1 m of your head.
2. Tap **Start recording** and allow the microphone.
3. Leave the screen on. The sleep screen dims to a faint clock.
   On iOS 16.4 or newer the app keeps the screen awake. On older
   versions turn off auto-lock for the night.
4. In the morning press and hold **Hold to stop** for 1.5 seconds.

## Limits

- The phone must stay unlocked and on this app all night. Browsers stop
  the microphone when the screen locks.
- Detection is based on loudness, rhythm and low-frequency energy. It is
  untuned against real bedrooms, so adjust **Sensitivity** in Settings.
- Exports contain the minute data, not the audio clips.
- This is not a medical device and does not diagnose sleep apnea.

## Update the app

After you change `index.html`, bump the `CACHE` name in `sw.js`
so installed phones pick up the new version.
