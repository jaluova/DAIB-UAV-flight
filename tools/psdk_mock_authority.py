#!/usr/bin/env python3
"""Dry-run contract test for the PSDK flight-control authority patch.

This deliberately does not import or call DJI's SDK. It models the small
state machine that the Manifold sample must implement around the SDK:
authority callbacks set an abort flag, monitored loops observe it, and normal
release is not mistaken for RC takeover.
"""

from dataclasses import dataclass, field
from typing import List, Optional


RC = "RC"
OSDK = "OSDK"  # PSDK is named OSDK in the flight-controller API.


@dataclass
class AuthorityPatchModel:
    owner: str = RC
    abort_requested: bool = False
    release_in_progress: bool = False
    calls: List[str] = field(default_factory=list)

    def obtain_authority(self) -> None:
        self.calls.append("obtain_authority")
        self.owner = OSDK

    def release_authority(self) -> None:
        self.release_in_progress = True
        self.calls.append("release_authority")
        self.owner = RC
        self.on_authority_event("RC_SWITCH_MODE", RC)
        self.release_in_progress = False

    def on_authority_event(self, reason: str, owner: str) -> None:
        self.owner = owner
        if owner != OSDK and not self.release_in_progress:
            self.abort_requested = True
            self.calls.append(f"abort:{reason}")

    def run_takeoff_hover_landing(self, takeover_at: Optional[int] = None) -> List[str]:
        """Run a bounded sample loop; takeover_at injects an async RC event."""
        self.obtain_authority()
        self.calls.append("takeoff")

        for tick in range(5):
            if takeover_at == tick:
                self.on_authority_event("RC_SWITCH_MODE", RC)
            if self.abort_requested:
                self.calls.append("sample_abort")
                return self.calls

        self.calls.append("landing")
        if not self.abort_requested:
            self.release_authority()
        return self.calls


def assert_equal(actual, expected, label):
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")


def test_normal_completion():
    model = AuthorityPatchModel()
    calls = model.run_takeoff_hover_landing()
    assert_equal(calls, ["obtain_authority", "takeoff", "landing", "release_authority"],
                 "normal completion")
    assert_equal(model.abort_requested, False, "normal release abort flag")
    assert_equal(model.owner, RC, "normal release owner")


def test_rc_takeover_aborts_before_landing():
    model = AuthorityPatchModel()
    calls = model.run_takeoff_hover_landing(takeover_at=2)
    assert_equal(calls, [
        "obtain_authority", "takeoff", "abort:RC_SWITCH_MODE", "sample_abort"
    ], "RC takeover")
    if "landing" in calls or "release_authority" in calls:
        raise AssertionError("RC takeover must not continue to landing/release")
    assert_equal(model.owner, RC, "RC takeover owner")


def test_sdk_loss_uses_same_abort_path():
    model = AuthorityPatchModel()
    model.obtain_authority()
    model.on_authority_event("OSDK_LOST", RC)
    assert_equal(model.abort_requested, True, "SDK-loss abort flag")
    assert_equal(model.owner, RC, "SDK-loss owner")


def test_normal_release_is_not_abort():
    model = AuthorityPatchModel()
    model.obtain_authority()
    model.release_authority()
    assert_equal(model.abort_requested, False, "normal release abort flag")
    assert_equal(model.calls, ["obtain_authority", "release_authority"],
                 "normal release calls")


def test_abort_state_must_be_reset_for_next_sample():
    model = AuthorityPatchModel()
    model.run_takeoff_hover_landing(takeover_at=0)
    model.abort_requested = False
    model.calls.clear()
    calls = model.run_takeoff_hover_landing()
    assert_equal(calls, ["obtain_authority", "takeoff", "landing", "release_authority"],
                 "next sample after reset")


if __name__ == "__main__":
    tests = [
        test_normal_completion,
        test_rc_takeover_aborts_before_landing,
        test_sdk_loss_uses_same_abort_path,
        test_normal_release_is_not_abort,
        test_abort_state_must_be_reset_for_next_sample,
    ]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"{len(tests)} dry-run authority tests passed")
