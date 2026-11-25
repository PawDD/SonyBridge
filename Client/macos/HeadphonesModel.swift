//
//  HeadphonesModel.swift
//  Observable view model wrapping the Obj-C++ HeadphonesBridge for SwiftUI.
//

import Foundation
import Combine

private let keepSpeakToChatOffKey = "KeepSpeakToChatOffOnConnect"

struct PairedDeviceInfo: Identifiable, Equatable {
    let name: String
    let address: String
    let slot: Int              // 0 = paired only, 1/2 = connected
    let classOfDevice: Int     // -1 if not reported
    let playback: Bool
    let isThisMac: Bool

    var id: String { address }
    var connected: Bool { slot != 0 }
}

final class HeadphonesModel: ObservableObject {
    // One connection per app: the window and the menu-bar item drive the same model.
    static let shared = HeadphonesModel()

    private let bridge = HeadphonesBridge()

    @Published var connected = false
    @Published var connecting = false
    @Published var deviceName = ""
    @Published var supportsVpt = false
    @Published var maxAmbientLevel = 20

    @Published var mode: SHCAmbientMode = .off
    @Published var ambientLevel = 10
    @Published var hasWindNoiseReduction = false
    @Published var windNoiseReduction = false
    @Published var focusOnVoice = false
    @Published var focusOnVoiceAvailable = false

    @Published var batteryLevel = -1
    @Published var batteryCharging = false
    @Published var hasDualBattery = false
    @Published var batteryLeft = -1
    @Published var batteryRight = -1
    @Published var batteryCase = -1
    @Published var batteryLeftCharging = false
    @Published var batteryRightCharging = false
    @Published var batteryCaseCharging = false
    @Published var eqPreset = 0
    @Published var supportsEqualizer = false
    @Published var eqBands = [0, 0, 0, 0, 0]
    @Published var tenBandEqualizer = false
    @Published var equalizerPresets: [EQPresetOption] = []

    var availableEqualizerPresets: [EQPresetOption] {
        equalizerPresets.isEmpty
            ? EQPresets.options(reported: [], tenBand: tenBandEqualizer)
            : equalizerPresets
    }

    @Published var clearBass = 0
    @Published var supportsDsee = false
    @Published var dsee = false
    @Published var dseeBusy = false

