// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VestToken} from "../src/VestToken.sol";
import {LinearVesting} from "../src/LinearVesting.sol";
import {FalseReturnToken, RevertingToken, NoReturnToken} from "./mocks/MockTokens.sol";

contract LinearVestingTest is Test {
    uint64 internal constant START = 1_700_000_000;
    uint64 internal constant CLIFF = 90 days;
    uint64 internal constant DURATION = 360 days;
    uint256 internal constant TOTAL = 1_000_000e18;

    VestToken internal token;
    LinearVesting internal vesting;

    address internal deployer = makeAddr("deployer");
    address internal beneficiary = makeAddr("beneficiary");
    address internal stranger = makeAddr("stranger");

    event Released(uint256 amount);

    function setUp() public {
        vm.prank(deployer);
        token = new VestToken();
        vesting = new LinearVesting(address(token), beneficiary, START, CLIFF, DURATION);
        vm.prank(deployer);
        token.transfer(address(vesting), TOTAL);
        vm.warp(START - 1 days);
    }

    function _newVesting(uint64 start, uint64 cliffSeconds, uint64 durationSeconds, uint256 amount)
        internal
        returns (LinearVesting v)
    {
        v = new LinearVesting(address(token), beneficiary, start, cliffSeconds, durationSeconds);
        vm.prank(deployer);
        token.transfer(address(v), amount);
    }

    // ---------------------------------------------------------------- constructor

    function test_Constructor_StoresParameters() public view {
        assertEq(address(vesting.token()), address(token));
        assertEq(vesting.beneficiary(), beneficiary);
        assertEq(vesting.start(), START);
        assertEq(vesting.cliffSeconds(), CLIFF);
        assertEq(vesting.durationSeconds(), DURATION);
        assertEq(vesting.cliff(), uint256(START) + CLIFF);
        assertEq(vesting.end(), uint256(START) + DURATION);
        assertEq(vesting.released(), 0);
        assertEq(vesting.totalAllocation(), TOTAL);
    }

    function test_Constructor_AllowsCliffEqualToDuration() public {
        LinearVesting v = new LinearVesting(address(token), beneficiary, START, DURATION, DURATION);
        assertEq(v.cliffSeconds(), DURATION);
    }

    function test_RevertWhen_TokenIsZero() public {
        vm.expectRevert(LinearVesting.ZeroAddress.selector);
        new LinearVesting(address(0), beneficiary, START, CLIFF, DURATION);
    }

    function test_RevertWhen_BeneficiaryIsZero() public {
        vm.expectRevert(LinearVesting.ZeroAddress.selector);
        new LinearVesting(address(token), address(0), START, CLIFF, DURATION);
    }

    function test_RevertWhen_DurationIsZero() public {
        vm.expectRevert(LinearVesting.ZeroDuration.selector);
        new LinearVesting(address(token), beneficiary, START, 0, 0);
    }

    function test_RevertWhen_CliffExceedsDuration() public {
        vm.expectRevert(LinearVesting.CliffExceedsDuration.selector);
        new LinearVesting(address(token), beneficiary, START, DURATION + 1, DURATION);
    }

    // ---------------------------------------------------------------- schedule: before the cliff

    function test_BeforeStart_NothingVested() public {
        assertEq(vesting.vestedAmount(0), 0);
        assertEq(vesting.vestedAmount(START - 1), 0);
        assertEq(vesting.releasable(), 0);
        vm.expectRevert(LinearVesting.NothingToRelease.selector);
        vesting.release();
    }

    function test_BeforeCliff_NothingVested() public {
        vm.warp(START + CLIFF - 1);
        assertEq(vesting.vestedAmount(START), 0);
        assertEq(vesting.vestedAmount(START + CLIFF - 1), 0);
        assertEq(vesting.releasable(), 0);
        vm.expectRevert(LinearVesting.NothingToRelease.selector);
        vesting.release();
        assertEq(token.balanceOf(beneficiary), 0);
        assertEq(vesting.released(), 0);
    }

    // ---------------------------------------------------------------- schedule: at the cliff

    function test_AtCliff_LinearPortionVestsAtOnce() public {
        uint256 expected = TOTAL * CLIFF / DURATION; // 25% of TOTAL
        assertEq(vesting.vestedAmount(START + CLIFF), expected);

        vm.warp(START + CLIFF);
        vm.expectEmit(true, true, true, true, address(vesting));
        emit Released(expected);
        vesting.release();

        assertEq(token.balanceOf(beneficiary), expected);
        assertEq(vesting.released(), expected);
        assertEq(token.balanceOf(address(vesting)), TOTAL - expected);
        assertEq(vesting.totalAllocation(), TOTAL);
        assertEq(vesting.releasable(), 0);
    }

    // ---------------------------------------------------------------- schedule: midway

    function test_Midway_HalfVested() public view {
        assertEq(vesting.vestedAmount(START + DURATION / 2), TOTAL / 2);
    }

    function test_Midway_ReleaseThenReleaseAgainLater() public {
        vm.warp(START + DURATION / 2);
        vesting.release();
        assertEq(token.balanceOf(beneficiary), TOTAL / 2);
        assertEq(vesting.released(), TOTAL / 2);

        // Nothing new has vested in the same second.
        vm.expectRevert(LinearVesting.NothingToRelease.selector);
        vesting.release();

        // A quarter of the schedule later, exactly another quarter is releasable.
        vm.warp(START + (DURATION * 3) / 4);
        assertEq(vesting.releasable(), TOTAL / 4);
        vesting.release();
        assertEq(token.balanceOf(beneficiary), (TOTAL * 3) / 4);
        assertEq(vesting.released(), (TOTAL * 3) / 4);
    }

    function test_Midway_TotalAllocationUnchangedByRelease() public {
        vm.warp(START + DURATION / 2);
        vesting.release();
        assertEq(vesting.totalAllocation(), TOTAL);
        assertEq(vesting.vestedAmount(START + DURATION), TOTAL);
    }

    // ---------------------------------------------------------------- schedule: at and after the end

    function test_AtEnd_EverythingVested() public {
        assertEq(vesting.vestedAmount(START + DURATION - 1), TOTAL * (DURATION - 1) / DURATION);
        assertEq(vesting.vestedAmount(START + DURATION), TOTAL);

        vm.warp(START + DURATION);
        vesting.release();
        assertEq(token.balanceOf(beneficiary), TOTAL);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(vesting.released(), TOTAL);
    }

    function test_AfterEnd_EverythingVested_NoOverRelease() public {
        assertEq(vesting.vestedAmount(START + DURATION + 1), TOTAL);
        assertEq(vesting.vestedAmount(type(uint64).max), TOTAL);

        vm.warp(START + DURATION + 10 * 365 days);
        vesting.release();
        assertEq(token.balanceOf(beneficiary), TOTAL);
        assertEq(vesting.released(), TOTAL);

        vm.expectRevert(LinearVesting.NothingToRelease.selector);
        vesting.release();
    }

    function test_PartialThenFinalRelease_SumsToTotal() public {
        vm.warp(START + CLIFF);
        vesting.release();
        vm.warp(START + DURATION / 2);
        vesting.release();
        vm.warp(START + DURATION + 1);
        vesting.release();
        assertEq(token.balanceOf(beneficiary), TOTAL);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(vesting.released(), TOTAL);
    }

    // ---------------------------------------------------------------- odd total: rounding down

    function test_OddTotal_RoundsDownAndSettlesAtEnd() public {
        // 1,000,001 base units over 3 seconds: 333,333 / 666,667 / 1,000,001.
        LinearVesting v = _newVesting(START, 0, 3, 1_000_001);
        assertEq(v.vestedAmount(START), 0);
        assertEq(v.vestedAmount(START + 1), 333_333);
        assertEq(v.vestedAmount(START + 2), 666_667);
        assertEq(v.vestedAmount(START + 3), 1_000_001);

        vm.warp(START + 1);
        v.release();
        assertEq(token.balanceOf(beneficiary), 333_333);
        vm.warp(START + 2);
        v.release();
        assertEq(token.balanceOf(beneficiary), 666_667);
        vm.warp(START + 3);
        v.release();
        assertEq(token.balanceOf(beneficiary), 1_000_001);
        assertEq(token.balanceOf(address(v)), 0);
    }

    function test_OddTotal_SevenOverTen_FloorEveryStep() public {
        LinearVesting v = _newVesting(START, 0, 10, 7);
        uint256[11] memory expected = [uint256(0), 0, 1, 2, 2, 3, 4, 4, 5, 6, 7];
        for (uint64 i = 0; i <= 10; i++) {
            assertEq(v.vestedAmount(START + i), expected[i]);
        }
    }

    function test_OddTotal_TinyAllocationNothingUntilItRoundsUp() public {
        // 1 wei over 100 seconds vests only at the very end.
        LinearVesting v = _newVesting(START, 0, 100, 1);
        vm.warp(START + 99);
        assertEq(v.releasable(), 0);
        vm.expectRevert(LinearVesting.NothingToRelease.selector);
        v.release();
        vm.warp(START + 100);
        v.release();
        assertEq(token.balanceOf(beneficiary), 1);
    }

    // ---------------------------------------------------------------- donations after start

    function test_DonationAfterStart_JoinsScheduleImmediately() public {
        uint256 donation = 400_000e18;

        vm.warp(START + DURATION / 2);
        vesting.release();
        assertEq(token.balanceOf(beneficiary), TOTAL / 2);

        // Extra tokens arrive mid-schedule.
        vm.prank(deployer);
        token.transfer(address(vesting), donation);
        uint256 newTotal = TOTAL + donation;
        assertEq(vesting.totalAllocation(), newTotal);

        // Half of the new total is vested; half of the old total was already released.
        assertEq(vesting.vestedAmount(START + DURATION / 2), newTotal / 2);
        assertEq(vesting.releasable(), donation / 2);
        vesting.release();
        assertEq(token.balanceOf(beneficiary), newTotal / 2);

        vm.warp(START + DURATION);
        vesting.release();
        assertEq(token.balanceOf(beneficiary), newTotal);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(vesting.released(), newTotal);
    }

    function test_DonationAfterEnd_IsFullyReleasable() public {
        vm.warp(START + DURATION);
        vesting.release();
        assertEq(token.balanceOf(beneficiary), TOTAL);

        vm.prank(deployer);
        token.transfer(address(vesting), 123);
        assertEq(vesting.releasable(), 123);
        vesting.release();
        assertEq(token.balanceOf(beneficiary), TOTAL + 123);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function test_DonationBeforeCliff_StillLocked() public {
        vm.prank(deployer);
        token.transfer(address(vesting), 1e18);
        vm.warp(START + CLIFF - 1);
        assertEq(vesting.releasable(), 0);
        vm.expectRevert(LinearVesting.NothingToRelease.selector);
        vesting.release();
    }

    function test_EmptyContract_NothingToRelease() public {
        LinearVesting v = new LinearVesting(address(token), beneficiary, START, CLIFF, DURATION);
        vm.warp(START + DURATION);
        assertEq(v.totalAllocation(), 0);
        assertEq(v.vestedAmount(START + DURATION), 0);
        vm.expectRevert(LinearVesting.NothingToRelease.selector);
        v.release();
    }

    // ---------------------------------------------------------------- other schedules

    function test_ZeroCliff_VestsFromStart() public {
        LinearVesting v = _newVesting(START, 0, DURATION, TOTAL);
        assertEq(v.vestedAmount(START - 1), 0);
        assertEq(v.vestedAmount(START), 0);
        assertEq(v.vestedAmount(START + 1), TOTAL / DURATION);
        vm.warp(START + 1);
        v.release();
        assertEq(token.balanceOf(beneficiary), TOTAL / DURATION);
    }

    function test_CliffEqualsDuration_AllOrNothing() public {
        LinearVesting v = _newVesting(START, DURATION, DURATION, TOTAL);
        assertEq(v.vestedAmount(START + DURATION - 1), 0);
        assertEq(v.vestedAmount(START + DURATION), TOTAL);
        vm.warp(START + DURATION - 1);
        vm.expectRevert(LinearVesting.NothingToRelease.selector);
        v.release();
        vm.warp(START + DURATION);
        v.release();
        assertEq(token.balanceOf(beneficiary), TOTAL);
    }

    function test_StartInThePast_VestsImmediately() public {
        vm.warp(START + DURATION);
        LinearVesting v = _newVesting(START, CLIFF, DURATION, TOTAL);
        assertEq(v.releasable(), TOTAL);
        v.release();
        assertEq(token.balanceOf(beneficiary), TOTAL);
    }

    function test_MaxTimestamps_DoNotOverflow() public {
        LinearVesting v =
            new LinearVesting(address(token), beneficiary, type(uint64).max, type(uint64).max, type(uint64).max);
        assertEq(v.cliff(), 2 * uint256(type(uint64).max));
        assertEq(v.vestedAmount(type(uint64).max), 0);
    }

    // ---------------------------------------------------------------- access & permissionlessness

    function test_AnyoneCanRelease_FundsGoToBeneficiary() public {
        vm.warp(START + DURATION);
        vm.prank(stranger);
        vesting.release();
        assertEq(token.balanceOf(beneficiary), TOTAL);
        assertEq(token.balanceOf(stranger), 0);
    }

    function test_NoEth() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(vesting).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(vesting).balance, 0);
    }

    function test_NoAdminEntryPoints() public {
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeWithSignature("revoke()");
        calls[1] = abi.encodeWithSignature("owner()");
        calls[2] = abi.encodeWithSignature("setBeneficiary(address)", stranger);
        calls[3] = abi.encodeWithSignature("withdraw(uint256)", 1);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok,) = address(vesting).call(calls[i]);
            assertFalse(ok, "unexpected admin entry point");
        }
    }

    // ---------------------------------------------------------------- token transfer failure handling

    function test_RevertWhen_TokenReturnsFalse() public {
        FalseReturnToken bad = new FalseReturnToken();
        LinearVesting v = new LinearVesting(address(bad), beneficiary, START, 0, DURATION);
        bad.mint(address(v), 1e18);
        vm.warp(START + DURATION);
        vm.expectRevert(LinearVesting.TransferFailed.selector);
        v.release();
        assertEq(v.released(), 0);
    }

    function test_RevertWhen_TokenReverts() public {
        RevertingToken bad = new RevertingToken();
        LinearVesting v = new LinearVesting(address(bad), beneficiary, START, 0, DURATION);
        bad.mint(address(v), 1e18);
        vm.warp(START + DURATION);
        vm.expectRevert(LinearVesting.TransferFailed.selector);
        v.release();
        assertEq(v.released(), 0);
    }

    function test_NoReturnToken_IsAccepted() public {
        NoReturnToken usdtLike = new NoReturnToken();
        LinearVesting v = new LinearVesting(address(usdtLike), beneficiary, START, 0, DURATION);
        usdtLike.mint(address(v), 1e18);
        vm.warp(START + DURATION);
        v.release();
        assertEq(usdtLike.balanceOf(beneficiary), 1e18);
        assertEq(v.released(), 1e18);
    }

    // ---------------------------------------------------------------- fuzz / invariants

    function testFuzz_VestedNeverExceedsTotalAndIsMonotone(uint64 t1, uint64 t2) public view {
        if (t1 > t2) (t1, t2) = (t2, t1);
        uint256 v1 = vesting.vestedAmount(t1);
        uint256 v2 = vesting.vestedAmount(t2);
        assertLe(v1, v2);
        assertLe(v2, TOTAL);
        if (t2 < START + CLIFF) assertEq(v2, 0);
        if (t1 >= START + DURATION) assertEq(v1, TOTAL);
    }

    function testFuzz_ReleasesNeverExceedVestedAndSumToTotal(uint64 t1, uint64 t2, uint64 t3) public {
        t1 = uint64(bound(t1, START, START + DURATION));
        t2 = uint64(bound(t2, t1, START + DURATION));
        t3 = uint64(bound(t3, t2, START + DURATION));
        uint64[3] memory ts = [t1, t2, t3];
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(ts[i]);
            uint256 releasable = vesting.releasable();
            if (releasable == 0) {
                vm.expectRevert(LinearVesting.NothingToRelease.selector);
                vesting.release();
            } else {
                vesting.release();
            }
            assertEq(token.balanceOf(beneficiary), vesting.vestedAmount(ts[i]));
            assertEq(vesting.released(), token.balanceOf(beneficiary));
        }
        vm.warp(START + DURATION);
        if (vesting.releasable() > 0) vesting.release();
        assertEq(token.balanceOf(beneficiary), TOTAL);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function testFuzz_Schedule(uint64 start, uint64 cliffSeconds, uint64 durationSeconds, uint96 amount, uint64 t)
        public
    {
        durationSeconds = uint64(bound(durationSeconds, 1, 100 * 365 days));
        cliffSeconds = uint64(bound(cliffSeconds, 0, durationSeconds));
        start = uint64(bound(start, 0, type(uint64).max - durationSeconds));
        amount = uint96(bound(amount, 1, TOTAL));

        LinearVesting v = _newVesting(start, cliffSeconds, durationSeconds, amount);
        uint256 vested = v.vestedAmount(t);
        if (t < uint256(start) + cliffSeconds) {
            assertEq(vested, 0);
        } else if (t >= uint256(start) + durationSeconds) {
            assertEq(vested, amount);
        } else {
            assertEq(vested, uint256(amount) * (t - start) / durationSeconds);
            assertLe(vested, amount);
        }
    }
}
