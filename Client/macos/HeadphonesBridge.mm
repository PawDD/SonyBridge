//
//  HeadphonesBridge.mm
//  Obj-C++ implementation owning the C++ core. Mirrors the connect/apply flow the old ViewController had.
//

#import "HeadphonesBridge.h"
#import <IOBluetoothUI/IOBluetoothUI.h>
#import <IOBluetooth/IOBluetooth.h>

#include <algorithm>
#include <atomic>
#include <memory>
#include "MacOSBluetoothConnector.h"
#include "BluetoothWrapper.h"
#include "Headphones.h"
#include "../WaitForDeviceState.h"
// RecoverableException comes in transitively via BluetoothWrapper.h -> IBluetoothConnector.h -> Exceptions.h.
// (Exceptions.h isn't a project file reference, so it can't be #included directly from this directory.)

// The dynamic poll fires every 2s; re-read the battery every 15th tick (~30s), which is far more often
// than a headphone battery meaningfully moves but cheap enough not to crowd out the ambient/NC polling.
static const unsigned kBatteryPollEveryNTicks = 15;

// Apply the new verification policy only to XM4C. Existing models retain their
// established write behaviour; reads stay on the serial command queue.
template <typename ReadAndMatch>
static void SHCWaitForAppliedState(Headphones* headphones, ReadAndMatch readAndMatch, const char* error) {
    if (headphones->requiresWriteReadback()) waitForDeviceState(readAndMatch, error);
}

@interface SHCPairedDevice ()
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) NSString *address;
@property (nonatomic, readwrite) NSInteger slot;
@property (nonatomic, readwrite) NSInteger classOfDevice;
@property (nonatomic, readwrite) BOOL playback;
@property (nonatomic, readwrite) BOOL isThisMac;
@end

@interface SHCEqualizerPreset ()
@property (nonatomic, readwrite) NSInteger code;
@property (nonatomic, copy, readwrite) NSString *name;
@end

@implementation SHCEqualizerPreset
@end

@implementation SHCPairedDevice
@end

