# Plan: Android emulator

Run and preview the app on an Android emulator inside the same window, with everything the iOS Simulator can do
today: the live screen, clicks and drags as touches, the Mac keyboard, Home, dark mode, text size, Point at…, Run and
Reconnect, and Claude's `ms-sim` vision. iOS stays first when it is there; Android is what a Mac without Xcode gets.

Installing the Android tools from the Get Started checklist is the last phase. Until then this works with an SDK that
Android Studio or `sdkmanager` already installed.

---

## 1. Where we start

What is already device-neutral and needs no change of approach:

- **Run, hot reload, hot restart, Stop**: `flutter run -d <id>` (`FlutterRunProcess`). An Android id is the adb serial,
  `emulator-5554`.
- **Point at…**: `InspectorClient` talks to the Dart VM service, not to the device. Its thumbnail is cut from the
  screen layer's `IOSurface`, so it works if the Android frames arrive as `IOSurface`s too (section 3).
- **Chat, Fix with Claude, checkpoints, History, Design**: none of it touches the device except Design's
  `capturePNG()`, which goes through the model.

What is iOS-only (about 1,300 lines, `Simulator/` plus a few callers):

| Piece | iOS today | Android |
|---|---|---|
| Device list, destination menu | `simctl list devices -j` | `emulator -list-avds` and `~/.android/avd/*.ini` for names; `adb devices` + discovery files for what's running |
| Boot | `simctl bootstatus -b` | start `emulator -avd <name> -no-window -grpc <port> -grpc-use-token`, detached; wait for `getprop sys.boot_completed` = 1 |
| Shut Down | `simctl shutdown` | `adb -s <serial> emu kill` |
| Live screen | CoreSimulator framebuffer (private, `MSSimulatorDisplay`) | emulator gRPC `streamScreenshot` (public, the API Android Studio's embedded emulator uses) |
| Click → tap, drag → swipe | Indigo touch events | gRPC `sendTouch` |
| Mac keyboard | `dtuhidd` HID reports | gRPC `sendKey` with `codeType: Mac` and the NSEvent key code |
| Home | `pressHome` | `sendKey` "GoHome" |
| Back | (none) | `sendKey` "GoBack"; new button and `ms-sim back` |
| Dark / Light | `simctl ui appearance` | `adb shell cmd uimode night yes\|no` |
| Text Size | `simctl ui content_size` | `adb shell settings put system font_scale 0.85…2.0` |
| Paste | `simctl pbcopy` | gRPC `setClipboard` |
| Device frame | DeviceKit chrome from Xcode | Android Studio's `device-art-resources` when installed, else the bare screen with rounded corners |
| Reconnect to a running app | `simctl spawn launchctl list` + `log show` for the VM service URL | `adb shell pidof <applicationId>`, then `flutter attach -d <serial> --app-id <id>` (Flutter reads the URL from logcat itself) |
| Foreground / terminate | `simctl launch` / `terminate` | `adb shell monkey -p <id> 1` / `adb shell am force-stop <id>` |
| App ID | `PRODUCT_BUNDLE_IDENTIFIER` in the pbxproj | `applicationId` in `android/app/build.gradle(.kts)` |
| Flavors | Xcode schemes (`FlavorValidator`) | `productFlavors` in Gradle (the project check already mentions it) |
| Run failures | Xcode error headings (`FlutterOutput`, `RunFailure`) | Gradle's `FAILURE: Build failed`, `* What went wrong:`, Kotlin `e: file:///…` |
| New Project | refuses a project without iOS | needs iOS **or** Android |

The emulator's `sendKey` takes `codeType: Usb` with HID usages as well, so `KeyboardMap` is reused for `ms-sim type`.
Its `text` field types a whole string in one call, which is the faster path when it works in Flutter text fields.

---

## 2. Shape: one device model, two backends

Keep the layering. `SimulatorModel` becomes `DeviceModel` (still `Workspace.simulator` → renamed `Workspace.device`),
and the per-platform work moves behind two small seams:

```
Views/SimulatorView      draws any DeviceScreen, unchanged apart from Back and the frame
DeviceModel              list, selection, boot/shutdown, stream, agent commands: platform-neutral
  ├─ SimctlService       + MSSimulatorDisplay      (iOS, as today)
  └─ EmulatorService     + EmulatorDisplay         (Android, new: Android/)
```

- **`Device`** (value, replaces `SimulatorDevice`): `id`, `name`, `platform` (`.ios` / `.android`), `osVersion`
  ("iOS 26.5", "Android 16"), `state`, and `runID` (the udid, or the adb serial once an emulator is running; nil when
  it isn't). The toolbar menu groups by platform, then OS version.
- **`DeviceScreen`** (protocol, `Sendable`): `frameHandler`, `latestFrame: IOSurface?`, `pixelSize`,
  `framesDelivered`, `inputAvailable`, `sendTouch(_:at:)`, `sendKeyEvent(_:)`, `pressKey(_:shift:)`, `type(_:)`,
  `press(_ button: .home | .back)`, `stop()`. `MSSimulatorDisplay` conforms through an extension; nothing in the
  Objective-C file changes.
- **`DeviceService`** (protocol over `SimctlService` and `EmulatorService`): `devices()`, `boot`, `shutdown`,
  `setAppearance` / `appearance`, `setTextSize` / `textSize`, `setClipboard`, `screen(for:)`. Text sizes are a
  per-platform list of (id, name), so the menu stays one menu.
- **Selection** is saved as `device.selected.v2` = platform + id (the v1 key holds a bare udid; read it once as iOS).
- **First choice** when nothing is saved: a running device, else the first iPhone, else the first Android emulator.
  That is the "iOS first when it's there" rule.
- `RunningAppFinder` gets an Android branch keyed on `Device.platform`; `Workspace.runApp()` passes `runID`.

This is a refactor first (phase 1) so iOS is proven unchanged before any Android code lands.

---

## 3. The emulator screen

`EmulatorDisplay` (`Android/`, a process-wrapper-style class: `@unchecked Sendable`, state behind a lock, with the
comment saying why) owns one gRPC channel to one emulator.

- **Finding it.** A running emulator writes `~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini` with
  `grpc.port` and, when started with `-grpc-use-token`, `grpc.token`, sent as `authorization: Bearer <token>`. An
  emulator started by Android Studio (JWT auth, or no gRPC) is shown as "Started outside AppFast Studio: shut it down
  and boot it from here", rather than half-working. The parsing is a pure, tested value (`EmulatorDiscovery`).
- **Frames.** `streamScreenshot(ImageFormat{format: RGBA8888})` streams each new frame. Each one is copied into an
  `IOSurface` from a small pool, so `ScreenView`, the Point at… thumbnail, `capturePNG()` and `ms-sim screenshot`
  all keep working unchanged. Phase 0 measures the frame rate; if plain messages don't reach about 30 fps at phone size,
  switch to the `MMAP` transport (the emulator writes into a shared file and the stream carries only metadata), which is
  what Android Studio uses.
- **Touch.** `sendTouch` with one `Touch{x, y, identifier: 0, pressure}` in device pixels: pressure > 0 for began and
  moved, 0 for ended. The view's normalized point times `pixelSize`.
- **Keys.** Mac keyboard: `KeyboardEvent{codeType: Mac, keyCode: event.keyCode, eventType: keydown|keyup}`.
  `pressKey(usage:)`: `codeType: Usb`. `type(text)`: `eventType: keypress, text`, falling back to per-key presses when
  phase 0 shows Flutter's text fields drop it.
- **Errors.** Every failure becomes a thrown error with a readable message; the model turns it into
  `.failed(...)` as today. Nothing crashes if the emulator dies mid-stream: the stream ending means "detach".

**Dependency.** gRPC over plain HTTP/2 needs a client library; URLSession only speaks HTTP/2 over TLS. Use
**grpc-swift 2** (`grpc-swift-2`, `grpc-swift-nio-transport`, `grpc-swift-protobuf`, `swift-protobuf`) as the project's
first Swift packages, in `project.yml`. It is Swift 6 native (async streams, `Sendable`), which suits the strict
concurrency rule, and it needs **macOS 15**, so the minimum goes up from 14 to 15 (decided): `project.yml`'s
`deploymentTarget`, AGENTS.md's "macOS 14+", and the macOS 14 notes in AGENTS.md re-checked (the flow map's `NSEvent`
monitor can stay; it isn't required to change). Check in the generated code for `emulator_controller.proto` (only the
calls above), with the script that regenerates it (`scripts/update-emulator-proto.sh`, reading the proto from the
installed SDK).

---

## 4. Booting and keeping emulators

- `EmulatorService.boot(avd:)` picks a free gRPC port (8554 upwards), starts the emulator **detached** (its own
  process group, output to `emulator.log`), so it outlives AppFast Studio like a simulator does, and the next launch
  finds it through the discovery file. `-no-window` because the app draws the screen; `-no-boot-anim` for speed;
  snapshots on (the default), so the second boot takes seconds.
- **Quitting asks** (decided). When AppFast Studio quits with an emulator it booted still running,
  `applicationShouldTerminate` asks: "Pixel 10 Pro is still running. Keep it running for next time?" with
  **Keep Running** / **Shut Down** and "Don't ask again". The answer is saved (`android.quitChoice.v1`: ask / keep /
  shutDown) and can be changed in Settings. Shut Down sends `adb emu kill` to each one and waits up to 10 s before the
  app quits. Emulators started outside AppFast Studio are never touched.
- Boot finishes when `adb -s <serial> shell getprop sys.boot_completed` prints 1 (polled, 4-minute timeout,
  phase `.booting` meanwhile). A cold first boot takes 1–2 minutes; the activity line says so.
- `adb` is the SDK's `platform-tools/adb`, never one from PATH, so versions match. The SDK is found from
  `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `flutter config`'s `android-sdk`, then `~/Library/Android/sdk`
  (`AndroidSDK.locate`, pure apart from file checks, and tested).
- The agent's shell gets `ANDROID_HOME` and `platform-tools` on PATH through `ClaudeAccess.agentProcess`, so Claude's
  `flutter` commands see the same SDK.

---

## 5. Everything else that names iOS

- **Workspace:** `runBlocker` says "Boot Pixel 10 Pro first." / "No devices are installed."; the activity line says
  "Building for Android… the first build downloads Gradle and takes a few minutes" on a project's first Android run.
- **Run failures:** teach `FlutterOutput` / `RunFailure` Gradle's and Kotlin's error shapes, with tests from real logs
  (a missing SDK licence, a minSdk clash, a Kotlin compile error), so *Fix with Claude* gets the right excerpt.
- **Prompts:** the chat and Fix system prompts say "the device" and name the platform (`ChatModel`, `FixModel`,
  `ClaudeAccess`). `ms-sim`'s answers say "the emulator" or "the simulator" as fits, and its help lists `back`.
- **Flavors:** `FlavorValidator` also reads `productFlavors` from Gradle; a flavor missing on the selected platform
  shows as a project issue.
- **New Project:** `NewProjectRequest.validate()` needs iOS or Android rather than iOS; Android stays on by default.
- **Snapshots:** the `sim:/…` steps and `MOBILE_STUDIO_SNAPSHOT_RUN` work on whatever device is selected; add
  `-device.selected.v2 android:<avd>` as a launch argument for Android runs.

---

## 6. Installing it (last phase)

New checklist rows, in the same `SetupPlan` / `SetupInstaller` shape, no password and no Apple ID:

| Row | How |
|---|---|
| Git (Command Line Tools) | only when there's no Xcode: Apple's Command Line Tools through `softwareupdate`, as Homebrew does (one password). Flutter needs git; this replaces "Set up Xcode first" for Flutter |
| Java | a Temurin 21 JDK `.tar.gz` from Adoptium's API (checksum published), unpacked to `~/development/jdk`; `flutter config --jdk-dir` |
| Android SDK | the command-line tools zip from Google (checksum on its download page) to `~/Library/Android/sdk`, then `sdkmanager` for `platform-tools`, `emulator`, the newest `platforms;android-N` and `build-tools`; `flutter config --android-sdk` |
| Android Emulator | `system-images;android-N;google_apis;arm64-v8a` (or `x86_64` on Intel), then `avdmanager create avd` for a Pixel: **Pixel 10 Pro** when `avdmanager list device -c` lists `pixel_10_pro`, else **Pixel 9** (`SetupPlan.preferredPixel`, pure and tested) |

SDK licences are shown to the user in a sheet and accepted only on their click (`sdkmanager --licenses` with their
answer), not silently. **Set Up Everything** takes the Android path when Xcode isn't ready, and the Xcode and iOS
Simulator rows become optional ("Also build for iPhone"). With Xcode already set up, iOS stays the default as now.
About 4 GB in all.

---

## Phases

Each phase builds with zero warnings, passes the tests, and leaves iOS working.

0. **Spike (throwaway, ~1 day).** On this Mac: raise the minimum to macOS 15 (build and tests clean), create a Pixel AVD, boot it headless with a gRPC token, and from a test
   harness stream frames, tap, type and press Home with grpc-swift 2. Answers: frame rate with and without MMAP, whether
   `keypress` text reaches a Flutter `TextField`, whether grpc-swift 2 compiles cleanly as a package dependency under
   Swift 6, and the discovery file's exact keys on emulator 37.
1. **Device abstraction (refactor, iOS only).** `Device`, `DeviceScreen`, `DeviceService`, `DeviceModel`; toolbar
   grouped by platform; v1 → v2 selection key. Snapshot the canvas and menu before and after: they must match.
2. **Emulator service.** SDK lookup, AVD list, running emulators, boot / shutdown, the quit question, dark mode, font scale. Android
   devices appear in the menu and boot, with no screen yet ("Booted. The screen arrives in the next phase").
3. **Emulator screen.** `EmulatorDisplay`: frames, touch, Mac keyboard, Home and Back. The canvas and Point at… work.
4. **The rest of the actions.** Run / Reconnect / terminate on Android, `ms-sim` (all commands, plus `back`), Design's
   capture, Gradle run failures and Fix, Gradle flavors, prompts, New Project's platform rule.
5. **Device frame.** Android Studio's device art when present; bare rounded screen otherwise.
6. **Setup rows.** Section 6, with `SetupFake` states for snapshots.
7. **Docs.** AGENTS.md: the Android pieces, the gRPC rule, the snapshot launch argument.

## Tests (pure layer)

`EmulatorDiscovery` (ini parsing), `AndroidSDK.locate`, AVD ini parsing, `adb devices` parsing, the boot-completed
check, Android `RunningAppFinder` parsing (applicationId from Groovy and Kotlin Gradle files, `pidof`), Gradle flavor
parsing, Gradle and Kotlin `RunFailure` excerpts, the device-selection migration, the first-choice rule, touch
coordinate mapping, and the setup plan's Android rules. No test needs an emulator, adb or the network.

## Decided (2026-11-06)

1. **macOS 15 minimum**, for grpc-swift 2 (section 3).
2. **Quitting asks** whether to keep the emulators the app booted running, with "Don't ask again" (section 4).
3. **Pixel 10 Pro** when the SDK's device list has it, else **Pixel 9**; newest Android, Google APIs image (section 6).
4. **Bare rounded screen** when Android Studio's device art isn't installed (phase 5).

## Phase 0 results (2026-11-06, partial)

- **macOS 15 minimum:** `project.yml` and `LSMinimumSystemVersion` raised; build and all tests clean.
- **grpc-swift 2 under Swift 6:** a scratch package with `grpc-swift-2`, `grpc-swift-nio-transport`, `grpc-swift-protobuf` and
  `swift-protobuf` (tools 6.0, macOS 15) builds with zero warnings.
- **Proto source:** `emulator_controller.proto` is installed with the emulator, at `~/Library/Android/sdk/emulator/lib/`
  (emulator 37.1.11.0), so `scripts/update-emulator-proto.sh` can read it from there.
- **Setup on this Mac:** `cmdline-tools` 23 (arm64, SHA-1 checked against Google's repository XML) and
  `system-images;android-36;google_apis;arm64-v8a` installed into `~/Library/Android/sdk`; AVD `ms_spike` (Pixel 9). `sdkmanager`
  in cmdline-tools 23 is now a shim that downloads the new Android CLI on first run, and it needs a JDK (Android Studio's `jbr` works).
  Homebrew has `protobuf` and `swift-protobuf` but no grpc-swift-2 plugin: build `protoc-gen-grpc-swift-2` from the package.
- **Discovery file** (`~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini`, emulator 37.1.11): `grpc.port`, `grpc.token`
  (with `-grpc-use-token`), `port.serial`, `port.adb`, `avd.name`, `avd.id`, `avd.dir`, `cmdline`, `emulator.version`. Auth is
  `authorization: Bearer <token>`. Headless boot to `sys.boot_completed` took about 27 s cold.
- **Frames (debug build, loopback, screen scrolling at about 60 Hz of touches):** plain RGBA8888 at 1080x2424 gave 242 frames in
  6 s (about 40 fps, about 10 MB each); at 540x1212 305 frames (about 51 fps); `MMAP` transport 335 frames (about 56 fps) with
  empty payloads. A static screen sends one frame, then nothing. So plain messages clear the 30 fps bar; MMAP is not needed
  unless a release build disappoints.
- **Gotcha:** one frame is bigger than grpc-swift's 4 MiB default, and `GRPCNIOTransportCore` applies
  `CallOptions.maxRequestMessageBytes` (not only `maxResponseMessageBytes`) when decoding a stream's responses, so set both (64 MiB
  worked), or ask for a smaller `ImageFormat.width/height`.
- **Touch:** `sendTouch` calls took about 1.2 ms each (20 in 23 ms) and scrolled Settings, so they are fast enough for drags.
- **Grpc-swift 2 under Swift 6:** the generated client compiles with `Visibility=Internal`, `Client=true`, `Server=false`. A
  top-level `main.swift` needs the work in a `nonisolated`/`@concurrent` function and a `sending`-safe capture of mutable values.
- **Still open:** whether `sendKey` `keypress` `text`, or per-key USB usages, reach a Flutter `TextField`. A test against a
  system dialog's field was inconclusive (neither changed it, while `adb shell input text` did), so retest with a Flutter app
  in phase 3 before relying on either. Throwaway harness: `grpcspike/` in the session scratchpad; not in the repo.

## Phase 2 results (2026-11-06)

`EmulatorService`, the pure parsers, the quit question and its Settings picker are in (`MobileStudio/Android/`). Checked against the
real `ms_spike` AVD with a throwaway live test: list, boot from snapshot (6 s), dark mode, font scale 1.3, shut down, and the
booted-by-app registry clearing itself. 270 tests pass with no warnings. The AVD and system image remain installed.
