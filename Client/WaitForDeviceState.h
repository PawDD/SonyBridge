#pragma once

#include "Exceptions.h"
#include <algorithm>
#include <chrono>
#include <thread>

// Transport ACKs can precede application of a setting. Retry only the read-back,
// never the SET. The deadline is checked between bounded transport operations.
template <typename ReadAndMatch>
void waitForDeviceState(ReadAndMatch readAndMatch, const char* error,
	std::chrono::milliseconds timeout = std::chrono::milliseconds(1500),
	std::chrono::milliseconds interval = std::chrono::milliseconds(100))
{
	using Clock = std::chrono::steady_clock;
	const auto deadline = Clock::now() + timeout;
	for (;;)
	{
		if (readAndMatch()) return;
		const auto now = Clock::now();
		if (now >= deadline) throw RecoverableException(error);
		std::this_thread::sleep_until(std::min(deadline, now + interval));
	}
}
