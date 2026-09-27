// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {VestToken} from "../src/VestToken.sol";
import {LinearVesting} from "../src/LinearVesting.sol";

/// @dev Drives the deployment script with in-memory configs. It never reads or writes the
///      process environment (`vm.setEnv` is forbidden: tests share one environment and run in
///      parallel), so `run()` itself is exercised only by `forge script` (see script/README.md).
contract DeployTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant ANVIL_CHAIN_ID = 31337;

    address internal constant ANVIL_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant ANVIL_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address internal constant ANVIL_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;

    Deploy internal script;

    function setUp() public {
        script = new Deploy();
        vm.chainId(ANVIL_CHAIN_ID);
    }

    // ---------------------------------------------------------------- helpers

    function _entry(address account, uint256 amount, uint64 start, uint64 cliff, uint64 duration)
        internal
        pure
        returns (Deploy.Beneficiary memory)
    {
        return Deploy.Beneficiary({
            account: account, amount: amount, start: start, cliffSeconds: cliff, durationSeconds: duration
        });
    }

    function _config(uint256 n) internal pure returns (Deploy.Config memory cfg) {
        cfg.chainId = ANVIL_CHAIN_ID;
        cfg.beneficiaries = new Deploy.Beneficiary[](n);
        for (uint256 i = 0; i < n; i++) {
            cfg.beneficiaries[i] = _entry(
                address(uint160(0x1000 + i)), (i + 1) * 1_000e18 + 1, uint64(1_800_000_000 + i), 30 days, 360 days
            );
        }
    }

    function _threeEntryJson() internal pure returns (string memory) {
        // Keys deliberately in different orders per object; amounts as decimal strings; an extra
        // unknown key that must be ignored.
        return string.concat(
            '{"beneficiaries":[',
            '{"account":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8","amount":"100000000000000000000000000",',
            '"start":1800000000,"cliffSeconds":7776000,"durationSeconds":31536000},',
            '{"durationSeconds":63072000,"cliffSeconds":15552000,"start":1800000001,',
            '"amount":"50000000000000000000000001","account":"0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"},',
            '{"amount":"25000000000000000000000000","account":"0x90F79bf6EB2c4f870365E785982E1f101E93b906",',
            '"start":1800000002,"durationSeconds":7776000,"cliffSeconds":0,"note":"ignored"}',
            '],"chainId":31337}'
        );
    }

    /// @dev Asserts that `deploy(cfg)` reverts with `err` and that nothing was created.
    function _assertRejected(Deploy.Config memory cfg, bytes memory err) internal {
        uint256 nonceBefore = vm.getNonce(DEFAULT_SENDER);
        address firstCreate = vm.computeCreateAddress(DEFAULT_SENDER, nonceBefore);

        vm.expectRevert(err);
        script.validate(cfg);

        vm.expectRevert(err);
        script.deploy(cfg);

        assertEq(vm.getNonce(DEFAULT_SENDER), nonceBefore, "a transaction was sent");
        assertEq(firstCreate.code.length, 0, "a contract was deployed");
    }

    // ---------------------------------------------------------------- parsing

    function test_ParseConfig_ReadsEveryFieldRegardlessOfKeyOrder() public view {
        Deploy.Config memory cfg = script.parseConfig(_threeEntryJson());

        assertEq(cfg.chainId, 31337);
        assertEq(cfg.beneficiaries.length, 3);

        assertEq(cfg.beneficiaries[0].account, ANVIL_1);
        assertEq(cfg.beneficiaries[0].amount, 100_000_000e18);
        assertEq(cfg.beneficiaries[0].start, 1_800_000_000);
        assertEq(cfg.beneficiaries[0].cliffSeconds, 7_776_000);
        assertEq(cfg.beneficiaries[0].durationSeconds, 31_536_000);

        assertEq(cfg.beneficiaries[1].account, ANVIL_2);
        assertEq(cfg.beneficiaries[1].amount, 50_000_000e18 + 1);
        assertEq(cfg.beneficiaries[1].start, 1_800_000_001);
        assertEq(cfg.beneficiaries[1].cliffSeconds, 15_552_000);
        assertEq(cfg.beneficiaries[1].durationSeconds, 63_072_000);

        assertEq(cfg.beneficiaries[2].account, ANVIL_3);
        assertEq(cfg.beneficiaries[2].amount, 25_000_000e18);
        assertEq(cfg.beneficiaries[2].start, 1_800_000_002);
        assertEq(cfg.beneficiaries[2].cliffSeconds, 0);
        assertEq(cfg.beneficiaries[2].durationSeconds, 7_776_000);
    }

    function test_ParseConfig_AcceptsAmountAsJsonNumber() public view {
        string memory json = '{"chainId":31337,"beneficiaries":[{"account":"0x0000000000000000000000000000000000000001",'
            '"amount":1000000000000000000000000000,"start":0,"cliffSeconds":0,"durationSeconds":1}]}';
        Deploy.Config memory cfg = script.parseConfig(json);
        assertEq(cfg.beneficiaries[0].amount, SUPPLY);
    }

    function test_ParseConfig_AcceptsMaximumUint64Start() public view {
        string memory json = '{"chainId":1,"beneficiaries":[{"account":"0x0000000000000000000000000000000000000001",'
            '"amount":"1","start":18446744073709551615,"cliffSeconds":18446744073709551615,'
            '"durationSeconds":18446744073709551615}]}';
        Deploy.Config memory cfg = script.parseConfig(json);
        assertEq(cfg.chainId, 1);
        assertEq(cfg.beneficiaries[0].start, type(uint64).max);
        assertEq(cfg.beneficiaries[0].cliffSeconds, type(uint64).max);
        assertEq(cfg.beneficiaries[0].durationSeconds, type(uint64).max);
    }

    function test_ParseConfig_EmptyArrayYieldsNoEntries() public view {
        Deploy.Config memory cfg = script.parseConfig('{"chainId":31337,"beneficiaries":[]}');
        assertEq(cfg.beneficiaries.length, 0);
    }

    function test_ParseConfig_RevertsWhenStartExceedsUint64() public {
        string memory json = '{"chainId":31337,"beneficiaries":[{"account":"0x0000000000000000000000000000000000000001",'
            '"amount":"1","start":18446744073709551616,"cliffSeconds":0,"durationSeconds":1}]}';
        vm.expectRevert(abi.encodeWithSelector(Deploy.ValueOutOfRange.selector, "start", 0, 2 ** 64));
        script.parseConfig(json);
    }

    function test_ParseConfig_RevertsWhenDurationExceedsUint64() public {
        string memory json = '{"chainId":31337,"beneficiaries":[{"account":"0x0000000000000000000000000000000000000001",'
            '"amount":"1","start":0,"cliffSeconds":0,"durationSeconds":"99999999999999999999"}]}';
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.ValueOutOfRange.selector, "durationSeconds", 0, 99_999_999_999_999_999_999)
        );
        script.parseConfig(json);
    }

    function test_ParseConfig_RevertsWhenChainIdMissing() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.ConfigMissingKey.selector, "chainId"));
        script.parseConfig('{"beneficiaries":[]}');
    }

    function test_ParseConfig_RevertsWhenBeneficiariesMissing() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.ConfigMissingKey.selector, "beneficiaries"));
        script.parseConfig('{"chainId":31337}');
    }

    function test_ParseConfig_RevertsWhenAnEntryLacksAField() public {
        string memory json = '{"chainId":31337,"beneficiaries":[{"account":"0x0000000000000000000000000000000000000001",'
            '"amount":"1","start":0,"durationSeconds":1}]}';
        vm.expectRevert();
        script.parseConfig(json);
    }

    function test_DefaultConfig_MatchesShippedAnvilConfig() public view {
        Deploy.Config memory cfg = script.parseConfig(script.DEFAULT_CONFIG());
        assertEq(cfg.chainId, ANVIL_CHAIN_ID);
        assertEq(cfg.beneficiaries.length, 3);
        assertEq(cfg.beneficiaries[0].account, ANVIL_1);
        assertEq(cfg.beneficiaries[0].amount, 100_000_000e18);
        assertEq(cfg.beneficiaries[1].account, ANVIL_2);
        assertEq(cfg.beneficiaries[1].amount, 50_000_000e18);
        assertEq(cfg.beneficiaries[2].account, ANVIL_3);
        assertEq(cfg.beneficiaries[2].amount, 25_000_000e18);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(cfg.beneficiaries[i].start, 1_800_000_000);
            assertLe(cfg.beneficiaries[i].cliffSeconds, cfg.beneficiaries[i].durationSeconds);
        }
        script.validate(cfg);
    }

    // ---------------------------------------------------------------- deployment wiring

    function test_DeployFromJson_WiresEveryContract() public {
        Deploy.Config memory cfg = script.parseConfig(_threeEntryJson());
        Deploy.Deployment memory d = script.deployFromJson(_threeEntryJson());

        VestToken token = VestToken(d.token);
        assertEq(token.name(), "Vest Demo");
        assertEq(token.symbol(), "VDEMO");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(d.vestings.length, 3);

        uint256 allocated;
        for (uint256 i = 0; i < 3; i++) {
            LinearVesting v = LinearVesting(d.vestings[i]);
            Deploy.Beneficiary memory b = cfg.beneficiaries[i];
            assertEq(address(v.token()), d.token, "token");
            assertEq(v.beneficiary(), b.account, "beneficiary");
            assertEq(v.start(), b.start, "start");
            assertEq(v.cliffSeconds(), b.cliffSeconds, "cliff");
            assertEq(v.durationSeconds(), b.durationSeconds, "duration");
            assertEq(v.released(), 0, "released");
            assertEq(token.balanceOf(d.vestings[i]), b.amount, "vault balance");
            assertEq(v.totalAllocation(), b.amount, "allocation");
            assertEq(token.balanceOf(b.account), 0, "beneficiary holds nothing yet");
            allocated += b.amount;
        }
        assertEq(token.balanceOf(d.deployer), SUPPLY - allocated, "remainder stays with deployer");

        // Each vault is distinct and none of them is the token.
        assertTrue(d.vestings[0] != d.vestings[1] && d.vestings[1] != d.vestings[2] && d.vestings[0] != d.vestings[2]);
        assertTrue(d.vestings[0] != d.token);
    }

    function test_Deploy_VaultsReleaseToTheirBeneficiaries() public {
        Deploy.Config memory cfg = _config(2);
        Deploy.Deployment memory d = script.deploy(cfg);
        VestToken token = VestToken(d.token);

        for (uint256 i = 0; i < 2; i++) {
            LinearVesting v = LinearVesting(d.vestings[i]);
            Deploy.Beneficiary memory b = cfg.beneficiaries[i];

            vm.warp(uint256(b.start) + b.cliffSeconds - 1);
            vm.expectRevert(LinearVesting.NothingToRelease.selector);
            v.release();

            vm.warp(uint256(b.start) + b.durationSeconds);
            v.release();
            assertEq(token.balanceOf(b.account), b.amount);
            assertEq(token.balanceOf(address(v)), 0);
        }
    }

    function test_Deploy_UsesTheBroadcasterAsDeployer() public {
        Deploy.Deployment memory d = script.deploy(_config(1));
        // No key is chosen by the script: the broadcaster is whoever forge configured as sender.
        assertEq(d.deployer, DEFAULT_SENDER);
        assertEq(VestToken(d.token).balanceOf(address(script)), 0, "script contract holds nothing");
        assertEq(VestToken(d.token).balanceOf(address(this)), 0, "test contract holds nothing");
    }

    function test_Deploy_OneBeneficiaryMayReceiveWholeSupply() public {
        Deploy.Config memory cfg = _config(1);
        cfg.beneficiaries[0].amount = SUPPLY;
        Deploy.Deployment memory d = script.deploy(cfg);
        assertEq(VestToken(d.token).balanceOf(d.vestings[0]), SUPPLY);
        assertEq(VestToken(d.token).balanceOf(d.deployer), 0);
    }

    function test_Deploy_AcceptsTwentyBeneficiaries() public {
        Deploy.Deployment memory d = script.deploy(_config(20));
        assertEq(d.vestings.length, 20);
    }

    function test_Deploy_CliffEqualToDurationIsAllowed() public {
        Deploy.Config memory cfg = _config(1);
        cfg.beneficiaries[0].cliffSeconds = cfg.beneficiaries[0].durationSeconds;
        Deploy.Deployment memory d = script.deploy(cfg);
        assertEq(LinearVesting(d.vestings[0]).cliffSeconds(), cfg.beneficiaries[0].durationSeconds);
    }

    function test_Deploy_ConfiguredChainNeedNotBeAnvil() public {
        vm.chainId(1);
        Deploy.Config memory cfg = _config(1);
        cfg.chainId = 1;
        Deploy.Deployment memory d = script.deploy(cfg);
        assertEq(VestToken(d.token).balanceOf(d.vestings[0]), cfg.beneficiaries[0].amount);
    }

    // ---------------------------------------------------------------- rejected configs

    function test_Deploy_RejectsWrongChainId() public {
        Deploy.Config memory cfg = _config(1);
        cfg.chainId = 1;
        _assertRejected(cfg, abi.encodeWithSelector(Deploy.ChainMismatch.selector, 1, ANVIL_CHAIN_ID));
    }

    function test_Deploy_RejectsZeroBeneficiaries() public {
        _assertRejected(_config(0), abi.encodeWithSelector(Deploy.InvalidBeneficiaryCount.selector, 0));
    }

    function test_DeployFromJson_RejectsEmptyArrayBeforeDeploying() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.InvalidBeneficiaryCount.selector, 0));
        script.deployFromJson('{"chainId":31337,"beneficiaries":[]}');
    }

    function test_Deploy_RejectsTwentyOneBeneficiaries() public {
        _assertRejected(_config(21), abi.encodeWithSelector(Deploy.InvalidBeneficiaryCount.selector, 21));
    }

    function test_Deploy_RejectsZeroAccount() public {
        Deploy.Config memory cfg = _config(3);
        cfg.beneficiaries[1].account = address(0);
        _assertRejected(cfg, abi.encodeWithSelector(Deploy.ZeroBeneficiary.selector, 1));
    }

    function test_Deploy_RejectsDuplicateAccount() public {
        Deploy.Config memory cfg = _config(3);
        cfg.beneficiaries[2].account = cfg.beneficiaries[0].account;
        _assertRejected(cfg, abi.encodeWithSelector(Deploy.DuplicateBeneficiary.selector, cfg.beneficiaries[0].account));
    }

    function test_Deploy_RejectsZeroAmount() public {
        Deploy.Config memory cfg = _config(2);
        cfg.beneficiaries[1].amount = 0;
        _assertRejected(cfg, abi.encodeWithSelector(Deploy.ZeroAmount.selector, 1));
    }

    function test_Deploy_RejectsTotalAboveSupply() public {
        Deploy.Config memory cfg = _config(2);
        cfg.beneficiaries[0].amount = SUPPLY;
        cfg.beneficiaries[1].amount = 1;
        _assertRejected(cfg, abi.encodeWithSelector(Deploy.AllocationExceedsSupply.selector, SUPPLY + 1, SUPPLY));
    }

    function test_Deploy_RejectsSingleAmountAboveSupply() public {
        Deploy.Config memory cfg = _config(1);
        cfg.beneficiaries[0].amount = SUPPLY + 1;
        _assertRejected(cfg, abi.encodeWithSelector(Deploy.AllocationExceedsSupply.selector, SUPPLY + 1, SUPPLY));
    }

    function test_Deploy_RejectsAmountThatWouldOverflowNaiveSum() public {
        Deploy.Config memory cfg = _config(2);
        cfg.beneficiaries[0].amount = 1;
        cfg.beneficiaries[1].amount = type(uint256).max;
        _assertRejected(cfg, abi.encodeWithSelector(Deploy.AllocationExceedsSupply.selector, type(uint256).max, SUPPLY));
    }

    function test_Deploy_RejectsZeroDuration() public {
        Deploy.Config memory cfg = _config(1);
        cfg.beneficiaries[0].cliffSeconds = 0;
        cfg.beneficiaries[0].durationSeconds = 0;
        _assertRejected(cfg, abi.encodeWithSelector(Deploy.ZeroDuration.selector, 0));
    }

    function test_Deploy_RejectsCliffLongerThanDuration() public {
        Deploy.Config memory cfg = _config(2);
        cfg.beneficiaries[1].cliffSeconds = cfg.beneficiaries[1].durationSeconds + 1;
        _assertRejected(cfg, abi.encodeWithSelector(Deploy.CliffExceedsDuration.selector, 1));
    }

    function test_DeployFromJson_RejectsWrongChainIdBeforeDeploying() public {
        uint256 nonceBefore = vm.getNonce(DEFAULT_SENDER);
        vm.expectRevert(abi.encodeWithSelector(Deploy.ChainMismatch.selector, 1, ANVIL_CHAIN_ID));
        script.deployFromJson(
            '{"chainId":1,"beneficiaries":[{"account":"0x0000000000000000000000000000000000000001",'
            '"amount":"1","start":0,"cliffSeconds":0,"durationSeconds":1}]}'
        );
        assertEq(vm.getNonce(DEFAULT_SENDER), nonceBefore);
    }
}
