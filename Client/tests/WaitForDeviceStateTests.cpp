#include "WaitForDeviceState.h"
#include <iostream>
#include <stdexcept>

static void require(bool condition, const char* message)
{
	if (!condition) throw std::runtime_error(message);
}

int main()
{
	using namespace std::chrono_literals;
	int reads = 0;
	waitForDeviceState([&] { ++reads; return true; }, "unexpected timeout");
	require(reads == 1, "already-applied state must not be polled again");

	// Model the hardware returning its old state for two inquiries after ACK.
	reads = 0;
	waitForDeviceState([&] { return ++reads >= 3; }, "device never applied setting", 1s, 0ms);
	require(reads == 3, "delayed application must be accepted after a fresh matching read");

	reads = 0;
	try {
		waitForDeviceState([&] { ++reads; return false; }, "not applied", 0ms);
		throw std::logic_error("timeout accepted stale state");
	} catch (const RecoverableException& error) {
		require(std::string(error.what()) == "not applied", "timeout must retain its actionable error");
	}
	require(reads == 1, "expired deadline must not issue additional inquiries");

	// A failed fresh inquiry must propagate, not fall back to the optimistic cache.
	try {
		waitForDeviceState([]() -> bool { throw RecoverableException("read failed"); }, "not applied");
		throw std::logic_error("failed inquiry accepted cached state");
	} catch (const RecoverableException& error) {
		require(std::string(error.what()) == "read failed", "read failure was swallowed");
	}
	std::cout << "Device write-readback tests passed\n";
}