// IOBluetooth formats addresses as "aa-bb-cc-dd-ee-ff"; the headset reports "AA:BB:CC:DD:EE:FF".
static NSString *SHCNormalizedAddress(NSString *address) {
    return [[address uppercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@":"];
}

@implementation HeadphonesBridge {
    MacOSBluetoothConnector *_macConnector; // owned by _bt
    std::unique_ptr<BluetoothWrapper> _bt;
    // Queued operations retain the current device state so disconnecting cannot invalidate a raw pointer
    // while a Bluetooth read or write is still completing.
    std::shared_ptr<Headphones> _hp;
    NSString *_deviceName;
    NSString *_deviceMac;
    NSString *_lastMultipointWriteDiagnostics;
    NSUInteger _connectionGeneration;
    std::atomic_bool _initialized;
    // Only touched inside blocks on _cmdQueue, which is serial.
    unsigned _dynamicTick;
    // All device I/O runs on this serial queue. Bluetooth commands are stateful, and serializing reads with
    // writes also prevents a slow capability probe from racing a user action or dynamic refresh.
    dispatch_queue_t _cmdQueue;
}

- (instancetype)init {
    if ((self = [super init])) {
        auto connector = std::make_unique<MacOSBluetoothConnector>();
        _macConnector = connector.get();
        _bt = std::make_unique<BluetoothWrapper>(std::move(connector));
        _initialized = false;
        _cmdQueue = dispatch_queue_create("com.sonybridge.commands", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)connected {
    return _bt && _bt->isConnected();
}

- (BOOL)systemBluetoothConnected {
    if (!_deviceMac.length) return NO;
    return [[IOBluetoothDevice deviceWithAddressString:_deviceMac] isConnected];
}

- (nullable NSString *)deviceName {
    return _deviceName;
}

- (nullable NSString *)deviceMac {
    return _deviceMac;
}

- (nullable NSString *)protocolVersionString {
    if (!self.connected) return nil;
    return _bt->getProtocolVersion() == SonyProtocolVersion::V2 ? @"v2" : @"v1";
}

- (BOOL)supportsVpt {
    if (!self.connected) return NO;
    return _bt->getProtocolVersion() == SonyProtocolVersion::V1;
}

- (NSInteger)maxAmbientLevel {
    return 20;
}

- (SHCAmbientMode)mode {
    if (!_hp) return SHCAmbientModeOff;
    if (!_hp->getAmbientSoundControl()) return SHCAmbientModeOff;
    return _hp->getAsmLevel() > 0 ? SHCAmbientModeAmbientSound : SHCAmbientModeNoiseCanceling;
}

- (NSInteger)ambientLevel {
    return _hp ? _hp->getAsmLevel() : 0;
}

- (BOOL)focusOnVoice {
    return _hp ? _hp->getFocusOnVoice() : NO;
}

- (BOOL)focusOnVoiceAvailable {
    return _hp ? _hp->isFocusOnVoiceAvailable() : NO;
}

- (NSInteger)batteryLevel {
    return _hp ? _hp->getBatteryLevel() : -1;
}

- (BOOL)batteryCharging {
    return _hp ? _hp->isBatteryCharging() : NO;
}

- (BOOL)hasDualBattery { return _hp && _hp->hasDualBattery(); }
- (NSInteger)batteryLeft { return _hp ? _hp->getBatteryLeft() : -1; }
- (NSInteger)batteryRight { return _hp ? _hp->getBatteryRight() : -1; }
- (NSInteger)batteryCase { return _hp ? _hp->getBatteryCase() : -1; }
- (BOOL)batteryLeftCharging { return _hp && _hp->isBatteryLeftCharging(); }
- (BOOL)batteryRightCharging { return _hp && _hp->isBatteryRightCharging(); }
- (BOOL)batteryCaseCharging { return _hp && _hp->isBatteryCaseCharging(); }

- (NSInteger)eqPreset {
    return _hp ? (NSInteger)_hp->getEqualizerPreset() : 0;
}

- (BOOL)supportsEqualizer {
    return _hp && _hp->hasEqualizer();
}

- (NSArray<SHCEqualizerPreset *> *)equalizerPresets {
    if (!_hp) return @[];
    NSMutableArray<SHCEqualizerPreset *> *presets = [NSMutableArray array];
    for (const auto &entry : _hp->getEqualizerPresets()) {
        SHCEqualizerPreset *preset = [SHCEqualizerPreset new];
        preset.code = entry.code;
        preset.name = [[NSString alloc] initWithBytes:entry.name.data() length:entry.name.size() encoding:NSUTF8StringEncoding] ?: @"";
        [presets addObject:preset];
    }
    return presets;
}

- (NSInteger)clearBass {
    return _hp ? _hp->getClearBass() : 0;
}

- (BOOL)dsee {
    return _hp ? _hp->getDsee() : NO;
}

- (BOOL)supportsDsee {
    return _hp && _hp->hasDsee();
}

- (NSInteger)equalizerBandCount {
    return _hp ? _hp->getEqualizerBandCount() : 5;
}

- (BOOL)tenBandEqualizer {
    return _hp && _hp->isTenBandEqualizer();
}

- (NSInteger)equalizerBandAtIndex:(NSInteger)index {
    return _hp ? _hp->getEqualizerBand((int)index) : 0;
}

- (BOOL)hasAutoPowerOff { return _hp && _hp->hasAutoPowerOff(); }
- (NSInteger)autoPowerOff { return _hp ? _hp->getAutoPowerOff() : 0; }
- (BOOL)hasFirmware { return _hp && _hp->hasFirmware(); }
- (nullable NSString *)firmware { return _hp ? @(_hp->getFirmware().c_str()) : nil; }
- (BOOL)hasCodec { return _hp && _hp->hasCodec(); }
- (nullable NSString *)codec { return _hp ? @(_hp->getCodec().c_str()) : nil; }
- (BOOL)hasWindNoiseReduction { return _hp && _hp->hasWindNoiseReduction(); }
- (BOOL)windNoiseReduction { return _hp && _hp->getWindNoiseReduction(); }
- (BOOL)hasConnectionQuality { return _hp && _hp->hasConnectionQuality(); }
- (NSInteger)connectionQuality { return _hp ? _hp->getConnectionQuality() : 0; }
- (void)refreshConnectionInfoWithCompletion:(void (^)(BOOL, NSString * _Nullable))completion {
    auto hp = _hp;
    if (!hp || !self.connected) { completion(NO, @"Not connected."); return; }
    dispatch_async(_cmdQueue, ^{
        BOOL ok = YES; NSString *error = nil;
        try { hp->requestConnectionQuality(); }
        catch (const std::exception &exc) { ok = NO; error = @(exc.what()); }
        try { hp->requestCodec(); }
        catch (const std::exception &exc) { ok = NO; if (!error) error = @(exc.what()); }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, error); });
    });
}
- (BOOL)hasSpeakToChat { return _hp && _hp->hasSpeakToChat(); }
- (BOOL)speakToChat { return _hp && _hp->getSpeakToChat(); }
- (BOOL)hasSpeakToChatTiming { return _hp && _hp->hasSpeakToChatTiming(); }
- (NSInteger)speakToChatTimeout { return _hp ? _hp->getSpeakToChatTimeout() : 0; }
- (NSArray<NSNumber *> *)speakToChatTimeoutSeconds {
    NSMutableArray<NSNumber *> *times = [NSMutableArray array];
    if (_hp) for (int seconds : _hp->getSpeakToChatTimeoutSeconds()) [times addObject:@(seconds)];
    return times;
}
- (void)setSpeakToChatTimeout:(NSInteger)option completion:(void (^)(BOOL, NSString * _Nullable))completion {
    auto hp = _hp;
    if (!hp || !self.connected || !hp->hasSpeakToChatTiming()) {
        completion(NO, @"Speak-to-Chat timing is unavailable."); return;
    }
    dispatch_async(_cmdQueue, ^{
        BOOL ok = YES; NSString *error = nil;
        try {
            hp->setSpeakToChatTimeout((int)option);
            waitForDeviceState([&] {
                hp->requestSpeakToChatTiming();
                return hp->getSpeakToChatTimeout() == option;
            }, "The headphones did not apply the Speak-to-Chat timeout.");
        } catch (const std::exception &exc) { ok = NO; error = @(exc.what()); }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, error); });
    });
}
- (BOOL)hasAdaptiveVolume { return _hp && _hp->hasAdaptiveVolume(); }
- (BOOL)adaptiveVolume { return _hp && _hp->getAdaptiveVolume(); }

