#include "BluetoothWrapper.h"
#include "CommandSerializer.h"
#include "Exceptions.h"
#include "Headphones.h"
#include "ControlSessionHealth.h"

#include <algorithm>
#include <cstring>
#include <deque>
#include <functional>
#include <iostream>
#include <memory>
#include <stdexcept>

namespace
{
class FakeV1Connector final : public IBluetoothConnector
{
public:
	int send(char* buf, size_t length) override
	{
		Buffer frame(buf, buf + length);
		if (frame.size() < 2 || frame.front() != START_MARKER || frame.back() != END_MARKER)
			throw std::runtime_error("invalid outbound frame");

		Buffer body(frame.begin() + 1, frame.end() - 1);
		auto message = CommandSerializer::unpackBtMessage(body);
		if (message.dataType != DATA_TYPE::DATA_MDR) return static_cast<int>(length);

		sentPayloads.push_back(message.payload);
		if (notificationBeforeNextAck) {
			queue({ (char)V1Command::AMBIENT_RET, 0x02, 0x11, 0x02, 0x02, 0x01, 0x00, 0x00 }, DATA_TYPE::DATA_MDR, 0);
			notificationBeforeNextAck = false;
		}
		queue({}, DATA_TYPE::ACK, 1 - message.seqNumber);
		queueResponse(message.payload);
		return static_cast<int>(length);
	}

	int recv(char* buf, size_t length) override
	{
		if (incoming.empty()) throw std::runtime_error("fake connector has no queued response");
		auto frame = std::move(incoming.front());
		incoming.pop_front();
		if (!recvPrefix.empty()) {
			frame.insert(frame.begin(), recvPrefix.begin(), recvPrefix.end());
			recvPrefix.clear();
		}
		if (frame.size() > length) throw std::runtime_error("fake response exceeds receive buffer");
		std::memcpy(buf, frame.data(), frame.size());
		return static_cast<int>(frame.size());
	}

	void connect(const std::string&) override { connected = true; }
	void disconnect() noexcept override { connected = false; }
	bool isConnected() noexcept override { return connected; }
	std::vector<BluetoothDevice> getConnectedDevices() override { return {}; }
	SonyProtocolVersion getProtocolVersion() noexcept override { return SonyProtocolVersion::V1; }

	std::vector<Buffer> sentPayloads;
	Buffer recvPrefix;
	bool notificationBeforeNextAck = false;

private:
	void queue(const Buffer& payload, DATA_TYPE type, unsigned char sequence)
	{
		incoming.push_back(CommandSerializer::packageDataForBt(payload, type, sequence));
	}

	void queueResponse(const Buffer& request)
	{
		if (request.empty()) return;
		Buffer response;
		switch ((unsigned char)request[0])
		{
		case V1Command::INIT_REQUEST: response = { (char)V1Command::INIT_REPLY, 0x00, 0x40, 0x10 }; break;
		case V1Command::FW_GET: response = { (char)V1Command::FW_RET, 0x02, 0x05, '3', '.', '0', '.', '1' }; break;
		case V1Command::BATTERY_GET: response = { (char)V1Command::BATTERY_RET, 0x00, 87, 0x00 }; break;
		case V1Command::CODEC_GET: response = { (char)V1Command::CODEC_RET, 0x00, 0x10 }; break;
		case V1Command::EQ_GET: response = { (char)V1Command::EQ_RET, 0x01, 0x10, 0x06, 10, 10, 10, 10, 10, 10 }; break;
		case V1Command::DSEE_GET: response = { (char)V1Command::DSEE_RET, 0x02, 0x00, 0x01 }; break;
		case V1Command::AMBIENT_GET: response = { (char)V1Command::AMBIENT_RET, 0x02, 0x11, 0x02, 0x02, 0x01, 0x00, 0x00 }; break;
		case V1Command::BTNMODE_GET:
			if (request.size() >= 2 && (unsigned char)request[1] == V1Command::SUB_AUTO_POWER_OFF)
				response = { (char)V1Command::BTNMODE_RET, (char)V1Command::SUB_AUTO_POWER_OFF, 0x01, 0x01, 0x01 };
			else if (request.size() >= 2 && (unsigned char)request[1] == V1Command::SUB_SPEAK_TO_CHAT)
				response = { (char)V1Command::BTNMODE_RET, (char)V1Command::SUB_SPEAK_TO_CHAT, 0x01, 0x01 };
			break;
		default: return; // SET commands only need the ACK already queued above.
		}
		if (!response.empty()) queue(response, DATA_TYPE::DATA_MDR, 0);
	}

	bool connected = true;
	std::deque<Buffer> incoming;
};

// v2-generation device scripted per test through `reply`: a request it returns an empty buffer for gets
// only the ACK, so the read times out (recv on an empty queue throws), which callers treat as "unsupported".
class FakeV2Connector final : public IBluetoothConnector
{
public:
	int send(char* buf, size_t length) override
	{
		Buffer frame(buf, buf + length);
		if (frame.size() < 2 || frame.front() != START_MARKER || frame.back() != END_MARKER)
			throw std::runtime_error("invalid outbound frame");

		Buffer body(frame.begin() + 1, frame.end() - 1);
		auto message = CommandSerializer::unpackBtMessage(body);
        if (onSend) onSend(message);
		if (message.dataType != DATA_TYPE::DATA_MDR
            && !(acceptTable2 && message.dataType == DATA_TYPE::DATA_MDR_NO2)) return static_cast<int>(length);

		sentPayloads.push_back(message.payload);
		if (!(omitConfirmationAck && message.payload == Buffer{(char)0x98, 0, 6, 1}))
            queue({}, DATA_TYPE::ACK, 1 - message.seqNumber);
		auto response = reply ? reply(message.payload) : Buffer{};
		if (!response.empty()) queue(response, message.dataType, 0);
		return static_cast<int>(length);
	}

	int recv(char* buf, size_t length) override
	{
		if (incoming.empty()) throw std::runtime_error("fake connector has no queued response");
		auto frame = std::move(incoming.front());
		incoming.pop_front();
		if (frame.size() > length) throw std::runtime_error("fake response exceeds receive buffer");
        if (onReceive) {
            Buffer body(frame.begin()+1, frame.end()-1);
            onReceive(CommandSerializer::unpackBtMessage(body));
        }
		std::memcpy(buf, frame.data(), frame.size());
		return static_cast<int>(frame.size());
	}

	void connect(const std::string&) override { connected = true; }
	void disconnect() noexcept override { connected = false; }
	bool isConnected() noexcept override { return connected; }
	std::vector<BluetoothDevice> getConnectedDevices() override { return {}; }
	SonyProtocolVersion getProtocolVersion() noexcept override { return SonyProtocolVersion::V2; }