    @Published var hasAutoPowerOff = false
    @Published var autoPowerOff = 0
    @Published var firmware = ""
    @Published var codec = ""
    @Published var hasConnectionQuality = false
    @Published var connectionQuality = 0
    @Published var refreshingConnectionInfo = false
    private var connectionInfoGeneration = 0
    @Published var hasSpeakToChat = false
    @Published var speakToChat = false
    @Published var hasSpeakToChatTiming = false
    @Published var speakToChatTimeout = 0
    @Published var speakToChatTimeoutSeconds: [Int] = []
    @Published var speakToChatTimingBusy = false
    // Force Speak-to-Chat off each time we connect (it pauses audio whenever it hears
    // speech, which is hostile to dictation). Flipping this takes effect next connect.
    @Published var keepSpeakToChatOff = UserDefaults.standard.object(forKey: keepSpeakToChatOffKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepSpeakToChatOff, forKey: keepSpeakToChatOffKey) }
    }
    @Published var hasAdaptiveVolume = false
    @Published var adaptiveVolume = false
    @Published var deviceMac = ""
    @Published var protocolVersion = ""

    @Published var hasPairedDevices = false
    @Published var pairedDevices: [PairedDeviceInfo] = []
    @Published var hasPlaybackPinState = false
    @Published var playbackPinned = false
    // Multipoint ("Connect to 2 devices"). Device-persistent - no app-enforced default; the
    // toggle just mirrors the on-device state.
    @Published var hasMultipointSetting = false
    @Published var canSetMultipoint = false
    @Published var multipointRequiresReconnect = false
    @Published var multipointEnabled = false
    @Published var multipointDiagnostics = ""
    private static let multipointAttemptURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SonyBridge", isDirectory: true)
            .appendingPathComponent("last-multipoint-attempt.txt")
    }()
    @Published private(set) var lastMultipointAttempt =
        (try? String(contentsOf: HeadphonesModel.multipointAttemptURL, encoding: .utf8)) ?? ""

    var diagnosticsToCopy: String {
        [lastMultipointAttempt, multipointDiagnostics].filter { !$0.isEmpty }.joined(separator: "\nCurrent session:\n")
    }

    private func saveMultipointAttempt(expected: Bool, error: String?) {
        lastMultipointAttempt = "\(Date().ISO8601Format()) · requested multipoint: \(expected)\n"
            + "\(deviceName) · fw \(firmware) · \(protocolVersion)\n"
            + bridge.multipointDiagnostics + "\nResult: \(error ?? "confirmation acknowledged")\n"
        do {
            let url = Self.multipointAttemptURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try lastMultipointAttempt.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("SonyBridge: could not save local multipoint diagnostics: %@", error.localizedDescription)
        }
    }
    @Published var refreshingMultipoint = false
    @Published var multipointBusy = false

    // True from connect until the first multipoint read has finished. Discovery can take several seconds.
    var multipointLoading: Bool {
        connected && protocolVersion == "v2" && multipointDiagnostics.isEmpty
    }

    @Published var errorMessage: String?
    @Published var connectionNotice: String?

    private var multipointExpectedAfterReconnect: Bool?
    private var multipointReconnectWork: DispatchWorkItem?
    private var pollTimer: Timer?
    private var dynamicTimer: Timer?

    // Slider-drag coalescing (mirrors the ImGui in-flight gate in CrossPlatformGUI).
    // While an exchange is in flight, only the latest value is remembered; when the
    // exchange completes, at most one more send fires with that latest value. All
    // state is main-thread-confined (bridge completions arrive on the main queue).
    private var pushInFlight = false
    private var pendingPush: (mode: SHCAmbientMode, level: Int, focusVoice: Bool, wind: Bool)?
    private var eqInFlight = false
    private var pendingEqSelection: Int?
    @Published private(set) var equalizerSelecting = false
    private var pendingEq: (bass: Int, bands: [Int], preset: Int)?

    // Armed on each successful connect; consumed once Speak-to-Chat capability is
    // confirmed, so the off-on-connect enforcement fires at most once per connection.
    private var s2cAutoDisablePending = false

    func connect() {
        guard !connecting, !connected else { return }
        connectionInfoGeneration += 1
        let generation = connectionInfoGeneration
        connecting = true
        errorMessage = nil
        connectionNotice = nil
        // Defer so SwiftUI can render the "Connecting…" state before the modal picker blocks the main thread.
        DispatchQueue.main.async {
            self.bridge.scanAndConnect { ok, error in
                guard self.connectionInfoGeneration == generation else { return }
                self.connecting = false
                if ok {
                    self.s2cAutoDisablePending = true
                    self.syncFromBridge()
                    self.startWatchingConnection()
                    self.refreshStatus()
                    self.startDynamicPolling()
                } else if let error = error {
                    self.errorMessage = error
                }
            }
        }
    }

    func refreshStatus() {
        bridge.refreshStatus {
            if !self.pushInFlight { self.syncFromBridge() }
            self.syncBatteryFromBridge()
            self.eqPreset = self.bridge.eqPreset
            self.supportsEqualizer = self.bridge.supportsEqualizer
            self.clearBass = self.bridge.clearBass
            self.supportsDsee = self.bridge.supportsDsee
            self.dsee = self.bridge.dsee
            self.tenBandEqualizer = self.bridge.tenBandEqualizer
            self.equalizerPresets = EQPresets.options(
                reported: self.bridge.equalizerPresets.map { (code: $0.code, name: $0.name) },
                tenBand: self.tenBandEqualizer)

            self.eqBands = self.readEqBands()
            self.hasAutoPowerOff = self.bridge.hasAutoPowerOff
            self.autoPowerOff = self.bridge.autoPowerOff
            self.firmware = self.bridge.firmware ?? ""
            self.codec = self.bridge.codec ?? ""
            self.hasConnectionQuality = self.bridge.hasConnectionQuality
            self.connectionQuality = self.bridge.connectionQuality
            self.hasSpeakToChat = self.bridge.hasSpeakToChat
            self.speakToChat = self.bridge.speakToChat
            self.hasSpeakToChatTiming = self.bridge.hasSpeakToChatTiming
            self.speakToChatTimeout = self.bridge.speakToChatTimeout
            self.speakToChatTimeoutSeconds = self.bridge.speakToChatTimeoutSeconds.map { $0.intValue }
            self.hasAdaptiveVolume = self.bridge.hasAdaptiveVolume
            self.adaptiveVolume = self.bridge.adaptiveVolume
            self.syncMultipointFromBridge()
            if let expected = self.multipointExpectedAfterReconnect, !self.multipointDiagnostics.isEmpty {
                self.multipointExpectedAfterReconnect = nil
                if !self.hasMultipointSetting {
                    self.errorMessage = "Reconnected, but the multipoint setting could not be read back."
                } else if self.multipointEnabled != expected {
                    self.errorMessage = "The headset did not report the requested multipoint setting after reconnecting."
                }
            }
            // Speak-to-Chat capability is only confirmed by the probeCapabilities pass
            // (the second completion), so this stays armed until then and fires at most
            // once per connect. The device stays untouched unless it reports S2C on.
            if self.s2cAutoDisablePending && self.hasSpeakToChat {
                self.s2cAutoDisablePending = false
                if self.keepSpeakToChatOff && self.speakToChat {
                    self.setSpeakToChat(false)
                }
            }
        }
    }

    func refreshMultipoint() {
        refreshingMultipoint = true
        bridge.refreshMultipoint {
            self.refreshingMultipoint = false
            self.syncMultipointFromBridge()
        }
    }

    func switchPlayback(to device: PairedDeviceInfo, fix: Bool) {
        multipointBusy = true
        errorMessage = nil
        bridge.switchPlayback(toAddress: device.address, fix: fix) { ok, error in
            self.multipointBusy = false
            if !ok, let error = error { self.errorMessage = error }
            self.syncMultipointFromBridge()
        }
    }

    func setPlaybackPinned(_ pinned: Bool) {
        multipointBusy = true
        errorMessage = nil
        bridge.setPlaybackPinned(pinned) { ok, error in
            self.multipointBusy = false
            if !ok, let error = error { self.errorMessage = error }
            self.syncMultipointFromBridge()
        }
    }

    private func syncMultipointFromBridge() {
        hasPairedDevices = bridge.hasPairedDevices
        pairedDevices = bridge.pairedDevices.map {
            PairedDeviceInfo(name: $0.name, address: $0.address, slot: $0.slot,
                             classOfDevice: $0.classOfDevice, playback: $0.playback, isThisMac: $0.isThisMac)
        }
        hasPlaybackPinState = bridge.hasPlaybackPinState
        playbackPinned = bridge.playbackPinned
        hasMultipointSetting = bridge.hasMultipointSetting
        canSetMultipoint = bridge.canSetMultipoint
        multipointRequiresReconnect = bridge.multipointRequiresReconnect
        multipointEnabled = bridge.multipointEnabled
        multipointDiagnostics = bridge.multipointDiagnostics
    }

    private func readEqBands() -> [Int] {
        (0..<bridge.equalizerBandCount).map { bridge.equalizerBand(at: $0) }
    }

    private func syncBatteryFromBridge() {
        assignIfChanged(\.batteryLevel, bridge.batteryLevel)
        assignIfChanged(\.batteryCharging, bridge.batteryCharging)
        assignIfChanged(\.hasDualBattery, bridge.hasDualBattery)
        assignIfChanged(\.batteryLeft, bridge.batteryLeft)
        assignIfChanged(\.batteryRight, bridge.batteryRight)
        assignIfChanged(\.batteryCase, bridge.batteryCase)
        assignIfChanged(\.batteryLeftCharging, bridge.batteryLeftCharging)
        assignIfChanged(\.batteryRightCharging, bridge.batteryRightCharging)
        assignIfChanged(\.batteryCaseCharging, bridge.batteryCaseCharging)
    }

    func setAutoPowerOff(_ index: Int) {
        autoPowerOff = index
        errorMessage = nil
        bridge.setAutoPowerOff(index) { ok, error in if !ok, let e = error { self.errorMessage = e } }
    }

    func setSpeakToChat(_ on: Bool) {
        speakToChat = on
        errorMessage = nil
        bridge.setSpeakToChat(on) { ok, error in if !ok, let e = error { self.errorMessage = e } }
    }

    func refreshConnectionInfo() {
        guard connected, !refreshingConnectionInfo else { return }
        refreshingConnectionInfo = true
        let generation = connectionInfoGeneration
        bridge.refreshConnectionInfo { ok, error in
            self.refreshingConnectionInfo = false
            guard self.connected, self.connectionInfoGeneration == generation else { return }
            self.connectionQuality = self.bridge.connectionQuality
            self.codec = self.bridge.codec ?? ""
            if !ok, let error = error { self.errorMessage = error }
        }
    }

    func setSpeakToChatTimeout(_ option: Int) {
        guard connected, hasSpeakToChatTiming, !speakToChatTimingBusy else { return }
        speakToChatTimingBusy = true
        errorMessage = nil
        bridge.setSpeakToChatTimeout(option) { ok, error in
            self.speakToChatTimingBusy = false
            self.speakToChatTimeout = self.bridge.speakToChatTimeout
            if !ok, let error = error { self.errorMessage = error }
        }
    }

    func setAdaptiveVolume(_ on: Bool) {
        adaptiveVolume = on
        errorMessage = nil
        bridge.setAdaptiveVolume(on) { ok, error in if !ok, let e = error { self.errorMessage = e } }
    }

    func setMultipoint(_ on: Bool) {
        guard connected, canSetMultipoint, !multipointBusy, on != multipointEnabled else { return }
        let needsReconnect = bridge.multipointRequiresReconnect
        let address = deviceMac
        multipointBusy = true
        stopDynamicPolling()
        stopWatchingConnection()
        errorMessage = nil
        bridge.setMultipoint(on) { ok, error in
            self.saveMultipointAttempt(expected: on, error: ok ? nil : (error ?? "Change not confirmed"))
            if needsReconnect {
                // A restarting headset can close before the confirmation ACK arrives.
                // Recover by reading the new session, never by resending the setting.
                if ok || self.bridge.multipointConfirmationAttempted {
                    self.reconnectAfterMultipointChange(address: address, expected: on)
                } else {
                    self.disconnect()
                    self.errorMessage = "Multipoint change could not be confirmed. The control session was closed and no retry was sent. \(error ?? "Reconnect to inspect the headset state.")"
                }
                return
            }
            self.multipointBusy = false
            if self.bridge.connected {
                self.syncMultipointFromBridge()
                self.startWatchingConnection()
                self.startDynamicPolling()
            } else {
                self.disconnect()
            }
            if !ok {
                self.errorMessage = "Multipoint change could not be confirmed. No retry was sent. \(error ?? "Reconnect to read the headset state.")"
            }
        }
    }

    private func reconnectAfterMultipointChange(address: String, expected: Bool) {
        disconnect()
        connecting = true
        multipointBusy = true
        let generation = connectionInfoGeneration
        // Allow the headset to restart before one reconnect attempt. Never resend the setting
        // or select a different headset during recovery.
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.connectionInfoGeneration == generation else { return }
            self.bridge.reconnect(toAddress: address) { ok, error in
                guard self.connectionInfoGeneration == generation else { return }
                self.connecting = false
                self.multipointBusy = false
                self.multipointReconnectWork = nil
                if ok {
                    self.multipointExpectedAfterReconnect = expected
                    self.s2cAutoDisablePending = true
                    self.syncFromBridge()
                    self.startWatchingConnection()
                    self.refreshStatus()
                    self.startDynamicPolling()
                } else {
                    self.errorMessage = "The headset did not reconnect after changing multipoint. \(error ?? "Press Connect to try connecting again.")"
                }
            }
        }
        multipointReconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    // Every @Published setter fires objectWillChange — and a full ContentView body
    // re-evaluation — even when the value is unchanged. The 2s poll mostly re-reads
    // cached bridge values, so gate writes to real changes.
    private func assignIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<HeadphonesModel, T>, _ newValue: T) {
        if self[keyPath: keyPath] != newValue {
            self[keyPath: keyPath] = newValue
        }
    }

    // Poll the button-changeable state so the app stays in sync when you use the headphone's own controls.
    private func startDynamicPolling() {
        stopDynamicPolling()
        var tick = 0
        dynamicTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.connected else { return }
            // Every 5th tick (10 s), also re-read which device has playback, so the menu-bar icon follows
            // changes made from the phone. Skipped while a multipoint write or refresh is in flight.
            tick += 1
            if tick % 5 == 0 && self.hasPairedDevices && !self.multipointBusy && !self.refreshingMultipoint {
                self.bridge.refreshMultipoint { self.syncMultipointFromBridge() }
            }
            self.bridge.refreshDynamic {
                // Only publish what refreshDynamic actually re-read: ambient/NC state and the battery.
                // EQ and DSEE aren't re-read on this path - they'd come straight back from the C++ cache,
                // so a failed write would snap back two seconds later and an EQ drag would fight the timer.
                if !self.pushInFlight {
                    self.assignIfChanged(\.mode, self.bridge.mode)
                    self.assignIfChanged(\.hasWindNoiseReduction, self.bridge.hasWindNoiseReduction)
                    self.assignIfChanged(\.windNoiseReduction, self.bridge.windNoiseReduction)
                }
                let level = self.bridge.ambientLevel
                if level > 0 { self.assignIfChanged(\.ambientLevel, level) }
                self.syncBatteryFromBridge()
            }
        }
    }

    private func stopDynamicPolling() {
        dynamicTimer?.invalidate()
        dynamicTimer = nil
    }

    // The controls below update optimistically and are corrected here if the write failed, rather than
    // being silently overwritten by the next poll tick.
    func setEqualizer(_ preset: Int) {
        guard !equalizerSelecting else { return }
        if eqInFlight {
            pendingEqSelection = preset
            return
        }
        if preset == 0xA0 {
            eqPreset = 0xA0
            applyCustomEq()
            return
        }
        eqPreset = preset
        errorMessage = nil
        equalizerSelecting = true
        bridge.setEqualizerPreset(preset) { ok, error in
            self.equalizerSelecting = false
            if !ok {
                self.eqPreset = self.bridge.eqPreset
                if let error = error { self.errorMessage = error }
                return
            }
            // The bridge re-reads the EQ after the write, so this picks up the band values that belong to
            // the preset just selected - in particular the custom curve the device restores for Manual,
            // which is what the sliders below the chips show.
            self.eqPreset = self.bridge.eqPreset
            self.clearBass = self.bridge.clearBass
            self.eqBands = self.readEqBands()
        }
    }

    // Editable EQ: retain Manual / Custom 1 / Custom 2 while coalescing slider writes.
    func applyCustomEq() {
        guard !equalizerSelecting else { return }
        if !EQPresets.isEditable(eqPreset) { eqPreset = 0xA0 }
        errorMessage = nil
        if eqInFlight {
            pendingEq = (clearBass, eqBands, eqPreset)
            return
        }
        sendCustomEq((clearBass, eqBands, eqPreset))
    }

    private func sendCustomEq(_ sent: (bass: Int, bands: [Int], preset: Int)) {
        eqInFlight = true
        bridge.setCustomEqualizerBass(sent.bass, bands: sent.bands.map { NSNumber(value: $0) }, preset: sent.preset) { ok, error in
            self.eqInFlight = false
            if let pending = self.pendingEq {
                self.pendingEq = nil
                if pending != sent {
                    self.sendCustomEq(pending)
                    return
                }
            }
            self.assignIfChanged(\.eqPreset, self.bridge.eqPreset)
            self.assignIfChanged(\.clearBass, self.bridge.clearBass)
            self.assignIfChanged(\.eqBands, self.readEqBands())
            if !ok, let error = error { self.errorMessage = error }
            if let next = self.pendingEqSelection {
                self.pendingEqSelection = nil
                self.setEqualizer(next)
            }
        }
    }

    func setDsee(_ on: Bool) {
        guard connected, supportsDsee, !dseeBusy else { return }
        dseeBusy = true
        dsee = on
        errorMessage = nil
        bridge.setDsee(on) { ok, error in
            self.dseeBusy = false
            self.dsee = self.bridge.dsee
            if !ok {
                if let error = error { self.errorMessage = error }
            }
        }
    }

    func releaseControlToPhone() {
        disconnect()
        errorMessage = nil
        connectionNotice = "Control released. You can now open Sound Connect on your phone."
    }

    func disconnect() {
        connectionNotice = nil
        multipointReconnectWork?.cancel()
        multipointReconnectWork = nil
        multipointExpectedAfterReconnect = nil
        connecting = false
        multipointBusy = false
        connectionInfoGeneration += 1
        stopWatchingConnection()
        stopDynamicPolling()
        pendingPush = nil
        pendingEq = nil
        pendingEqSelection = nil
        s2cAutoDisablePending = false
        bridge.disconnect()
        connected = false
        deviceName = ""
        syncMultipointFromBridge()
    }

    // The headset can drop the RFCOMM link on its own (idle power-save). Poll so the UI reflects reality
    // instead of showing a stale "Connected" state.
    private func startWatchingConnection() {
        stopWatchingConnection()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.connected && !self.bridge.connected {
                self.connected = false
                self.deviceName = ""
                if self.multipointBusy {
                    self.connectionNotice = nil
                    self.errorMessage = "The headset closed the connection while changing multipoint. Press Connect to read its current setting."
                } else if self.bridge.systemBluetoothConnected {
                    self.errorMessage = nil
                    self.connectionNotice = "Control connection closed. To use SonyBridge, close Sound Connect on your phone and reconnect."
                } else {
                    self.errorMessage = nil
                    self.connectionNotice = "Bluetooth disconnected. If the headset is off, turn it on and reconnect."
                }
                self.stopWatchingConnection()
                self.stopDynamicPolling()
                // Release the dead session too, so a reconnect starts clean and the device list doesn't
                // linger with Fix/Switch enabled.
                self.bridge.disconnect()
                self.syncMultipointFromBridge()
            }
        }
    }

    private func stopWatchingConnection() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func setMode(_ newMode: SHCAmbientMode) {
        mode = newMode
        pushState()
    }

    func setLevel(_ level: Int) {
        ambientLevel = level
        if mode == .ambientSound { pushState() }
    }

    func setWindNoiseReduction(_ on: Bool) {
        windNoiseReduction = on
        pushState()
    }

    func setFocusOnVoice(_ on: Bool) {
        focusOnVoice = on
        pushState()
    }

    private func pushState() {
        errorMessage = nil
        if pushInFlight {
            pendingPush = (mode, ambientLevel, focusOnVoice, windNoiseReduction)
            return
        }
        sendPush((mode, ambientLevel, focusOnVoice, windNoiseReduction))
    }

    private func sendPush(_ sent: (mode: SHCAmbientMode, level: Int, focusVoice: Bool, wind: Bool)) {
        pushInFlight = true
        bridge.applyMode(sent.mode, level: sent.level, focusVoice: sent.focusVoice, windReduction: sent.wind) { ok, error in
            self.pushInFlight = false
            if let pending = self.pendingPush {
                self.pendingPush = nil
                if pending != sent {
                    self.sendPush(pending)
                    return
                }
            }
            // Sync either way: on failure the bridge has rolled the pending change back, so this shows
            // what the headphones are actually set to instead of leaving the UI lying.
            self.syncFromBridge()
            if !ok, let error = error { self.errorMessage = error }
        }
    }

    private func syncFromBridge() {
        assignIfChanged(\.connected, bridge.connected)
        assignIfChanged(\.deviceName, bridge.deviceName ?? "")
        assignIfChanged(\.deviceMac, bridge.deviceMac ?? "")
        assignIfChanged(\.protocolVersion, bridge.protocolVersionString ?? "")
        assignIfChanged(\.supportsVpt, bridge.supportsVpt)
        assignIfChanged(\.supportsEqualizer, bridge.supportsEqualizer)
        assignIfChanged(\.supportsDsee, bridge.supportsDsee)
        assignIfChanged(\.maxAmbientLevel, bridge.maxAmbientLevel)
        assignIfChanged(\.mode, bridge.mode)
        let level = bridge.ambientLevel
        if level > 0 { assignIfChanged(\.ambientLevel, level) }
        assignIfChanged(\.hasWindNoiseReduction, bridge.hasWindNoiseReduction)
        assignIfChanged(\.windNoiseReduction, bridge.windNoiseReduction)
        assignIfChanged(\.focusOnVoice, bridge.focusOnVoice)
        assignIfChanged(\.focusOnVoiceAvailable, bridge.focusOnVoiceAvailable)
    }
}

// Playback-pin shortcuts shared by the menu-bar menu and the quick-controls panel.
extension HeadphonesModel {
    var thisMac: PairedDeviceInfo? {
        pairedDevices.first { $0.isThisMac && $0.connected }
    }

    var playbackPinnedToThisMac: Bool {
        playbackPinned && thisMac?.playback == true
    }

    var playbackDevice: PairedDeviceInfo? {
        connected ? pairedDevices.first { $0.playback } : nil
    }

    func pinPlaybackToThisMac() {
        if let thisMac = thisMac { switchPlayback(to: thisMac, fix: true) }
    }
}