- (BOOL)hasPairedDevices { return _hp && _hp->hasPairedDevices(); }
- (BOOL)hasPlaybackPinState { return _hp && _hp->hasPlaybackPinState(); }
- (BOOL)playbackPinned { return _hp && _hp->isPlaybackPinned(); }
- (BOOL)hasMultipointSetting { return _hp && _hp->hasMultipointSetting(); }
- (BOOL)canSetMultipoint { return _hp && _hp->canSetMultipoint(); }
- (BOOL)multipointRequiresReconnect { return _hp && _hp->multipointRequiresReconnect(); }
- (BOOL)multipointConfirmationAttempted { return _hp && _hp->multipointConfirmationAttempted(); }
- (BOOL)multipointEnabled { return _hp && _hp->getMultipointEnabled(); }
- (NSString *)multipointDiagnostics {
    NSString *current = _hp ? @(_hp->getMultipointDiagnostics().c_str()) : @"";
    // Keep the loading sentinel empty until a fresh session has a read result.
    if (!current.length || !_lastMultipointWriteDiagnostics.length) return current;
    return [NSString stringWithFormat:@"Previous multipoint change (before reconnect):\n%@\nCurrent session:\n%@",
            _lastMultipointWriteDiagnostics, current];
}

- (NSArray<SHCPairedDevice *> *)pairedDevices {
    if (!_hp) return @[];
    NSString *hostAddress = SHCNormalizedAddress([[IOBluetoothHostController defaultController] addressAsString] ?: @"");
    NSMutableArray<SHCPairedDevice *> *result = [NSMutableArray array];
    for (const auto &device : _hp->getPairedDevices()) {
        SHCPairedDevice *item = [SHCPairedDevice new];
        // Names are UTF-8 as far as we know; fall back to Latin-1 so a bad byte can't drop the row.
        NSString *name = [[NSString alloc] initWithBytes:device.name.data() length:device.name.size() encoding:NSUTF8StringEncoding]
            ?: [[NSString alloc] initWithBytes:device.name.data() length:device.name.size() encoding:NSISOLatin1StringEncoding];
        item.name = name ?: @"";
        item.address = SHCNormalizedAddress(@(device.address.c_str()));
        item.slot = device.slot;
        item.classOfDevice = device.classOfDevice;
        item.playback = device.playback;
        item.isThisMac = hostAddress.length > 0 && [item.address isEqualToString:hostAddress];
        [result addObject:item];
    }
    return result;
}

