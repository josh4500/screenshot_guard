# screenshot_shield

[![pub package](https://img.shields.io/pub/v/screenshot_shield.svg)](https://pub.dev/packages/screenshot_shield)
[![pub points](https://img.shields.io/pub/points/screenshot_shield)](https://pub.dev/packages/screenshot_shield/score)
[![CI](https://github.com/josh4500/screenshot_guard/actions/workflows/ci.yml/badge.svg)](https://github.com/josh4500/screenshot_guard/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Protect sensitive screens in your Flutter app. `screenshot_shield` detects screenshots
and screen recording, blanks screen captures of a whole screen or of a single sensitive
region, and hides your app's content in the app switcher.

- **Prevent capture** - screenshots and screen recordings come out blank (Android, iOS,
  Windows), and so does the app-switcher snapshot (Android, iOS).
- **Detect screenshots** - get a callback, plus a PNG of the guarded screen to share
  instead of the blanked frame (Android, iOS).
- **Detect screen recording and mirroring** - a stream and a getter you can react to
  (Android 15+, iOS; best-effort on desktop).
- **Protect one region** - keep a card number or a balance out of recordings while the
  rest of the screen stays capturable (iOS).
- **App-switcher privacy** - hide the app's content when it goes to the background.
- **Route-aware guards** - protection turns on while a screen is visible and off when it
  isn't, and several guards can be active at once.

## Platform support

| Feature | Android | iOS | Windows | Linux |
|---|:-:|:-:|:-:|:-:|
| Prevent capture (`preventCapture`) | ✅ | ✅¹ | ✅ | ❌ |
| Screenshot detection | ✅² | ✅ | ❌ | ❌ |
| Screen-recording detection | ✅ 15+ | ✅ | ⚠️³ | ⚠️³ |
| Region protection (`ScreenshotShieldSensitiveView`) | ❌ | ✅¹ | ❌ | ❌ |
| App-switcher privacy (`backgroundBlur`) | ✅ | ✅ | ✅ | ❌ |
| Keyboard protection | ❌ | ✅¹ | ❌ | ❌ |

¹ Relies on undocumented UIKit behaviour - verify on the iOS versions you support (see
[iOS](#ios)).
² Android 14+ uses the system API. Android 10-13 needs a media permission granted by the
host app (see [Android](#android)).
³ A heuristic that looks for known recorder programs; see [Windows and Linux](#windows-and-linux).

## Install

```sh
flutter pub add screenshot_shield
```

No configuration is needed for the defaults. Read [Android](#android) if you want
screenshot detection on Android 10-13.

## Quick start

Provide a `ScreenshotShield` with `ScreenshotShieldScope`, register its route observer
with your app, and wrap a sensitive screen in a `ScreenshotShieldRouteGuard`:

```dart
final routeObserver = RouteObserver<ModalRoute<void>>();

void main() {
  runApp(
    ScreenshotShieldScope(
      shield: ScreenshotShield(),
      routeObserver: routeObserver,
      child: MaterialApp(
        navigatorObservers: [routeObserver],
        home: const PaymentScreen(),
      ),
    ),
  );
}

class PaymentScreen extends StatelessWidget {
  const PaymentScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenshotShieldRouteGuard(
      onScreenshotDetected: (image) {
        // `image` is a PNG of the guarded screen (null if capture failed).
        // Show it to the user or share it, e.g. with `share_plus`.
      },
      child: const Scaffold(body: Center(child: Text('Card number: 1234'))),
    );
  }
}
```

While `PaymentScreen` is visible, captures of it come out blank and screenshots are
reported. When another route covers it, protection and listening are released.

## Usage

### Guarding a screen

`ScreenshotShieldRouteGuard` follows the route it lives on. For content that is not a
route (tabs, overlays, embedded views) use `ScreenshotShieldGuard`, which is active while
it is mounted and its `active` flag is `true`:

```dart
ScreenshotShieldGuard(
  active: showBalance,
  child: BalanceCard(balance: balance),
)
```

Both guards take the same options:

| Option | Default | Effect |
|---|---|---|
| `preventCapture` | `true` | Blank captures while the guard is active. |
| `detectScreenshots` | `true` | Listen for screenshots while active. |
| `forcePreventCapture` | `false` | On Android, keep prevention even when detection is on (see below). |
| `captureOnScreenshot` | `true` | Re-rasterize the guarded subtree into a PNG on each screenshot. |
| `onScreenshotDetected` | - | Called with that PNG (or `null`). |

Guards count their requests: with two guards on screen, protection stays on until the
last one that needs it goes away.

**Android:** the secure window flag that blanks captures also stops screenshots from
being saved, so no screenshot event can fire while it is on. When a guard asks for both,
detection wins and prevention is dropped on Android; set `forcePreventCapture: true` to
keep the blanked frame instead (and accept that `onScreenshotDetected` will not fire).
On iOS and Windows the two work together.

### Detect-and-notify mode

To let screenshots succeed and react to them instead - a Snapchat-style "they took a
screenshot" flow - turn prevention off:

```dart
ScreenshotShieldRouteGuard(
  preventCapture: false,
  onScreenshotDetected: (image) => notifyPeer(image),
  child: const ChatScreen(),
)
```

### Protecting one region (iOS)

`ScreenshotShieldSensitiveView` keeps one part of the screen out of captures while the
rest stays capturable:

```dart
ScreenshotShieldSensitiveView(
  // What a capture shows where the region is. Defaults to black.
  captureColor: Colors.black,
  // What the user sees behind the region where the child is transparent.
  backdropColor: Theme.of(context).scaffoldBackgroundColor,
  child: const Text('Account number: 1234'),
)
```

| `protection` | Covers | Cost |
|---|---|---|
| `SensitiveProtection.whileRecording` | screen recordings and mirroring | none while not recording |
| `SensitiveProtection.whileCaptured` (default) | the above, plus the app-switcher snapshot | none while not captured |
| `SensitiveProtection.always` | the above, plus foreground screenshots | continuous, see below |

By default the widget is effectively not there: it lays out and paints `child`
unchanged, creates no platform view and rasterises nothing. It takes over only while the
screen is recorded or mirrored (`ScreenshotShield.isScreenRecording`) or the app is in the
background. While engaged, the subtree stays live and interactive - taps, focus and text
input reach `child` - and a native view nested in a capture-excluded canvas shows a copy
of it that refreshes whenever the subtree repaints (at most once per frame). A capture
sees `captureColor` instead. `ScreenshotShieldSensitiveViewController.refresh()`
refreshes on demand.

`protection: SensitiveProtection.always` keeps the region engaged permanently, which also
blanks foreground screenshots, at these costs:

- The region is a native view, so it composites above Flutter content: a Flutter overlay
  that covers the region (a dialog, a tooltip, a selection toolbar) draws behind it.
- Each refresh is a GPU readback, so continuously repainting content (video, large
  animations) keeps the CPU busy. Cap it with `refreshInterval`, or use a guard instead.
- The copy is one frame behind.

Region protection stands down while whole-window prevention is active.

<details>
<summary>Why a foreground screenshot cannot be blanked per region without a copy</summary>

iOS excludes a *native view's own layer* from captures, and Flutter renders every widget
into one surface (`PlatformViewLayer` is the only composited native view). Nesting live
Flutter content in the excluded layer is therefore impossible, and an excluded layer is
*omitted* from the capture rather than replaced by black - so a shield that is
transparent on screen would reveal the live widget to the capture as well. The only way
to blank a region in a screenshot is to display something native in it: a rasterised
copy, which is what `protection: always` does.

Flutter's own `SensitiveContent` widget is not an alternative: it obscures the **entire
screen** during media projection, and only on Android 15+.

</details>

### App-switcher privacy

```dart
await ScreenshotShield().setProtection(backgroundBlur: true);
```

| Platform | What the app switcher shows |
|---|---|
| Android 13+ | No thumbnail of the app (`setRecentsScreenshotEnabled(false)`); screenshots and their detection are unaffected. |
| Android 12 and below | The content blurred (with `RenderMode.texture`) or covered. |
| iOS | The content blurred. The blur also appears while the app is inactive, e.g. under Control Center or a system alert. |
| Windows | The app icon instead of a live preview in the taskbar thumbnail and Alt+Tab. |

While `preventCapture` is on, the app-switcher snapshot is blank anyway.

### Screen-recording detection

```dart
final shield = ScreenshotShield();
shield.onScreenRecordingChanged.listen((isRecording) {
  // Hide sensitive content, pause playback, ...
});
await shield.startListening();

// Or read the current state at any time:
if (shield.isScreenRecording) { /* ... */ }
```

The stream emits the current state when listening starts and then every change. iOS
reports recording, mirroring (AirPlay) and screen sharing for the app's scene; Android
15+ reports whether the app is visible in a recording.

### Keyboard protection (iOS)

The on-screen keyboard is a window of its own, so neither whole-window protection nor a
region covers it - a capture with the keyboard up shows the keys.

```dart
await ScreenshotShield().setKeyboardProtection(enabled: true);
```

On iOS this nests the keyboard window's content in the same capture-excluded canvas, so
captures get no keyboard pixels (undocumented UIKit behaviour: verify it on the iOS
versions you support). On Android the keyboard belongs to another app and cannot be
excluded; keep sensitive input inside your app instead (an in-app keypad is ordinary
Flutter content the guards cover), or hide the keyboard while
`onScreenRecordingChanged` is `true`.

### Low-level API

The guards are built on `ScreenshotShield`, which you can drive directly:

```dart
final shield = ScreenshotShield();
shield.onScreenshotDetected.listen((_) => showShareSheet());

await shield.startListening();                    // calls are counted
await shield.setProtection(preventCapture: true); // sets the window state directly

// Later:
await shield.setProtection(preventCapture: false);
await shield.stopListening();
```

`setProtection` sets the window's state directly, so prefer the guards when more than
one part of the app needs protection.

## Platform notes

### Android

| Android | Screenshot detection | Permission |
|---|---|---|
| 14+ (API 34) | System `ScreenCaptureCallback`, immediate | `DETECT_SCREEN_CAPTURE` (normal, declared by the plugin) |
| 10-13 (API 29-33) | Media store observer, shortly after the image is saved | `READ_EXTERNAL_STORAGE` (10-12) or `READ_MEDIA_IMAGES` (13) - declare and request it in your app |
| 7-9 (API 24-28) | Media store observer | `READ_EXTERNAL_STORAGE` - declared by the plugin, request it at runtime |

Without the media permission on Android 10-13, the screenshot (owned by System UI) is
invisible to your app and no event fires. Only request it if detection on those versions
matters to you: Google Play asks apps to justify photo permissions.

On Android 14+ the system shows a notice when an app detects a screenshot. Screenshots
taken through ADB are not reported. Screen-recording detection needs Android 15 (API 35,
`DETECT_SCREEN_RECORDING`).

The plugin's manifest merges `DETECT_SCREEN_CAPTURE`, `DETECT_SCREEN_RECORDING` and
`READ_EXTERNAL_STORAGE` (up to API 28) into your app. To drop one, add it to your app's
`AndroidManifest.xml` with `tools:node="remove"` (declare
`xmlns:tools="http://schemas.android.com/tools"` on the `<manifest>` element):

```xml
<uses-permission android:name="android.permission.DETECT_SCREEN_RECORDING" tools:node="remove" />
```

Debug logs are off by default; enable them with
`adb shell setprop log.tag.ScreenshotShield DEBUG`.

### iOS

iOS has no public API for blocking screenshots. `preventCapture` relies on a
`UITextField` with `isSecureTextEntry`: UIKit renders such a field through a private
capture-excluded canvas layer, and the plugin nests the app's content layer inside it, so
screenshots, recordings and the app-switcher snapshot come out blank while
`onScreenshotDetected` still fires.

- Protection is re-applied automatically when UIKit rebuilds the view hierarchy (for
  example after a full-screen modal is dismissed) and when the app becomes active.
- Native modals and alerts presented over the app are separate views and are not covered.
- Because it depends on undocumented behaviour, a future iOS release can break it, and it
  may draw questions in App Store review. Verify it on every iOS version you support, and
  keep detect-and-notify mode as a fallback.
- Test on a device or with the simulator's **Device > Trigger Screenshot**:
  `xcrun simctl io screenshot` reads the framebuffer directly and is never masked. The
  simulator never reports a recording.

No permissions or `Info.plist` entries are needed. The plugin ships a privacy manifest.

### Windows and Linux

- **Windows:** `preventCapture` uses `SetWindowDisplayAffinity`: on Windows 10 2004+ the
  window is left out of screenshots, recordings and screen sharing; older versions show
  it black. Windows has no screenshot notification, so `onScreenshotDetected` never fires.
- **Linux:** there is no standard mechanism for detection or prevention; the widgets still
  work and the calls are accepted.
- **Recording detection (both):** while listening, the process list is sampled every two
  seconds and `onScreenRecordingChanged` is `true` while a known recorder (OBS, Bandicam,
  Camtasia, Kazam, Kooha, `wf-recorder`, ...) is running. A recorder that is open but idle
  counts as recording, and unlisted or sandboxed recorders (and GNOME's built-in one) are
  missed.

## Example

A runnable example with a toggle for every feature lives in [`example/`](example):

```sh
cd example
flutter run
```

## License

MIT - see [LICENSE](LICENSE).
