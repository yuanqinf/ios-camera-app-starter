# ios-camera-app-starter

A SwiftUI camera app for iOS 18 to build your own on: photo, video, Live
Photos, Portrait and macro, with tap-to-lock subject tracking. Fork it, rename
it, and start from a camera that already works.

> **Status:** early. It runs on device, but the structure may still change
> before 1.0.

## Where it comes from

This is the camera I built as the foundation of a pet camera app. Pets don't
hold still, so it had to be quick to shoot, quick to focus, and able to follow
a subject that won't stay put. Once it worked, the camera turned out to have
nothing to do with pets, so I took out everything that did and opened up the
rest. Subject tracking, which started out following cats and dogs, now finds
people and faces too.

## Features

**Capture**
- Photos in 4:3, 16:9 and 1:1, saved as HEIC where the device supports it
- Video recording, with sound
- Live Photos
- Portrait mode, with depth kept so the blur stays editable in Photos
- Automatic switch to macro on iPhones that support it
- Deferred photo processing, so the shutter is ready again straight away
- Auto-enhance with Core Image

**Controls**
- Zoom by preset lens, pinch, or a slider on the front camera
- Flash, torch, and a 3, 5 or 10 second self-timer
- Tap to focus

**Subject tracking**
- Finds faces, people and animals with Vision, and falls back to whatever
  stands out in the frame
- Tap a subject to lock focus on it and keep following it as it moves

**Library**
- Saves to an album of the app's own, with location when allowed
- The thumbnail opens the Photos app

## Requirements

- iOS 18.0 or later, iPhone only
- Xcode 26
- A physical iPhone. The simulator has no camera.

## Getting started

1. Clone the repository.
2. Copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig`, and set
   your team ID and a bundle identifier of your own. Git ignores that file,
   so your values stay on your machine and out of the project file.
3. Open `CameraStarter.xcodeproj`, pick your iPhone, and run.

## Making it yours

| To change | Where |
| --- | --- |
| Bundle identifier and team | `Config/Local.xcconfig` |
| Name under the icon | `INFOPLIST_KEY_CFBundleDisplayName` in the target's build settings |
| Album the app saves into | `CaptureAlbum.shared` in `Photos/CaptureAlbum.swift` |
| Accent color | `AccentColor` in `Assets.xcassets` (system blue until set) |
| Other colors, animations, haptics | `DesignSystem/Theme.swift` |
| App icon | `AppIcon` in `Assets.xcassets` |
| Permission prompts | The `NS…UsageDescription` keys in the target's build settings |
| Wording, and other languages | `Localizable.xcstrings`, a String Catalog keyed by the English text |

## How it fits together

- `CameraManager` owns the `AVCaptureSession`: configuration, capture,
  recording, zoom, focus and macro, split by job across the
  `CameraManager+…` files. It hands finished photos and videos out through
  async streams.
- `CameraModel` reads those streams, saves each capture, and keeps the
  thumbnail on the newest one.
- `CaptureAlbum` finds or creates the app's album and saves into it.
- `SubjectDetector` runs Vision on preview frames and feeds auto-focus and
  `SubjectLockService`, which follows the subject you tap.
- `CameraView` lays out the screen from the components in `Camera/UI`.

## Tests

`CameraStarterTests` covers the logic that doesn't need a camera: choosing
the subject to focus on, keeping a subject's identity from frame to frame,
detection throttling, coordinate conversion and aspect ratios. They use Swift
Testing and run on the simulator with ⌘U.

## Before you ship

- **Privacy manifest.** `PrivacyInfo.xcprivacy` declares what the app does
  today: no tracking, no data collected, and the reasons it uses
  `UserDefaults` and the system clock. Update it if you add analytics, crash
  reporting or a backend.
- **Opening Photos.** The thumbnail opens the Photos app through
  `photos-redirect://`, which works but isn't documented by Apple. If that
  worries you for App Review, show the photos in-app instead.

## License

MIT. See [LICENSE](LICENSE).