static BOOL SHCLooksLikeSonyHeadset(NSString *name) {
    if (name.length == 0) return NO;
    NSArray<NSString *> *prefixes = @[@"WH-", @"WF-", @"WI-", @"MDR-", @"XB", @"LinkBuds", @"ULT"];
    for (NSString *p in prefixes) {
        if ([name hasPrefix:p] || [name containsString:p]) return YES;
    }
    return NO;
}

- (void)scanAndConnectWithCompletion:(void (^)(BOOL, NSString * _Nullable))completion {
    // Prefer the already system-connected Sony headset (Sony-app "My Device" behaviour) and skip the
    // native picker, which shows a confusing empty list when nothing is connected.
    IOBluetoothDevice *device = nil;
    for (IOBluetoothDevice *paired in [IOBluetoothDevice pairedDevices]) {
        if ([paired isConnected] && SHCLooksLikeSonyHeadset([paired name])) {
            device = paired;
            break;
        }
    }
    // BLE/audio-only headsets (e.g. ULT WEAR) report isConnected == NO; fall back to any paired Sony headset.
    if (!device) {
        for (IOBluetoothDevice *paired in [IOBluetoothDevice pairedDevices]) {
            if (SHCLooksLikeSonyHeadset([paired name])) {
                device = paired;
                break;
            }
        }
    }

    if (!device) {
        // Fall back to the native picker if we can't auto-identify a connected Sony device.
        IOBluetoothDeviceSelectorController *selector = [IOBluetoothDeviceSelectorController deviceSelector];
        if ([selector runModal] != kIOBluetoothUISuccess) {
            completion(NO, nil); // user cancelled - not an error
            return;
        }
        device = [[selector getResults] lastObject];
    }

    if (!device) {
        completion(NO, @"No connected Sony headset found. Connect your headphones in macOS Bluetooth settings first.");
        return;
    }

    [self connectDevice:device completion:completion];
}

- (void)reconnectToAddress:(NSString *)address completion:(void (^)(BOOL, NSString * _Nullable))completion {
    IOBluetoothDevice *device = [IOBluetoothDevice deviceWithAddressString:address];
    if (!device || !device.isPaired) { completion(NO, @"The selected headset is no longer paired."); return; }
    [self connectDevice:device completion:completion];
}

- (void)connectDevice:(IOBluetoothDevice *)device completion:(void (^)(BOOL, NSString * _Nullable))completion {
    // Every connection path must drain old work on a closed link, including manual
    // reconnect after another control app takes over. Otherwise an old retained
    // Headphones object can send inquiries through the replacement before its INIT.
    [self disconnect];
    NSUInteger generation = _connectionGeneration;
    dispatch_async(_cmdQueue, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_connectionGeneration != generation) {
                completion(NO, @"Connection cancelled.");
                return;
            }
            [self openDevice:device completion:completion];
        });
    });
}