	bool acceptTable2 = false;
    bool omitConfirmationAck = false;
    std::vector<Buffer> sentPayloads;
	std::function<Buffer(const Buffer&)> reply;
    std::function<void(const CommandSerializer::Message&)> onReceive;
    std::function<void(const CommandSerializer::Message&)> onSend;

	bool sent(const Buffer& payload) const
	{
		return std::find(sentPayloads.begin(), sentPayloads.end(), payload) != sentPayloads.end();
	}

private:
	void queue(const Buffer& payload, DATA_TYPE type, unsigned char sequence)
	{
		incoming.push_back(CommandSerializer::packageDataForBt(payload, type, sequence));
	}

	bool connected = true;
	std::deque<Buffer> incoming;
};

Buffer bytes(std::initializer_list<int> values)
{
	Buffer out;
	for (int v : values) out.push_back((char)v);
	return out;
}

void require(bool condition, const char* message)
{
	if (!condition) throw std::runtime_error(message);
}

// A malformed inbound frame must surface as a RecoverableException (caught at every call
// site and shown in the UI) rather than a bare std::runtime_error. If a future call site
// narrowed its catch to RecoverableException, a plain runtime_error here would reach
// std::terminate on attacker-controlled input.
template <typename Fn>
void expectRecoverable(Fn&& fn, const char* message)
{
	try { fn(); }
	catch (const RecoverableException&) { return; }
	catch (...) { throw std::runtime_error(message); }
	throw std::runtime_error(message);
}
}

