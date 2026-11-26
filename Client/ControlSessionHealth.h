#pragma once

// Feed only completed heartbeat attempts, never optional capability probes or
// cached getters. A reply to either basic inquiry proves the session is alive.
class ControlSessionHealth {
public:
    enum class State { Responsive, Checking, Unresponsive };

    State record(bool receivedReply) {
        if (receivedReply) failures = 0;
        else if (failures < failureLimit) ++failures;
        return failures == 0 ? State::Responsive
            : failures < failureLimit ? State::Checking : State::Unresponsive;
    }

    void reset() { failures = 0; }

private:
    static constexpr unsigned failureLimit = 3;
    unsigned failures = 0;
};