- (void)openDevice:(IOBluetoothDevice *)device completion:(void (^)(BOOL, NSString * _Nullable))completion {
    // A device without an address string would hand std::string a null char* below (undefined
    // behaviour); getConnectedDevices() applies the same guard.
    NSString *address = [device addressString];
    if (!address) {
        completion(NO, @"The selected device has no Bluetooth address.");
        return;
    }

    try {
        _bt->connect([address UTF8String]);
    } catch (RecoverableException &exc) {
        completion(NO, @(exc.what()));
        return;
    }

    // A real RFCOMM open (SDP + link setup, sometimes with encryption renegotiation) can take a few
    // seconds; pump the run loop until it lands or we give up.
    int timeout = 80;
    while (!_bt->isConnected() && _macConnector->running && timeout >= 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        timeout--;
    }

    if (!_bt->isConnected()) {
        int status = _macConnector->channelOpenStatus();
        _bt->disconnect();
        completion(NO, [NSString stringWithFormat:@"Could not open the headset control channel (Bluetooth status %d). Another app may be using it. Close the headphone app on Android and try again; check multipoint connections in macOS Bluetooth.", status]);
        return;
    }

    _deviceName = [device nameOrAddress];
    _deviceMac = [device addressString];
    _hp = std::make_shared<Headphones>(*_bt);
    // Lets requestBattery() probe the per-earbud layout first on TWS models (WF-*/LinkBuds).
    _hp->setDeviceName(_deviceName ? [_deviceName UTF8String] : "");
    // A link the headset dropped on its own never went through -disconnect, so reset here: every new
    // Headphones needs the init handshake (its reply also gates the multipoint reads).
    _initialized = false;
    // An open audio/control link is not yet a usable Sony session. Do not start polling or
    // capability probes until the headset has answered the protocol handshake.
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil;
        try { hp->initDevice(); }
        catch (const std::exception &exc) {
            error = [NSString stringWithFormat:@"The headset did not complete Sony initialization: %s. Try connecting again.", exc.what()];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_hp != hp) { completion(NO, @"Connection cancelled."); return; }
            if (error || !self.connected) {
                [self disconnect];
                completion(NO, error ?: @"The headset disconnected during initialization.");
                return;
            }
            self->_initialized = true;
            completion(YES, nil);
        });
    });
}

- (void)disconnect {
    ++_connectionGeneration;
    if (_bt) _bt->disconnect();
    _hp.reset();
    _deviceName = nil;
    _deviceMac = nil;
    _initialized = false;
}

- (void)refreshStatusWithCompletion:(void (^)(void))completion {
    if (!_hp || !self.connected || !_initialized.load()) { completion(); return; }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        // Every method chooses its command family from the SDP-confirmed protocol version. This is
        // essential for v1: 0x22 powers off an XM4 but requests battery state on v2.
        try { hp->requestMultipoint(); } catch (const std::exception &exc) {}
        dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
        try { hp->requestAmbientState(); } catch (std::exception &exc) {}
        try { hp->requestBattery(); } catch (std::exception &exc) {}
        try { hp->requestEqualizer(); hp->requestEqualizerPresets(); } catch (std::exception &exc) {}
        try { hp->requestDsee(); } catch (std::exception &exc) {}
        dispatch_async(dispatch_get_main_queue(), ^{ completion(); });

        // Optional-feature probes can time out on unsupported devices; publish their results last.
        try { hp->probeCapabilities(); } catch (std::exception &exc) {}
        dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
    });
}

- (void)refreshMultipointWithCompletion:(void (^)(void))completion {
    // GETs only, and v2 only: on v1 these opcodes are unverified (0x22-style collisions are possible).
    if (!_hp || !self.connected || _bt->getProtocolVersion() != SonyProtocolVersion::V2 || !_initialized.load()) {
        completion();
        return;
    }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        try { hp->requestMultipoint(); } catch (std::exception &exc) {}
        dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
    });
}

