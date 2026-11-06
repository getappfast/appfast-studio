import Foundation
import Testing
@testable import AppFast_Studio

struct AndroidTests {
    @Test func sdkLocationFollowsTheToolsOrder() {
        let home = URL(fileURLWithPath: "/Users/me")
        let present: Set<String> = ["/a/platform-tools/adb", "/b/platform-tools/adb", "/flutter/platform-tools/adb", "/Users/me/Library/Android/sdk/platform-tools/adb"]
        func locate(_ env: [String: String], flutter: String? = nil) -> String? {
            let data = flutter.map { Data("{\"android-sdk\": \"\($0)\"}".utf8) }
            return AndroidSDK.locate(environment: env, flutterSettings: data, home: home, fileExists: present.contains)?.root.path
        }
        #expect(locate(["ANDROID_HOME": "/a", "ANDROID_SDK_ROOT": "/b"]) == "/a")
        #expect(locate(["ANDROID_HOME": "/missing", "ANDROID_SDK_ROOT": "/b"]) == "/b")
        #expect(locate([:], flutter: "/flutter") == "/flutter")
        #expect(locate([:]) == "/Users/me/Library/Android/sdk")
        #expect(AndroidSDK.locate(environment: [:], flutterSettings: nil, home: home, fileExists: { _ in false }) == nil)
    }

    @Test func avdConfigGivesNameVersionAndKind() {
        let phone = AVDInfo.parse(name: "Pixel_9", config: """
        avd.ini.displayname=Pixel 9
        image.sysdir.1=system-images/android-36.1/google_apis/arm64-v8a/
        tag.id=google_apis
        """)
        #expect(phone == AVDInfo(name: "Pixel_9", displayName: "Pixel 9", osVersion: "Android 36.1", isPhone: true))
        let ext = AVDInfo.parse(name: "x", config: "image.sysdir.1=system-images/android-36-ext18/google_apis/arm64-v8a/")
        #expect(ext.osVersion == "Android 36")
        #expect(ext.displayName == "x")
        #expect(AVDInfo.parse(name: "w", config: "tag.id=android-wear\nimage.sysdir.1=system-images/android-36/android-wear/arm64-v8a/").isPhone == false)
        #expect(AVDInfo.parse(name: "n", config: "").osVersion == "Android")
    }

    @Test func discoveryFileGivesSerialAndGrpc() {
        let text = """
        avd.name=ms_spike
        port.serial=5554
        port.adb=5555
        grpc.port=8554
        grpc.token=secret
        """
        let emulator = RunningEmulator.parse(text, fileName: "pid_15954.ini")
        #expect(emulator == RunningEmulator(avdName: "ms_spike", serial: "emulator-5554", pid: 15954, grpcPort: 8554, grpcToken: "secret"))
        #expect(RunningEmulator.parse("avd.name=x", fileName: "pid_1.ini") == nil)
        #expect(RunningEmulator.parse("port.serial=5554") == nil)
    }

    @Test func deadEmulatorsAreIgnored() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("avd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "avd.name=live\nport.serial=5554".write(to: dir.appendingPathComponent("pid_10.ini"), atomically: true, encoding: .utf8)
        try "avd.name=dead\nport.serial=5556".write(to: dir.appendingPathComponent("pid_20.ini"), atomically: true, encoding: .utf8)
        try "ignore".write(to: dir.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        let found = RunningEmulator.running(in: dir, isAlive: { $0 == 10 })
        #expect(found.map(\.avdName) == ["live"])
    }

    @Test func adbOutputParsers() {
        let devices = AdbOutput.emulators(in: "List of devices attached\nemulator-5554\tdevice\n0123ABCD\tdevice\nemulator-5556\toffline\n\n")
        #expect(devices.map(\.serial) == ["emulator-5554", "emulator-5556"])
        #expect(devices.map(\.state) == ["device", "offline"])
        #expect(AdbOutput.isBootCompleted("1\n"))
        #expect(!AdbOutput.isBootCompleted(""))
        #expect(AdbOutput.isNight("Night mode: yes\n") == true)
        #expect(AdbOutput.isNight("Night mode: no") == false)
        #expect(AdbOutput.isNight("Night mode: auto") == nil)
    }

    @Test func fontScaleMapsToTheNearestOption() {
        #expect(AndroidTextSize.optionID(for: "null\n") == "1.0")
        #expect(AndroidTextSize.optionID(for: "1.0") == "1.0")
        #expect(AndroidTextSize.optionID(for: "1.12") == "1.15")
        #expect(AndroidTextSize.optionID(for: "3") == "2.0")
    }

    @Test func quitChoiceOnlyActsOnEmulatorsWeStarted() {
        #expect(AndroidQuitChoice.ask.action(runningBootedByApp: 0) == .quit)
        #expect(AndroidQuitChoice.ask.action(runningBootedByApp: 1) == .askUser)
        #expect(AndroidQuitChoice.keep.action(runningBootedByApp: 2) == .quit)
        #expect(AndroidQuitChoice.shutDown.action(runningBootedByApp: 1) == .shutDownThenQuit)
    }

    @Test func freePortSkipsUsedOnes() {
        #expect(EmulatorService.freePort(from: 18554, avoiding: [18554, 18555]) >= 18556)
    }

    @Test func noSDKMeansNoAndroidDevices() async throws {
        let service = EmulatorService(sdkProvider: { nil })
        #expect(try await service.devices().isEmpty)
    }
}
