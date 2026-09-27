// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {VestToken} from "../src/VestToken.sol";
import {LinearVesting} from "../src/LinearVesting.sol";

/// @title Deploy
/// @notice Deploys `VestToken` and one `LinearVesting` vault per configured beneficiary, funds
///         each vault, and asserts the wiring before the broadcast ends.
/// @dev Every parameter comes from one JSON document. `run()` reads it from the `DEPLOY_CONFIG`
///      environment variable (foundry.toml grants no file-read permission) and falls back to
///      `DEFAULT_CONFIG`, the local-anvil configuration, when the variable is unset or empty.
///      `run()` does nothing else: parsing (`parseConfig`), validation (`validate`) and the
///      deployment itself (`deploy`) are public so tests can drive them with in-memory values
///      and never touch the process environment.
///
///      Nothing is broadcast unless `forge script` is invoked with `--broadcast`, and the
///      broadcasting account always comes from the command line (`--sender` with anvil's
///      unlocked accounts, or `--account`). No key lives in the repository or the config.
///
///      Only long-established cheatcodes are used (`parseJsonUint`, `parseJsonAddress`,
///      `keyExistsJson`, `readCallers`, `envOr`), so the script runs on any forge release that
///      supports the vendored forge-std.
contract Deploy is Script {
    /// @notice One vault per entry in `beneficiaries[]`.
    struct Beneficiary {
        address account;
        uint256 amount;
        uint64 start;
        uint64 cliffSeconds;
        uint64 durationSeconds;
    }

    /// @notice Whole configuration document.
    struct Config {
        uint256 chainId;
        Beneficiary[] beneficiaries;
    }

    /// @notice What `deploy` created.
    struct Deployment {
        address deployer;
        address token;
        address[] vestings;
    }

    /// @notice Name of the environment variable holding the JSON text.
    string public constant CONFIG_ENV = "DEPLOY_CONFIG";

    /// @notice Upper bound on `beneficiaries[]`.
    uint256 public constant MAX_BENEFICIARIES = 20;

    /// @notice `VestToken.INITIAL_SUPPLY`, needed before the token exists to bound the total
    ///         allocation. `_assertWiring` checks it against the deployed token.
    uint256 public constant TOKEN_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice Built-in configuration for a local anvil, byte-for-byte equivalent to
    ///         `script/config/deploy.json`: anvil's default accounts 1, 2 and 3.
    string public constant DEFAULT_CONFIG = "{" '"chainId": 31337,' '"beneficiaries": [' "{"
        '"account": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",' '"amount": "100000000000000000000000000",'
        '"start": 1800000000,' '"cliffSeconds": 7776000,' '"durationSeconds": 31536000' "}," "{"
        '"account": "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",' '"amount": "50000000000000000000000000",'
        '"start": 1800000000,' '"cliffSeconds": 15552000,' '"durationSeconds": 63072000' "}," "{"
        '"account": "0x90F79bf6EB2c4f870365E785982E1f101E93b906",' '"amount": "25000000000000000000000000",'
        '"start": 1800000000,' '"cliffSeconds": 0,' '"durationSeconds": 7776000' "}" "]" "}";

    error ConfigMissingKey(string key);
    error ChainMismatch(uint256 configured, uint256 actual);
    error InvalidBeneficiaryCount(uint256 count);
    error ZeroBeneficiary(uint256 index);
    error DuplicateBeneficiary(address account);
    error ZeroAmount(uint256 index);
    error AllocationExceedsSupply(uint256 allocated, uint256 supply);
    error ZeroDuration(uint256 index);
    error CliffExceedsDuration(uint256 index);
    error ValueOutOfRange(string field, uint256 index, uint256 value);
    error WiringMismatch(string what, uint256 index);

    // ------------------------------------------------------------------ entry point

    /// @notice `forge script` entry point: read `DEPLOY_CONFIG`, then parse, validate, deploy.
    function run() external returns (Deployment memory) {
        string memory json = vm.envOr(CONFIG_ENV, string(""));
        if (bytes(json).length == 0) {
            console.log("DEPLOY_CONFIG is not set; using the built-in local-anvil configuration");
            json = DEFAULT_CONFIG;
        }
        return deployFromJson(json);
    }

    /// @notice Parse a JSON document, validate it against the current chain, and deploy.
    function deployFromJson(string memory json) public returns (Deployment memory) {
        return deploy(parseConfig(json));
    }

    // ------------------------------------------------------------------ parsing

    /// @notice Decode the JSON document into a `Config`. Performs only shape and range checks;
    ///         `validate` applies the deployment rules.
    /// @dev Entries are read by index (`.beneficiaries[i]`) until the first missing index, so the
    ///      order of keys inside each object does not matter and unknown keys are ignored.
    ///      `amount` may be a decimal string (recommended: JSON numbers above 2^53 are lossy in
    ///      many editors) or a JSON number; both are coerced to `uint256`.
    function parseConfig(string memory json) public view returns (Config memory cfg) {
        if (!vm.keyExistsJson(json, ".chainId")) revert ConfigMissingKey("chainId");
        if (!vm.keyExistsJson(json, ".beneficiaries")) revert ConfigMissingKey("beneficiaries");

        cfg.chainId = vm.parseJsonUint(json, ".chainId");

        uint256 count = 0;
        while (vm.keyExistsJson(json, _entryPath(count, ""))) {
            count++;
        }

        cfg.beneficiaries = new Beneficiary[](count);
        for (uint256 i = 0; i < count; i++) {
            Beneficiary memory b = cfg.beneficiaries[i];
            b.account = vm.parseJsonAddress(json, _entryPath(i, ".account"));
            b.amount = vm.parseJsonUint(json, _entryPath(i, ".amount"));
            b.start = _toUint64("start", i, vm.parseJsonUint(json, _entryPath(i, ".start")));
            b.cliffSeconds = _toUint64("cliffSeconds", i, vm.parseJsonUint(json, _entryPath(i, ".cliffSeconds")));
            b.durationSeconds =
                _toUint64("durationSeconds", i, vm.parseJsonUint(json, _entryPath(i, ".durationSeconds")));
        }
    }

    function _entryPath(uint256 index, string memory field) internal pure returns (string memory) {
        return string.concat(".beneficiaries[", vm.toString(index), "]", field);
    }

    function _toUint64(string memory field, uint256 index, uint256 value) internal pure returns (uint64) {
        if (value > type(uint64).max) revert ValueOutOfRange(field, index, value);
        return uint64(value);
    }

    // ------------------------------------------------------------------ validation

    /// @notice Every rule that must hold before anything is deployed.
    function validate(Config memory cfg) public view {
        if (cfg.chainId != block.chainid) revert ChainMismatch(cfg.chainId, block.chainid);

        uint256 n = cfg.beneficiaries.length;
        if (n == 0 || n > MAX_BENEFICIARIES) revert InvalidBeneficiaryCount(n);

        uint256 supply = TOKEN_SUPPLY;
        uint256 allocated = 0;
        for (uint256 i = 0; i < n; i++) {
            Beneficiary memory b = cfg.beneficiaries[i];
            if (b.account == address(0)) revert ZeroBeneficiary(i);
            for (uint256 j = 0; j < i; j++) {
                if (cfg.beneficiaries[j].account == b.account) revert DuplicateBeneficiary(b.account);
            }
            if (b.amount == 0) revert ZeroAmount(i);
            if (b.durationSeconds == 0) revert ZeroDuration(i);
            if (b.cliffSeconds > b.durationSeconds) revert CliffExceedsDuration(i);
            // Checked against the remaining headroom so a huge amount cannot overflow the sum.
            if (b.amount > supply - allocated) revert AllocationExceedsSupply(_saturatingSum(cfg), supply);
            allocated += b.amount;
        }
    }

    function _saturatingSum(Config memory cfg) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < cfg.beneficiaries.length; i++) {
            uint256 amount = cfg.beneficiaries[i].amount;
            total = amount > type(uint256).max - total ? type(uint256).max : total + amount;
        }
    }

    // ------------------------------------------------------------------ deployment

    /// @notice Validate, then deploy and fund everything under one broadcast.
    /// @dev The broadcaster is whatever the caller configured (`--sender` / `--account`); the
    ///      script never chooses a key. The wiring is asserted before `stopBroadcast`.
    function deploy(Config memory cfg) public returns (Deployment memory result) {
        validate(cfg);

        uint256 n = cfg.beneficiaries.length;
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        VestToken token = new VestToken();
        console.log("Deployer  ", deployer);
        console.log("VestToken ", address(token));

        LinearVesting[] memory vestings = new LinearVesting[](n);
        uint256 allocated = 0;
        for (uint256 i = 0; i < n; i++) {
            Beneficiary memory b = cfg.beneficiaries[i];
            vestings[i] = new LinearVesting(address(token), b.account, b.start, b.cliffSeconds, b.durationSeconds);
            token.transfer(address(vestings[i]), b.amount);
            allocated += b.amount;

            console.log("LinearVesting", address(vestings[i]));
            console.log("  beneficiary    ", b.account);
            console.log("  amount         ", b.amount);
            console.log("  start          ", b.start);
            console.log("  cliffSeconds   ", b.cliffSeconds);
            console.log("  durationSeconds", b.durationSeconds);
        }
        console.log("Unallocated supply left with deployer", token.balanceOf(deployer));

        _assertWiring(token, cfg, vestings, deployer, allocated);
        vm.stopBroadcast();

        result.deployer = deployer;
        result.token = address(token);
        result.vestings = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            result.vestings[i] = address(vestings[i]);
        }
    }

    function _assertWiring(
        VestToken token,
        Config memory cfg,
        LinearVesting[] memory vestings,
        address deployer,
        uint256 allocated
    ) internal view {
        uint256 supply = token.INITIAL_SUPPLY();
        if (supply != TOKEN_SUPPLY) revert WiringMismatch("INITIAL_SUPPLY", 0);
        if (token.totalSupply() != supply) revert WiringMismatch("totalSupply", 0);
        if (token.balanceOf(deployer) != supply - allocated) revert WiringMismatch("deployer balance", 0);

        for (uint256 i = 0; i < vestings.length; i++) {
            Beneficiary memory b = cfg.beneficiaries[i];
            LinearVesting v = vestings[i];
            if (address(v.token()) != address(token)) revert WiringMismatch("token", i);
            if (v.beneficiary() != b.account) revert WiringMismatch("beneficiary", i);
            if (v.start() != b.start) revert WiringMismatch("start", i);
            if (v.cliffSeconds() != b.cliffSeconds) revert WiringMismatch("cliffSeconds", i);
            if (v.durationSeconds() != b.durationSeconds) revert WiringMismatch("durationSeconds", i);
            if (v.released() != 0) revert WiringMismatch("released", i);
            if (token.balanceOf(address(v)) != b.amount) revert WiringMismatch("vault balance", i);
            if (v.totalAllocation() != b.amount) revert WiringMismatch("totalAllocation", i);
        }
    }
}