static NSString *_Nullable SHCSourceSwitchError(int result) {
    switch (result) {
        case V2Table2Command::RESULT_SUCCESS: return nil;
        case V2Table2Command::RESULT_FAIL_CALLING: return @"The headset refused: a call is in progress.";
        case V2Table2Command::RESULT_FAIL_A2DP_NOT_CONNECTED: return @"The headset refused: that device isn't connected for audio.";
        case V2Table2Command::RESULT_FAIL_VOICE_ASSISTANT: return @"The headset refused: the voice assistant has priority.";
        case V2Table2Command::RESULT_NO_CONFIRMATION: return @"The headset didn't confirm the change. Showing the state it reports now.";
        default: return [NSString stringWithFormat:@"The headset refused the change (result %d).", result];
    }
}

- (void)runMultipointWrite:(int (^)(Headphones *hp))write completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected || _bt->getProtocolVersion() != SonyProtocolVersion::V2 || !_initialized.load()) {
        completion(NO, @"Not connected.");
        return;
    }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil;
        try {
            error = SHCSourceSwitchError(write(hp.get()));
        } catch (std::exception &exc) {
            error = @(exc.what());
        }
        try { hp->requestMultipoint(); } catch (std::exception &exc) {}
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error == nil, error); });
    });
}

- (void)switchPlaybackToAddress:(NSString *)address fix:(BOOL)fix completion:(void (^)(BOOL, NSString * _Nullable))completion {
    std::string target = address.UTF8String ?: "";
    [self runMultipointWrite:^int(Headphones *hp) {
        // Decide from the state as of this queued write, not the tap: a poll or the phone may have moved
        // playback in between, and a stale "already playing" would fix playback to the wrong device.
        bool alreadyPlaying = false;
        for (const auto &device : hp->getPairedDevices()) {
            if (device.playback && strcasecmp(device.address.c_str(), target.c_str()) == 0) alreadyPlaying = true;
        }
        bool pinned = hp->isPlaybackPinned();
        if (!fix) {
            // The headset keeps "fixed" on across a switch (the fix moves to the new device), so a plain
            // switch frees it afterwards. A refused switch leaves the fix untouched.
            int result = hp->switchPlaybackDevice(target);
            if (result != V2Table2Command::RESULT_SUCCESS || !pinned) return result;
            return hp->setPlaybackPinned(false);
        }
        // A fixed playback device may refuse a switch, so free it first.
        BOOL unfixed = NO;
        if (pinned && !alreadyPlaying) {
            int result = hp->setPlaybackPinned(false);
            if (result != V2Table2Command::RESULT_SUCCESS) return result;
            unfixed = YES;
        }
        if (!alreadyPlaying) {
            int result = hp->switchPlaybackDevice(target);
            if (result != V2Table2Command::RESULT_SUCCESS) {
                // Don't leave the old device unfixed after a refused switch (e.g. mid-call).
                if (unfixed) hp->setPlaybackPinned(true);
                return result;
            }
        }
        return hp->setPlaybackPinned(true);
    } completion:completion];
}

- (void)setPlaybackPinned:(BOOL)pinned completion:(void (^)(BOOL, NSString * _Nullable))completion {
    [self runMultipointWrite:^int(Headphones *hp) {
        return hp->setPlaybackPinned(pinned);
    } completion:completion];
}