int main()
{
    {
        // A channel may remain open while a competing controller makes all
        // inquiries go unanswered. ACKs and unrelated notifications are not proof
        // that our requested state was returned.
        auto connector = std::make_unique<FakeV2Connector>();
        auto *wire = connector.get();
        BluetoothWrapper bt(std::move(connector));
        Headphones hp(bt);
        ControlSessionHealth health;
        using State = ControlSessionHealth::State;
        wire->reply = [](const Buffer&) { return bytes({0x23, 0, 80, 0}); };
        hp.requestBattery();
        require(bt.successfulResponseCount() == 1 && hp.getBatteryLevel() == 80,
            "a matched basic reply must be observed");
        auto count = bt.successfulResponseCount();
        hp.getBatteryLevel();
        require(bt.successfulResponseCount() == count, "cached battery must not prove session health");

        // Optional multipoint failure does not feed the health policy.
        wire->reply = nullptr;
        hp.requestMultipoint();
        require(health.record(true) == State::Responsive, "optional feature failure killed a live session");
        for (int attempt = 1; attempt <= 3; ++attempt) {
            count = bt.successfulResponseCount();
            // Battery's layout probes catch errors and return normally. A return
            // without a matched response must still count as heartbeat failure.
            hp.requestBattery();
            require(bt.isConnected(), "test must simulate a physically open silent channel");
            auto state = health.record(bt.successfulResponseCount() != count);
            require(state == (attempt < 3 ? State::Checking : State::Unresponsive),
                "silent open session was not classified correctly");
        }
        health.reset();
        require(health.record(false) == State::Checking, "new session inherited old failures");
        wire->reply = [](const Buffer&) { return bytes({0x23, 0, 79, 0}); };
        count = bt.successfulResponseCount();
        hp.requestBattery();
        require(health.record(bt.successfulResponseCount() != count) == State::Responsive,
            "basic battery fallback must recover an unsupported ANC heartbeat");
        require(health.record(false) == State::Checking && health.record(false) == State::Checking,
            "successful reply did not reset the consecutive-failure budget");

        // Same response ID with a different subtype is just an unrelated frame.
        count = bt.successfulResponseCount();
        wire->reply = [](const Buffer&) { return bytes({0x67, 0x19, 1, 1, 0, 0, 1}); };
        try { bt.sendCommandAndReadResponse(bytes({0x66, 0x17}), 0x67, 0x17); }
        catch (const std::exception&) {}
        require(bt.successfulResponseCount() == count, "unrelated notification revived a dead session");
    }
	auto fake = std::make_unique<FakeV1Connector>();
	auto* observed = fake.get();
	BluetoothWrapper bluetooth(std::move(fake));
	Headphones headphones(bluetooth);

	// RFCOMM stacks may deliver harmless transport noise before a start marker. It must not become part
	// of the checksum-protected Sony frame.
	observed->recvPrefix = { 0x00, 0x7f };
	headphones.initDevice();
	headphones.requestAmbientState();
	headphones.requestBattery();
	headphones.requestEqualizer();
	headphones.requestDsee();
	headphones.probeCapabilities();

	require(headphones.hasBattery(), "v1 battery capability was not recorded");
	require(headphones.getBatteryLevel() == 87, "v1 battery response was not parsed");
	require(headphones.hasEqualizer(), "v1 equalizer capability was not recorded");
	require(headphones.getEqualizerPreset() == EQ_PRESET::BRIGHT, "v1 equalizer response was not parsed");
	require(headphones.hasDsee() && headphones.getDsee(), "v1 DSEE response was not parsed");
	require(headphones.getAmbientSoundControl(), "v1 ANC response was not parsed");
	require(headphones.getAsmLevel() == 0, "v1 ANC response was mistaken for ambient sound");
	require(headphones.hasFirmware() && headphones.getFirmware() == "3.0.1", "v1 firmware response was not parsed");
	require(headphones.hasCodec() && headphones.getCodec() == "LDAC", "v1 codec response was not parsed");
	require(headphones.hasAutoPowerOff() && headphones.getAutoPowerOff() == 2, "v1 auto-power-off response was not parsed");
	require(headphones.hasSpeakToChat() && headphones.getSpeakToChat(), "v1 Speak-to-Chat response was not parsed");

	const auto hasV1BatteryRequest = std::any_of(observed->sentPayloads.begin(), observed->sentPayloads.end(), [](const Buffer& payload) {
		return payload.size() >= 2 && (unsigned char)payload[0] == V1Command::BATTERY_GET && payload[1] == 0x00;
	});
	const auto hasDangerousV2BatteryRequest = std::any_of(observed->sentPayloads.begin(), observed->sentPayloads.end(), [](const Buffer& payload) {
		return !payload.empty() && (unsigned char)payload[0] == V2Command::BATTERY_GET;
	});
	require(hasV1BatteryRequest, "XM4 path did not issue the v1 battery inquiry");
	require(!hasDangerousV2BatteryRequest, "XM4 path emitted v2 battery / v1 power-off opcode 0x22");

	headphones.setAmbientSoundControl(true);
	headphones.setAsmLevel(20);
	headphones.setFocusOnVoice(false);
	headphones.setChanges();
	const auto hasLevel20 = std::any_of(observed->sentPayloads.begin(), observed->sentPayloads.end(), [](const Buffer& payload) {
		return payload.size() == 8 && (unsigned char)payload[0] == V1Command::AMBIENT_SET &&
			(unsigned char)payload[7] == 20;
	});
	require(hasLevel20,
		"XM4 ambient level 20 was not serialized correctly");

	headphones.setAsmLevel(1);
	headphones.setChanges();
	const auto& ambientLevelOne = observed->sentPayloads.back();
	require(ambientLevelOne.size() == 8 && (unsigned char)ambientLevelOne[4] == 0x00 &&
		(unsigned char)ambientLevelOne[7] == 0x01,
		"XM4 ambient level 1 was mistaken for wind/noise cancellation");

	headphones.setEqualizerCustom(3, { -2, -1, 0, 1, 2 });
	require(!observed->sentPayloads.empty(), "custom EQ command was not sent");
	const auto& customEq = observed->sentPayloads.back();
	require(customEq.size() == 10 && (unsigned char)customEq[0] == V1Command::EQ_SET,
		"custom EQ did not use the v1 command");
	require((unsigned char)customEq[1] == 0x01 && (unsigned char)customEq[2] == V1Command::MANUAL_EQ,
		"custom EQ did not use the v1 subtype and manual preset byte");

	observed->notificationBeforeNextAck = true;
	headphones.setDsee(false);
	const auto& dsee = observed->sentPayloads.back();
	require(dsee.size() == 4 && (unsigned char)dsee[0] == V1Command::DSEE_SET &&
		(unsigned char)dsee[1] == 0x02 && (unsigned char)dsee[3] == 0x00,
		"DSEE did not use the v1 command layout");

	headphones.setSpeakToChat(false);
	const auto& speakToChat = observed->sentPayloads.back();
	require(speakToChat.size() == 4 && (unsigned char)speakToChat[0] == V1Command::BTNMODE_SET &&
		(unsigned char)speakToChat[1] == V1Command::SUB_SPEAK_TO_CHAT && (unsigned char)speakToChat[3] == 0x00,
		"Speak-to-Chat did not use the v1 command layout");

	// Multipoint has no proven v1 frames (GadgetBridge SonyProtocolImplV1: "Connect two devices not
	// implemented for V1"), so the XM4 path must never probe or set it.
	headphones.requestMultipoint();
	require(!headphones.hasMultipointSetting(), "multipoint capability must stay unconfirmed on v1");
	const auto hasMultipointFrame = std::any_of(observed->sentPayloads.begin(), observed->sentPayloads.end(), [](const Buffer& payload) {
		return !payload.empty() && ((unsigned char)payload[0] == V2Command::GS_GET_CAPABILITY ||
			(unsigned char)payload[0] == V2Command::GS_GET_PARAM ||
			(unsigned char)payload[0] == V2Command::GS_SET_PARAM ||
			(unsigned char)payload[0] == V2Command::SYSCTL_SET);
	});
	require(!hasMultipointFrame, "XM4 path emitted a v2 multipoint frame (d0/d6/d8/98)");
	bool multipointRejected = false;
	try { headphones.setMultipoint(true); }
	catch (const std::exception&) { multipointRejected = true; }
	require(multipointRejected, "setMultipoint on v1 must throw instead of sending");

	// --- v2 multipoint ("Connect to 2 devices"), byte layout proven by GadgetBridge on the WH-ULT900N
	// (SonyProtocolImplV2 commits 8cbc309346, e8520865f3, 5d7b37d1b7) ---
	// The setting lives in a per-model general-settings slot, found by name; the ULT900N uses D1.
	auto fakeV2 = std::make_unique<FakeV2Connector>();
	auto* observedV2 = fakeV2.get();
	observedV2->reply = [](const Buffer& request) -> Buffer {
		if (request == bytes({ 0xd0, 0xd1, 0x01 })) {
			std::string name = "MULTIPOINT_SETTING";
			Buffer response = bytes({ 0xd1, 0xd1, 0x00, 0x00, (int)name.size() });
			response.insert(response.end(), name.begin(), name.end());
			response.push_back(0x00);
			return response;
		}
		if (request == bytes({ 0xd6, 0xd1 })) return bytes({ 0xd7, 0xd1, 0x00, 0x00 }); // 00 = ON (inverted)
		return {};
	};
	BluetoothWrapper bluetoothV2(std::move(fakeV2));
	Headphones ult900n(bluetoothV2);
	ult900n.probeCapabilities();
	ult900n.requestMultipoint();

	require(ult900n.hasMultipointSetting(), "MULTIPOINT_SETTING slot D1 was not found by name");
	require(ult900n.getMultipointEnabled(), "RET d7 d1 00 00 must parse as multipoint ON (enable bit inverted)");
	require(!ult900n.hasSpeakToChat() && !ult900n.hasAdaptiveVolume(),
		"unanswered v2 probes must stay unsupported");

	ult900n.setMultipoint(false);
	require(observedV2->sentPayloads.size() >= 2, "multipoint OFF did not send both frames");
	const auto offState = observedV2->sentPayloads[observedV2->sentPayloads.size() - 2];
	const auto offCommit = observedV2->sentPayloads.back();
	require(offState == Buffer({ (char)0xd8, (char)0xd1, 0x00, 0x01 }),
		"multipoint OFF state frame must be d8 d1 00 01");
	require(offCommit == Buffer({ (char)0x98, 0x00, 0x06, 0x01 }),
		"multipoint apply commit must be the fixed 98 00 06 01");
	require(!ult900n.getMultipointEnabled(), "multipoint OFF was not mirrored locally");

	ult900n.setMultipoint(true);
	const auto onState = observedV2->sentPayloads[observedV2->sentPayloads.size() - 2];
	const auto onCommit = observedV2->sentPayloads.back();
	require(onState == Buffer({ (char)0xd8, (char)0xd1, 0x00, 0x00 }),
		"multipoint ON state frame must be d8 d1 00 00");
	require(onCommit == Buffer({ (char)0x98, 0x00, 0x06, 0x01 }),
		"multipoint ON must reuse the fixed apply commit 98 00 06 01");
	require(ult900n.getMultipointEnabled(), "multipoint ON was not mirrored locally");

    // XM4C regression: enable session alerts, D2 SET, alert, ACK, confirmation.
    // An ACK alone must never authorize the confirmation. No writes are retried.
    for (bool enable : {false, true}) {
        for (const Buffer& alert : {bytes({0x99, 0, 6, 1}), Buffer{}, bytes({0x99, 0, 7, 1}),
                                    bytes({0x99, 0, 6}), bytes({0x99, 0, 6, 0})}) {
            for (bool omitAck : {false, true}) {
                auto fake = std::make_unique<FakeV2Connector>();
                fake->omitConfirmationAck = omitAck;
                bool actualState = !enable;
                auto* observed = fake.get();
                bool alertRead = false;
                bool alertAcknowledged = false;
                bool alertsEnabled = false;
                fake->onSend = [&](const CommandSerializer::Message& message) {
                    if (alertRead && message.dataType == DATA_TYPE::ACK) alertAcknowledged = true;
                };
                fake->onReceive = [&](const CommandSerializer::Message& message) {
                    if (message.payload == alert && !alert.empty()) alertRead = true;
                };
                fake->reply = [&](const Buffer& request) -> Buffer {
                    if (request == bytes({0xd0, 0xd2, 1})) {
                        std::string name = "MULTIPOINT_SETTING";
                        Buffer response = bytes({0xd1, 0xd2, 0, 1, (int)name.size()});
                        response.insert(response.end(), name.begin(), name.end());response.push_back(0);
                        return response;
                    }
                    if (request == bytes({0xd6, 0xd2})) return bytes({0xd7, 0xd2, 0, actualState ? 0 : 1});
                    if (request == bytes({0x94, 0, 0})) alertsEnabled = true;
                    if (request == bytes({0xd8, 0xd2, 0, enable ? 0 : 1})) {
                        require(alertsEnabled, "multipoint SET preceded session alert setup");
                        return alertsEnabled ? alert : Buffer{};
                    }
                    if (request == bytes({0x98, 0, 6, 1})) require(alertRead && alertAcknowledged, "confirmation preceded receiving/acknowledging the alert");
                    return {};
                };
                BluetoothWrapper bt(std::move(fake));Headphones hp(bt);hp.setDeviceName("WH-1000XM4C");hp.requestMultipoint();
                require(hp.canSetMultipoint(), "supported XM4C D2 setting was not writable");
                size_t before=observed->sentPayloads.size();bool failed=false;
                try { hp.setMultipoint(enable); } catch (const std::exception&) { failed=true; }
                bool expected=alert==bytes({0x99,0,6,1});
                require(failed == (!expected || omitAck), "XM4C alert/confirmation ACK validation returned wrong result");
                require(hp.multipointConfirmationAttempted() == expected, "recovery allowed before a valid alert or not allowed after confirmation attempt");
                require(observed->sentPayloads.size()==before+(expected?3:2), "XM4C sent confirmation without valid alert or retried SET");
                require(observed->sentPayloads[before]==bytes({0x94,0,0}), "XM4C did not enable fixed-message alerts first");
                require(observed->sentPayloads[before+1]==bytes({0xd8,0xd2,0,enable?0:1}), "XM4C wrote the wrong slot/value");
                if (expected) require(observed->sentPayloads.back()==bytes({0x98,0,6,1}), "XM4C confirmation has unexpected payload");
                require(hp.getMultipointEnabled()!=enable, "XM4C cached desired state without reconnect/read-back");
                require(hp.getMultipointDiagnostics().find("W T1 d8 d2") != std::string::npos,
                    "multipoint write trace was unavailable before another status read");
                if (expected) require(hp.getMultipointDiagnostics().find("R T1 99 00 06 01") != std::string::npos,
                    "accepted headset alert was absent from diagnostics");
                if (expected && omitAck) {
                    actualState = enable; // Peer applied the setting despite closing before its ACK.
                    size_t beforeRead = observed->sentPayloads.size();
                    hp.requestMultipoint();
                    require(hp.getMultipointEnabled() == enable, "fresh GET did not recover applied state after lost ACK");
                    for (size_t i = beforeRead; i < observed->sentPayloads.size(); ++i) {
                        auto command = (unsigned char)observed->sentPayloads[i][0];
                        require(command != 0xd8 && command != 0x98 && command != 0x94,
                                "readback recovery resent a setting or confirmation");
                    }
                }
            }
        }
    }
    // If session alert setup fails, do not send the setting or confirmation.
    {
        auto fake = std::make_unique<FakeV2Connector>();
        auto* observed = fake.get();
        fake->reply = [&](const Buffer& request) -> Buffer {
            if (request == bytes({0xd0, 0xd2, 1})) {
                std::string name = "MULTIPOINT_SETTING";
                Buffer response = bytes({0xd1, 0xd2, 0, 1, (int)name.size()});
                response.insert(response.end(), name.begin(), name.end());
                response.push_back(0);
                return response;
            }
            if (request == bytes({0xd6, 0xd2})) return bytes({0xd7, 0xd2, 0, 1});
            if (request == bytes({0x94, 0, 0})) throw RecoverableException("alert setup failed", false);
            return {};
        };
        BluetoothWrapper bt(std::move(fake));
        Headphones hp(bt);
        hp.setDeviceName("WH-1000XM4C");
        hp.requestMultipoint();
        size_t before = observed->sentPayloads.size();
        bool failed = false;
        try { hp.setMultipoint(true); } catch (const std::exception&) { failed = true; }
        require(failed, "failed alert setup was accepted");
        require(observed->sentPayloads.size() == before + 1,
                "setting or confirmation was sent after failed alert setup");
    }
    // A different setting slot is outside the supported XM4C write profile.
    ult900n.setDeviceName("WH-1000XM4C");
    require(!ult900n.canSetMultipoint(), "XM4C D1 was incorrectly authorized by the D2 profile");
    auto beforeBlocked=observedV2->sentPayloads.size();bool blocked=false;
    try { ult900n.setMultipoint(false); } catch (const std::exception&) { blocked=true; }
    require(blocked && observedV2->sentPayloads.size()==beforeBlocked, "unverified XM4C slot sent a command");

	// --- WH-1000XM6 (issue #11): noise control reads via 0x19, the equalizer is the ten-band 0x04 layout.
	// Frames captured on fw 3.1.5 by marconvcm/sony-device-center (#44, #74). ---
	auto fakeXm6 = std::make_unique<FakeV2Connector>();
	auto* observedXm6 = fakeXm6.get();
	observedXm6->reply = [](const Buffer& request) -> Buffer {
		if (request == bytes({ 0x66, 0x17 })) return bytes({ 0x67, 0x17, 0x00, 0x00, 0x00, 0x00, 0x00 });
		if (request == bytes({ 0x66, 0x19 })) return bytes({ 0x67, 0x19, 0x01, 0x01, 0x01, 0x00, 0x0a, 0x00, 0x00 });
		if (request == bytes({ 0x56, 0x04 })) return bytes({ 0x57, 0x04, 0xa0, 0x0a, 6, 6, 6, 6, 6, 6, 6, 6, 6, 12 });
		return {};
	};
	BluetoothWrapper bluetoothXm6(std::move(fakeXm6));
	Headphones xm6(bluetoothXm6);
	xm6.setDeviceName("WH-1000XM6");

	xm6.requestAmbientState();
	require(observedXm6->sent(bytes({ 0x66, 0x19 })) && !observedXm6->sent(bytes({ 0x66, 0x17 })),
		"XM6 noise control must be read via 66 19");
	require(xm6.getAmbientSoundControl() && xm6.getAsmLevel() == 10, "XM6 67 19 reply (Ambient, level 10) was not parsed");

	xm6.requestEqualizer();
	require(xm6.hasEqualizer() && xm6.isTenBandEqualizer(), "XM6 ten-band equalizer was not recognised");
	require(xm6.getEqualizerBandCount() == 10 && xm6.getEqualizerBand(0) == 6 && xm6.getEqualizerBand(9) == 12,
		"XM6 raw ten-band values were not decoded");
	require(xm6.getEqualizerPreset() == EQ_PRESET::MANUAL, "XM6 custom preset byte was not decoded");

	xm6.setEqualizerCustom(5, { 0, 1, 2, 3, 4, 5, 6, 7, 8, 13 });
	require(observedXm6->sentPayloads.back() == bytes({ 0x58, 0x04, 0xa0, 0x0a, 0, 1, 2, 3, 4, 5, 6, 7, 8, 12 }),
		"XM6 custom EQ must be 58 04 a0 0a <10 raw bands clamped to 0..12>, no clear bass");
	xm6.setEqualizerPreset(EQ_PRESET::OFF);
	require(observedXm6->sent(bytes({ 0x58, 0x04, 0x00, 0x00 })), "XM6 preset must use inquired type 04");

	// WH-1000XM4C firmware 1.1.2: real capability list includes 57 (EQ 04) and 6a (ANC 16).
	auto fakeXm4c = std::make_unique<FakeV2Connector>();
	auto* observedXm4c = fakeXm4c.get();
	observedXm4c->reply = [](const Buffer& request) -> Buffer {
		if (request == bytes({0x06, 0x00})) return bytes({0x07, 0x00, 0x03, 0x57, 0x0c, 0x6a, 0x04, 0xf2, 0x06});
		if (request == bytes({0x56, 0x04}))
			return bytes({0x57, 0x04, 0x00, 0x0a, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6});
		if (request == bytes({0x66, 0x16})) return bytes({0x67, 0x16, 0x01, 0x01, 0x00, 0x02, 0x01, 0x0a});
		if (request == bytes({0xf6, 0x02})) return bytes({0xf7, 0x02, 0x01, 0x01});
		if (request == bytes({0x50, 0x04, 0x01}))
			return bytes({0x51, 0x04, 0x0a, 0x0d, 0x09, 0x00, 0x00, 0x30, 0x00, 0x31, 0x00,
				0x32, 0x00, 0x33, 0x00, 0x20, 0x00, 0xa0, 0x00, 0xa1, 0x00, 0xa2, 0x00});
		return {};
	};
	BluetoothWrapper bluetoothXm4c(std::move(fakeXm4c));
	Headphones xm4c(bluetoothXm4c);
	xm4c.setDeviceName("WH-1000XM4C");
	xm4c.requestEqualizer();
	require(xm4c.isTenBandEqualizer() && xm4c.getEqualizerBandCount() == 10,
		"XM4C ten-band EQ must be discovered from the response");
	require(xm4c.getEqualizerBand(9) == 6 && xm4c.getClearBass() == 0,
		"XM4C raw ten-band values must not be interpreted as five-band values plus Clear Bass");
	xm4c.setEqualizerCustom(0, {0, 1, 2, 3, 4, 5, 6, 7, 8, 12});
	require(observedXm4c->sentPayloads.back() == bytes({0x58, 0x04, 0xa0, 0x0a, 0, 1, 2, 3, 4, 5, 6, 7, 8, 12}),
		"XM4C must send ten bands using advertised subtype 04");
	xm4c.requestAmbientState();
	require(xm4c.getAmbientSoundControl() && xm4c.getAsmLevel() == 0 && xm4c.getFocusOnVoice(),
		"XM4C subtype 16 must decode NC mode with voice byte at offset 6");
	xm4c.setAmbientSoundControl(true);
	xm4c.setAsmLevel(10);
	xm4c.setFocusOnVoice(false);
	xm4c.setChanges();
	require(observedXm4c->sentPayloads.back() == bytes({0x68, 0x16, 0x01, 0x01, 0x01, 0x02, 0x00, 0x0a}),
		"XM4C Ambient command must include the separate NC value byte");
	xm4c.setAsmLevel(0);
	xm4c.setChanges();
	require(observedXm4c->sentPayloads.back() == bytes({0x68, 0x16, 0x01, 0x01, 0x00, 0x02, 0x00, 0x01}),
		"XM4C ANC command must use the captured subtype 16 layout");
	require(!observedXm4c->sent(bytes({0x66, 0x17})), "XM4C must not keep polling unsupported ANC subtype 17");
	require(xm4c.hasWindNoiseReduction() && !xm4c.getWindNoiseReduction(),
		"Subtype 16 must expose the dual/single ANC selector");
	xm4c.setWindNoiseReduction(true);
	require(xm4c.isChanged(), "Changing only the wind variant must schedule an ANC write");
	xm4c.requestAmbientState(); // Stale dual reply must not erase the pending single choice.
	require(xm4c.isChanged(), "A poll must not discard a pending wind-mode change");
	xm4c.setChanges();
	require(observedXm4c->sentPayloads.back() == bytes({0x68, 0x16, 1, 1, 0, 1, 0, 1}),
		"Wind reduction must write single NC at offset 5");
	auto beforeWindReadReply = observedXm4c->reply;
	observedXm4c->reply = [beforeWindReadReply](const Buffer& request) -> Buffer {
		if (request == bytes({0x66, 0x16})) return bytes({0x67, 0x16, 1, 1, 0, 1, 0, 1});
		return beforeWindReadReply(request);
	};
	xm4c.requestAmbientState();
	require(xm4c.getWindNoiseReduction(), "Single NC readback must report wind reduction");
	xm4c.setWindNoiseReduction(false);
	xm4c.setChanges();
	require(observedXm4c->sentPayloads.back() == bytes({0x68, 0x16, 1, 1, 0, 2, 0, 1}),
		"Normal noise cancelling must restore dual NC");
	observedXm4c->reply = beforeWindReadReply;
	xm4c.requestAmbientState();
	xm4c.setWindNoiseReduction(true);
	xm4c.discardAmbientChanges();
	require(!xm4c.isChanged(), "Failed wind writes must allow later polling and retries");
	xm4c.probeCapabilities();
	require(xm4c.hasSpeakToChat() && !xm4c.getSpeakToChat(), "XM4C must read advertised type-1 Speak-to-Chat");
	require(!observedXm4c->sent(bytes({0xf6, 0x0c})), "XM4C must not probe unadvertised type-2 Speak-to-Chat");
	require(!observedXm4c->sent(bytes({0xf6, 0x0a})), "XM4C must not probe unadvertised adaptive volume");
	auto beforeUnadvertisedSlot = observedXm4c->sentPayloads.size();
	expectRecoverable([&] { xm4c.setEqualizerCustom(0, std::vector<int>(10, 6), EQ_PRESET::CUSTOM_1); },
		"Numbered slot edits must wait for device advertisement");
	require(observedXm4c->sentPayloads.size() == beforeUnadvertisedSlot, "Unconfirmed custom slot must not send a write");
	xm4c.requestEqualizerPresets();
	auto advertisedPresets = xm4c.getEqualizerPresets();
	require(advertisedPresets.size() == 9 && advertisedPresets[1].code == 0x30 && advertisedPresets[8].code == 0xa2,
		"XM4C must expose all nine advertised EQ presets");
	require(advertisedPresets[1].name.empty(), "empty device preset names must remain available for UI fallbacks");
	auto writesBeforeRejectedPreset = observedXm4c->sentPayloads.size();
	expectRecoverable([&] { xm4c.setEqualizerPreset(EQ_PRESET::BRIGHT); }, "unsupported legacy EQ preset must be rejected");
	require(observedXm4c->sentPayloads.size() == writesBeforeRejectedPreset, "unadvertised preset must not send a SET");
	xm4c.setEqualizerPreset(EQ_PRESET::HEAVY);
	require(observedXm4c->sent(bytes({0x58, 0x04, 0x30, 0x00})), "advertised Heavy preset must use its real ID");

	// Reconstructed stateful fixtures: each numbered slot must retain its own curve.
	auto originalXm4cReply = observedXm4c->reply;
	unsigned char activeSlot = 0xa0;
	std::vector<Buffer> slotCurves(3, Buffer(10, 6));
	Buffer timing = bytes({0xfb, 0x02, 0x01, 0x00, 0x01});
	bool malformedTiming = false;
	observedXm4c->reply = [&](const Buffer& request) -> Buffer {
		if (request == bytes({0xf0, 0x02})) return bytes({0xf1, 0x02, 0x00, 5, 15, 30});
		if (request == bytes({0xfa, 0x02})) return malformedTiming ? bytes({0xfb, 0x02, 0x00}) : timing;
		if (request.size() == 5 && (unsigned char)request[0] == 0xfc) {
			timing = request; timing[0] = (char)0xfb; return {};
		}
		if (request.size() >= 4 && request[0] == 0x58 && request[1] == 0x04) {
			activeSlot = (unsigned char)request[2];
			if (request.size() == 14) slotCurves[activeSlot - 0xa0] = Buffer(request.begin() + 4, request.end());
			return {};
		}
		if (request == bytes({0x56, 0x04}) && activeSlot >= 0xa0 && activeSlot <= 0xa2) {
			Buffer response = bytes({0x57, 0x04, activeSlot, 0x0a});
			response.insert(response.end(), slotCurves[activeSlot - 0xa0].begin(), slotCurves[activeSlot - 0xa0].end());
			return response;
		}
		return originalXm4cReply(request);
	};
	for (auto slot : {EQ_PRESET::CUSTOM_1, EQ_PRESET::CUSTOM_2}) {
		std::vector<int> curve(10, slot == EQ_PRESET::CUSTOM_1 ? 3 : 9);
		xm4c.setEqualizerCustom(0, curve, slot);
		require((unsigned char)observedXm4c->sentPayloads.back()[2] == (unsigned char)slot,
			"Custom edits must address the selected slot, not Manual");
		xm4c.requestEqualizer();
		require(xm4c.getEqualizerPreset() == slot && xm4c.getEqualizerBand(9) == curve[9],
			"Custom write must read back the selected slot and curve");
	}
	xm4c.setEqualizerPreset(EQ_PRESET::CUSTOM_1);
	xm4c.requestEqualizer();
	require(xm4c.getEqualizerBand(0) == 3, "Custom 2 edits must not overwrite Custom 1");
	xm4c.requestSpeakToChatTiming();
	require(xm4c.hasSpeakToChatTiming() && xm4c.getSpeakToChatTimeout() == 1 &&
		xm4c.getSpeakToChatTimeoutSeconds() == std::vector<int>({5, 15, 30}),
		"Speak-to-Chat choices must come from device capabilities");
	// Simulate a phone changing the other fields after discovery.
	timing[2] = 2; timing[3] = 1;
	for (int option : {0, 1, 2, 3}) {
		xm4c.setSpeakToChatTimeout(option);
		require(observedXm4c->sentPayloads.back() == bytes({0xfc, 0x02, 0x02, 0x01, (unsigned char)option}),
			"Timeout write must preserve freshly read sensitivity and voice focus");
		xm4c.requestSpeakToChatTiming();
		require(xm4c.getSpeakToChatTimeout() == option, "Timeout readback must decode every option");
	}
	malformedTiming = true;
	auto timingWritesBefore = std::count(observedXm4c->sentPayloads.begin(), observedXm4c->sentPayloads.end(), bytes({0xfc, 0x02, 0x02, 0x01, 0x01}));
	expectRecoverable([&] { xm4c.setSpeakToChatTimeout(1); }, "Malformed read must block timing SET");
	require(std::count(observedXm4c->sentPayloads.begin(), observedXm4c->sentPayloads.end(), bytes({0xfc, 0x02, 0x02, 0x01, 0x01})) == timingWritesBefore,
		"Failed timing read must not send a guessed setting");
	for (auto invalid : {bytes({0xfb, 0x02, 3, 0, 0}), bytes({0xfb, 0x02, 0, 2, 0}), bytes({0xfb, 0x02, 0, 0, 4})}) {
		malformedTiming = false; timing = invalid;
		auto before = observedXm4c->sentPayloads.size();
		expectRecoverable([&] { xm4c.setSpeakToChatTimeout(1); }, "Invalid shared fields must block timeout writes");
		require(observedXm4c->sentPayloads.size() == before + 1, "Only the read may be sent for invalid shared fields");
	}
	observedXm4c->reply = originalXm4cReply;

	xm4c.setSpeakToChat(true);
	require(observedXm4c->sentPayloads.back() == bytes({0xf8, 0x02, 0x00, 0x01}), "XM4C Speak-to-Chat SET must use subtype 02");

	// A failed read-back must not confirm the values optimistically cached by a SET.
	observedXm4c->reply = [](const Buffer& request) -> Buffer {
		if (request == bytes({0xf6, 0x02})) return bytes({0xf7, 0x02});
		if (request == bytes({0x26, 0x05})) return bytes({0x27, 0x05, 0x7f, 0x00});
		if (request == bytes({0xe6, 0x01})) return bytes({0xe7, 0x01});
		if (request == bytes({0x56, 0x04})) return bytes({0x57, 0x04, 0xa0});
		return {};
	};
	expectRecoverable([&] { xm4c.requestSpeakToChat(); }, "truncated Speak-to-Chat read-back must fail");
	for (const auto& response : {bytes({0xf7, 0x02, 0x00}), bytes({0xf7, 0x02, 0x00, 0x02})}) {
		observedXm4c->reply = [response](const Buffer& request) -> Buffer {
			return request == bytes({0xf6, 0x02}) ? response : Buffer{};
		};
		expectRecoverable([&] { xm4c.requestSpeakToChat(); }, "Incomplete or invalid preview state must not confirm Speak-to-Chat");
	}
	observedXm4c->reply = [](const Buffer& request) -> Buffer {
		if (request == bytes({0x26, 0x05})) return bytes({0x27, 0x05, 0x7f, 0x00});
		if (request == bytes({0xe6, 0x01})) return bytes({0xe7, 0x01});
		if (request == bytes({0x56, 0x04})) return bytes({0x57, 0x04, 0xa0});
		return {};
	};
	expectRecoverable([&] { xm4c.requestAutoPowerOff(); }, "unknown auto power-off option must not become Off");
	expectRecoverable([&] { xm4c.requestDsee(); }, "truncated DSEE read-back must fail");
	expectRecoverable([&] { xm4c.requestEqualizer(); }, "truncated ten-band read-back must fail");

	// Connection-priority layouts are selected from capabilities, independently of DSEE.
	for (unsigned char function : {0xe1, 0xe3}) {
		auto fakeQuality = std::make_unique<FakeV2Connector>();
		auto* observedQuality = fakeQuality.get();
		unsigned char subtype = function == 0xe1 ? 0x00 : 0x02;
		int priority = 0;
		bool malformed = false;
		unsigned char codec = 0x02;
		observedQuality->reply = [&](const Buffer& request) -> Buffer {
			if (request == bytes({0x06, 0x00})) return bytes({0x07, 0x00, 1, function, 1});
			if (request == bytes({0x12, 0x02})) return bytes({0x13, 0x02, codec});
			if (request == bytes({0xe6, subtype}))
				return malformed ? bytes({0xe7, subtype, 0x7f}) : bytes({0xe7, subtype, (unsigned char)priority});
			return {};
		};
		BluetoothWrapper qualityBluetooth(std::move(fakeQuality));
		Headphones qualityHeadphones(qualityBluetooth);
		qualityHeadphones.setDeviceName("WH-1000XM4C");
		qualityHeadphones.requestConnectionQuality();
		require(qualityHeadphones.hasConnectionQuality() && qualityHeadphones.getConnectionQuality() == 0,
			"Sound-quality priority must be read from the advertised subtype");
		for (const auto& item : std::vector<std::pair<unsigned char, std::string>>{{0, "Negotiating"}, {1, "SBC"}, {2, "AAC"}, {0x10, "LDAC"}}) {
			codec = item.first;
			qualityHeadphones.requestCodec();
			require(qualityHeadphones.hasCodec() && qualityHeadphones.getCodec() == item.second,
				"Codec inquiry must report the current device value, including negotiation");
		}
		codec = 0xfe;
		expectRecoverable([&] { qualityHeadphones.requestCodec(); }, "Unknown codec must fail, not retain the previous codec");
		require(!qualityHeadphones.hasCodec() && qualityHeadphones.getCodec().empty(), "Failed codec read must clear stale display");
		priority = 1;
		qualityHeadphones.requestConnectionQuality();
		require(qualityHeadphones.getConnectionQuality() == 1, "Read-only priority must reflect changes made externally");
		malformed = true;
		expectRecoverable([&] { qualityHeadphones.requestConnectionQuality(); }, "Unknown priority must fail the refresh");
		require(std::none_of(observedQuality->sentPayloads.begin(), observedQuality->sentPayloads.end(), [](const Buffer& payload) {
			return !payload.empty() && (unsigned char)payload[0] == 0xe8;
		}), "Connection-priority and codec discovery must never send an audio-setting write");
	}
	{
		auto unsupported = std::make_unique<FakeV2Connector>();
		auto* observed = unsupported.get();
		observed->reply = [](const Buffer& request) -> Buffer {
			if (request == bytes({0x06, 0x00})) return bytes({0x07, 0x00, 1, 0xe7, 1});
			return {};
		};
		BluetoothWrapper bluetooth(std::move(unsupported));
		Headphones headphones(bluetooth);
		headphones.setDeviceName("WH-1000XM4C");
		expectRecoverable([&] { headphones.requestConnectionQuality(); }, "Do not guess an LE Audio connection layout");
		require(!headphones.hasConnectionQuality() && observed->sentPayloads.size() == 1,
			"Unsupported layout must not expose controls or probe guessed subtypes");
	}

	auto malformedCapabilities = std::make_unique<FakeV2Connector>();
	auto* observedMalformed = malformedCapabilities.get();
	observedMalformed->reply = [](const Buffer& request) -> Buffer {
		if (request == bytes({0x06, 0x00})) return bytes({0x07, 0x00, 0x02, 0x57, 0x0c});
		return {};
	};
	BluetoothWrapper malformedBluetooth(std::move(malformedCapabilities));
	Headphones malformedHeadphones(malformedBluetooth);
	malformedHeadphones.setDeviceName("WH-1000XM4C");
	malformedHeadphones.setAmbientSoundControl(true);
	malformedHeadphones.setAsmLevel(10);
	expectRecoverable([&] { malformedHeadphones.setChanges(); }, "truncated capabilities must prevent writes");
	require(observedMalformed->sentPayloads.size() == 1 && observedMalformed->sentPayloads[0] == bytes({0x06, 0x00}),
		"capability failure must not send an ANC SET");

	for (const auto& badPresets : {
		bytes({0x51, 0x04}),
		bytes({0x51, 0x04, 0x0a, 0x0d, 0x01, 0xa0, 0x04, 'x'}),
		bytes({0x51, 0x04, 0x0a, 0x0d, 0x02, 0x00, 0x00, 0x00, 0x00}),
		bytes({0x51, 0x04, 0x0a, 0x0d, 0x00, 0x7f}) })
	{
		auto malformedPresets = std::make_unique<FakeV2Connector>();
		malformedPresets->reply = [badPresets](const Buffer& request) -> Buffer {
			if (request == bytes({0x06, 0x00})) return bytes({0x07, 0x00, 0x02, 0x57, 0x0c, 0x6a, 0x04});
			if (request == bytes({0x56, 0x04})) return bytes({0x57, 0x04, 0x00, 0x0a, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6});
			if (request == bytes({0x50, 0x04, 0x01})) return badPresets;
			return {};
		};
		BluetoothWrapper presetBluetooth(std::move(malformedPresets));
		Headphones presetHeadphones(presetBluetooth);
		presetHeadphones.setDeviceName("WH-1000XM4C");
		presetHeadphones.requestEqualizer();
		expectRecoverable([&] { presetHeadphones.requestEqualizerPresets(); }, "malformed preset list must be rejected");
		require(presetHeadphones.getEqualizerPresets().empty(), "malformed list must not publish partial presets");
	}

	// Any other v2 headset that answered 66 17 with zeros must not be read as "Off" either.
	auto fakeZeros = std::make_unique<FakeV2Connector>();
	fakeZeros->reply = [](const Buffer& request) -> Buffer {
		if (request == bytes({ 0x66, 0x17 })) return bytes({ 0x67, 0x17, 0x00, 0x00, 0x00, 0x00, 0x00 });
		return {};
	};
	BluetoothWrapper bluetoothZeros(std::move(fakeZeros));
	Headphones zeros(bluetoothZeros);
	zeros.setDeviceName("WH-1000XM5");
	zeros.setAmbientSoundControl(true);
	zeros.setAsmLevel(7);
	zeros.setFocusOnVoice(false);
	zeros.setChanges();
	zeros.requestAmbientState();
	require(zeros.getAmbientSoundControl() && zeros.getAsmLevel() == 7, "a zeroed 67 17 reply overwrote the state");

	// Malformed inbound frames on the untrusted parser path must throw the recoverable type.
	// 61 (0x3D) is the escape sentry; a lone one at buffer end and one followed by a
	// non-escapable byte are the two unescape rejection paths.
	constexpr char ESCAPE_SENTRY = 61;
	expectRecoverable([&] { CommandSerializer::unpackBtMessage(Buffer{ ESCAPE_SENTRY }); },
		"dangling escape byte did not throw RecoverableException");
	expectRecoverable([&] { CommandSerializer::unpackBtMessage(Buffer{ ESCAPE_SENTRY, 0x00 }); },
		"unexpected escaped byte did not throw RecoverableException");
	expectRecoverable([] { CommandSerializer::unpackBtMessage(Buffer{ 0x00, 0x00, 0x00 }); },
		"under-minimum-size frame did not throw RecoverableException");

    // Synthetic XM4C list regression: the final record declares zero name bytes
    // but carries a literal placeholder before the playback slot.
    {
        const std::string macName = "Test Mac (é)";
        const std::string phoneName = "Test phone";
        Buffer capture = bytes({0x37, 0x00, 0x03});
        auto appendDevice = [&](const std::string& address, int slot, const std::string& name, int length) {
            capture.insert(capture.end(), address.begin(), address.end());
            capture.push_back((char)slot);
            capture.push_back((char)length);
            capture.insert(capture.end(), name.begin(), name.end());
        };
        appendDevice("00:00:00:00:00:01", 2, macName, (int)macName.size());
        appendDevice("00:00:00:00:00:02", 1, phoneName, (int)phoneName.size());
        appendDevice("00:00:00:00:00:03", 0, "Unknown Device", 0);
        capture.push_back(1); // playback belongs to slot 1 (phone), not list index 1

        auto readList = [&](const Buffer& response, const std::string& model) {
            auto fake = std::make_unique<FakeV2Connector>();
            fake->acceptTable2 = true;
            fake->reply = [&](const Buffer& request) -> Buffer {
                if (request == bytes({0x00, 0x00})) return bytes({0x01, 0x00, 0x03, 0x00, 0x30, 0x37, 0x00, 0x00});
                if (request == bytes({0x06, 0x00})) return bytes({0x07, 0x00, 0x01, 0x30, 0x01});
                if (request == bytes({0x36, 0x00})) return response;
                return {};
            };
            BluetoothWrapper bt(std::move(fake));
            Headphones hp(bt);
            hp.setDeviceName(model);
            hp.initDevice();
            hp.requestMultipoint();
            return std::make_pair(hp.hasPairedDevices(), hp.getPairedDevices());
        };
        auto [available, devices] = readList(capture, "WH-1000XM4C");
        require(available && devices.size() == 3, "XM4C placeholder discarded the connected-device list");
        require(devices[0].name == macName && devices[0].slot == 2 && !devices[0].playback,
            "Mac UTF-8 name or connection slot was misread");
        require(devices[1].name == phoneName && devices[1].slot == 1 && devices[1].playback,
            "phone name, slot or playback ownership was misread");
        require(devices[2].name == "Unknown Device" && devices[2].slot == 0 && !devices[2].playback,
            "placeholder must remain paired-only");
        require(!readList(capture, "WH-1000XM6").first, "XM4C workaround leaked to unrelated models");

        Buffer standard = capture;
        const size_t lengthOffset = standard.size() - 16;
        standard[lengthOffset] = 14;
        require(readList(standard, "WH-1000XM4C").first, "standard length-prefixed name was rejected");
        Buffer emptyName = capture;
        emptyName.erase(emptyName.end() - 15, emptyName.end() - 1);
        require(readList(emptyName, "WH-1000XM4C").first, "ordinary empty name was rejected");
        for (size_t length = 0; length < capture.size(); ++length) {
            require(!readList(Buffer(capture.begin(), capture.begin() + length), "WH-1000XM4C").first,
                "truncated XM4C list was accepted");
        }
        Buffer garbage = capture;
        garbage[garbage.size() - 15] = 'X';
        require(!readList(garbage, "WH-1000XM4C").first, "arbitrary uncounted name bytes were accepted");
        garbage = capture;
        garbage.push_back(0);
        require(!readList(garbage, "WH-1000XM4C").first, "trailing garbage was accepted");
    }

	std::cout << "XM4 / multipoint / XM6 protocol tests passed\n";
	return 0;
}