- (void)refreshDynamicWithCompletion:(void (^)(void))completion {
    if (!_hp || !self.connected) { completion(); return; }
    auto hp = _hp;
    BOOL isV2 = _bt->getProtocolVersion() == SonyProtocolVersion::V2;
    dispatch_async(_cmdQueue, ^{
        // The headphone's physical button only changes ambient/NC, so that's all we poll (keeps traffic low).
        // requestAmbientState() is protocol-aware (v2 uses 66 17, v1 uses 66 02), so this is safe on both.
        try { hp->requestAmbientState(); } catch (std::exception &exc) {}
        // Battery drains, earbuds get docked and the case charges them, so re-read it too - but only
        // every Nth poll, since it costs up to three inquiries on TWS. v2 only: 0x22 is POWER_OFF on v1.
        if (isV2 && self->_dynamicTick++ % kBatteryPollEveryNTicks == 0) {
            try { hp->requestBattery(); } catch (std::exception &exc) {}
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
    });
}

- (void)setEqualizerPreset:(NSInteger)preset completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected) {
        completion(NO, @"Not connected.");
        return;
    }
    if (!_hp->hasEqualizer()) {
        completion(NO, @"Equalizer control isn't supported on this device yet.");
        return;
    }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil;
        BOOL ok = YES;
        try {
            auto expected = static_cast<EQ_PRESET>((unsigned char)preset);
            hp->setEqualizerPreset(expected);
            SHCWaitForAppliedState(hp.get(), [&] {
                hp->requestEqualizer();
                return hp->getEqualizerPreset() == expected;
            }, "The headphones did not apply this EQ preset.");
        } catch (std::exception &exc) {
            ok = NO;
            error = @(exc.what());
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(ok, error);
        });
    });
}

- (void)setCustomEqualizerBass:(NSInteger)bass bands:(NSArray<NSNumber *> *)bands preset:(NSInteger)preset completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected || !_hp->hasEqualizer()) {
        completion(NO, @"Equalizer control isn't supported on this device yet.");
        return;
    }
    std::vector<int> cbands;
    for (NSNumber *n in bands) cbands.push_back((int)n.integerValue);
    int cbass = (int)bass;
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil; BOOL ok = YES;
        try {
            hp->setEqualizerCustom(cbass, cbands, static_cast<EQ_PRESET>(preset));
            SHCWaitForAppliedState(hp.get(), [&] {
                hp->requestEqualizer();
                bool matches = hp->getEqualizerPreset() == static_cast<EQ_PRESET>(preset);
                if (!hp->isTenBandEqualizer()) matches = matches && hp->getClearBass() == std::clamp(cbass, -10, 10);
                for (int i = 0; i < hp->getEqualizerBandCount(); ++i) {
                    int expected = i < (int)cbands.size() ? cbands[i] : 0;
                    expected = hp->isTenBandEqualizer() ? std::clamp(expected, 0, 12) : std::clamp(expected, -10, 10);
                    matches = matches && hp->getEqualizerBand(i) == expected;
                }
                return matches;
            }, "The headphones did not apply the custom EQ curve.");
        } catch (std::exception &exc) { ok = NO; error = @(exc.what()); }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, error); });
    });
}

- (void)setDsee:(BOOL)enabled completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected || !_hp->hasDsee()) {
        completion(NO, @"Not supported on this device.");
        return;
    }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil; BOOL ok = YES;
        try {
            hp->setDsee(enabled);
            SHCWaitForAppliedState(hp.get(), [&] {
                hp->requestDsee();
                return hp->getDsee() == (bool)enabled;
            }, "The headphones did not apply the DSEE setting.");
        } catch (std::exception &exc) { ok = NO; error = @(exc.what()); }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, error); });
    });
}

- (void)applyMode:(SHCAmbientMode)mode
            level:(NSInteger)level
       focusVoice:(BOOL)focusVoice
    windReduction:(BOOL)windReduction
       completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected) {
        completion(NO, @"Not connected.");
        return;
    }

    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil;
        BOOL ok = YES;
        try {
            if (hp->hasWindNoiseReduction()) hp->setWindNoiseReduction(windReduction);
            switch (mode) {
                case SHCAmbientModeOff:
                    hp->setAmbientSoundControl(false);
                    if (hp->requiresWriteReadback()) {
                        hp->setAsmLevel(0);
                        hp->setFocusOnVoice(false);
                    }
                    break;
                case SHCAmbientModeNoiseCanceling:
                    hp->setAmbientSoundControl(true);
                    hp->setAsmLevel(0);
                    hp->setFocusOnVoice(false);
                    break;
                case SHCAmbientModeAmbientSound:
                    hp->setAmbientSoundControl(true);
                    hp->setAsmLevel((int)MAX(level, 1));
                    hp->setFocusOnVoice(focusVoice);
                    break;
            }
            if (hp->isChanged()) hp->setChanges();
            SHCWaitForAppliedState(hp.get(), [&] {
                hp->requestAmbientState();
                bool matches = hp->getAmbientSoundControl() == (mode != SHCAmbientModeOff);
                if (mode != SHCAmbientModeOff) {
                    matches = matches && (hp->getAsmLevel() > 0) == (mode == SHCAmbientModeAmbientSound);
                    if (mode == SHCAmbientModeNoiseCanceling && hp->hasWindNoiseReduction())
                        matches = matches && hp->getWindNoiseReduction() == (bool)windReduction;
                    if (mode == SHCAmbientModeAmbientSound) {
                        matches = matches && hp->getAsmLevel() == MAX(level, 1);
                        if (hp->requiresWriteReadback()) matches = matches && hp->getFocusOnVoice() == (bool)focusVoice;
                    }
                }
                return matches;
            }, "The headphones did not apply the ANC/Ambient setting.");
        } catch (RecoverableException &exc) {
            ok = NO;
            error = @(exc.what());
        } catch (std::exception &exc) {
            ok = NO;
            error = @(exc.what());
        }
        // The write never landed, so stop it counting as pending - otherwise the ambient read-back stays
        // suppressed and the UI freezes on a value the headphones never took.
        if (!ok) hp->discardAmbientChanges();
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(ok, error);
        });
    });
}

- (void)setAutoPowerOff:(NSInteger)index completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected) { completion(NO, @"Not connected."); return; }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil; BOOL ok = YES;
        try {
            hp->setAutoPowerOff((int)index);
            SHCWaitForAppliedState(hp.get(), [&] {
                hp->requestAutoPowerOff();
                return hp->getAutoPowerOff() == index;
            }, "The headphones did not apply the auto power-off setting.");
        } catch (std::exception &exc) { ok = NO; error = @(exc.what()); }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, error); });
    });
}

- (void)setSpeakToChat:(BOOL)enabled completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected) { completion(NO, @"Not connected."); return; }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil; BOOL ok = YES;
        try {
            hp->setSpeakToChat(enabled);
            SHCWaitForAppliedState(hp.get(), [&] {
                hp->requestSpeakToChat();
                return hp->getSpeakToChat() == (bool)enabled;
            }, "The headphones did not apply the Speak-to-Chat setting.");
        } catch (std::exception &exc) { ok = NO; error = @(exc.what()); }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, error); });
    });
}

- (void)setAdaptiveVolume:(BOOL)enabled completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected) { completion(NO, @"Not connected."); return; }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil; BOOL ok = YES;
        try { hp->setAdaptiveVolume(enabled); } catch (std::exception &exc) { ok = NO; error = @(exc.what()); }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, error); });
    });
}

- (void)setMultipoint:(BOOL)enabled completion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (!_hp || !self.connected) { completion(NO, @"Not connected."); return; }
    auto hp = _hp;
    dispatch_async(_cmdQueue, ^{
        NSString *error = nil; BOOL ok = YES;
        try { hp->setMultipoint(enabled); } catch (std::exception &exc) { ok = NO; error = @(exc.what()); }
        // XM4C must restart and reconnect before fresh reads; the model owns that one-shot flow.
        // Other models retain the immediate read-back path.
        if (ok && self.connected && !hp->multipointRequiresReconnect()) {
            try { hp->requestMultipoint(); } catch (const std::exception &exc) {}
        }
        NSString *attemptDiagnostics = @(hp->getMultipointDiagnostics().c_str());
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_lastMultipointWriteDiagnostics = attemptDiagnostics;
            completion(ok, error);
        });
    });
}

@end
