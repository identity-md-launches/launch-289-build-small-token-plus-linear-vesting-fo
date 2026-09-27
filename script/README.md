# Deployment script

`script/Deploy.s.sol` deploys `VestToken`, one `LinearVesting` vault per beneficiary,
funds every vault, and asserts the wiring before the broadcast ends. Every parameter
comes from one JSON document; nothing is hardcoded to a chain, an address or a key.

```
script/Deploy.s.sol                 the script (run / parseConfig / validate / deploy)
script/config/deploy.json           local-anvil configuration (anvil default accounts 1-3)
script/config/deploy.example.json   template with placeholder addresses
test/Deploy.t.sol                   tests that drive parseConfig / validate / deploy in memory
```

> The configuration files live under `script/config/` (not a top-level `config/`)
> because this contribution may only write to `script/**`, `test/**` and `README.md`.

## How the script gets its configuration

`foundry.toml` grants no file-read permission (`fs_permissions = []`), so the script
never opens a file. It reads the JSON **text** from the `DEPLOY_CONFIG` environment
variable and parses it with `vm.parseJson*`:

```sh
DEPLOY_CONFIG="$(cat script/config/deploy.json)" forge script script/Deploy.s.sol ...
```

If `DEPLOY_CONFIG` is unset or empty, `run()` logs a notice and uses `DEFAULT_CONFIG`, a
string constant in the script that is equivalent to `script/config/deploy.json`
(`test_DefaultConfig_MatchesShippedAnvilConfig` pins the values). That is the
documented default for a local run; keep the two in sync if you edit either.

The broadcasting account is **never** chosen by the script or the config. It comes
from the command line: `--sender <addr> --unlocked` against anvil, or `--account
<name>` for a keystore. There is no private key anywhere in the repository.

## Configuration reference

```json
{
  "chainId": 31337,
  "beneficiaries": [
    {
      "account": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
      "amount": "100000000000000000000000000",
      "start": 1800000000,
      "cliffSeconds": 7776000,
      "durationSeconds": 31536000
    }
  ]
}
```

| Field | Type | Meaning | Rule (error if violated) | Default in `deploy.json` |
| --- | --- | --- | --- | --- |
| `chainId` | number | chain the script may run on | must equal `block.chainid` (`ChainMismatch(configured, actual)`) | `31337` (anvil) |
| `beneficiaries` | array | one `LinearVesting` per entry | 1 to 20 entries (`InvalidBeneficiaryCount(n)`) | 3 entries |
| `account` | address string | beneficiary of the vault | non-zero (`ZeroBeneficiary(i)`), unique (`DuplicateBeneficiary(a)`) | anvil accounts 1, 2, 3 |
| `amount` | decimal string (JSON number also accepted) | tokens moved into the vault, in base units (18 decimals) | `> 0` (`ZeroAmount(i)`); running total ≤ 1,000,000,000 × 10^18 (`AllocationExceedsSupply(total, supply)`) | 100 M / 50 M / 25 M tokens |
| `start` | number, unix seconds | when the linear curve begins | ≤ `2^64 - 1` (`ValueOutOfRange("start", i, v)`) | `1800000000` (2027-01-15) |
| `cliffSeconds` | number | seconds after `start` before anything vests | ≤ `durationSeconds` (`CliffExceedsDuration(i)`) | 90 days / 180 days / 0 |
| `durationSeconds` | number | total schedule length from `start` | `> 0` (`ZeroDuration(i)`) | 1 year / 2 years / 90 days |

Other notes:

- Keys inside an entry may appear in any order; unknown keys are ignored. A missing
  `chainId` or `beneficiaries` key reverts with `ConfigMissingKey(name)`; a missing
  field inside an entry reverts inside the JSON cheatcode.
- Write `amount` as a string. JSON numbers above 2^53 are silently rounded by many
  editors and tools; forge itself parses either form exactly.
- The supply check uses the remaining headroom (`amount > supply - allocated`) so an
  absurd amount cannot overflow the sum.
- The example file `script/config/deploy.example.json` uses `0x1111…` / `0x2222…`
  placeholders and `chainId: 31337`. Replace every address and set `chainId` to the
  target chain; the script refuses to run anywhere else.

## What the script does

`run()` reads the environment and calls `deployFromJson`, which is `parseConfig` →
`deploy`. `deploy` calls `validate` first, so **every rule above is checked before
`startBroadcast`** and a bad config produces no transaction at all. Then, under one
broadcast:

1. `new VestToken()` — the broadcaster receives the whole supply.
2. For each entry: `new LinearVesting(token, account, start, cliffSeconds, durationSeconds)`,
   then `token.transfer(vault, amount)`.
3. Every address and parameter is logged.
4. `_assertWiring` re-reads the chain: `INITIAL_SUPPLY` and `totalSupply`, the
   deployer's remaining balance (`supply - Σ amount`), and for each vault `token`,
   `beneficiary`, `start`, `cliffSeconds`, `durationSeconds`, `released == 0`,
   `balanceOf(vault) == amount`, `totalAllocation() == amount`. Any mismatch reverts
   with `WiringMismatch(what, i)` before `stopBroadcast`.

The function returns `Deployment { deployer, token, vestings[] }`, which `forge script`
prints under `== Return ==`.

The script uses only long-established cheatcodes (`envOr`, `keyExistsJson`,
`parseJsonUint`, `parseJsonAddress`, `toString`, `readCallers`, `startBroadcast`,
`stopBroadcast`). It deliberately avoids `parseJsonArrayLength`, which older forge
releases do not implement; array entries are counted by probing `.beneficiaries[i]`
until the first missing index.

## Commands

Build and test (no network, no environment variables):

```sh
forge build
forge test
```

Dry run in forge's local EVM. Nothing is broadcast, no RPC is needed, `block.chainid`
is `31337`, and the sender is forge's default `0x1804c8AB…`:

```sh
DEPLOY_CONFIG="$(cat script/config/deploy.json)" forge script script/Deploy.s.sol
# or, with the built-in default (identical values):
forge script script/Deploy.s.sol
```

Simulate against a running node without sending anything (`--broadcast` omitted):

```sh
DEPLOY_CONFIG="$(cat script/config/deploy.json)" forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

Broadcast to a local anvil (account 0 is anvil's first unlocked account):

```sh
anvil --port 8545 --chain-id 31337      # separate terminal
DEPLOY_CONFIG="$(cat script/config/deploy.json)" forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast --unlocked \
  --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

Broadcast with a keystore account instead of an unlocked node account (form only;
this repository never targets a public network):

```sh
DEPLOY_CONFIG="$(cat my-config.json)" forge script script/Deploy.s.sol \
  --rpc-url "$RPC_URL" --broadcast --account <keystore-name>
```

`forge script` writes `broadcast/Deploy.s.sol/<chainId>/run-latest.json` after a real
broadcast. That file is the record of what was sent; keep it with the launch notes.

## Proof against a local anvil

Recorded with forge/anvil/cast 1.8.3 on 2026-09-27. Output is verbatim except that
the rejection runs show only the decisive lines (forge prints the full call trace on
failure; it is elided here as `[trace elided]`) and the absolute repository path is
shortened to `<repo>`. The warning `Detected artifacts built from source files that no
longer exist … foundry-pp/DeployHelper27.sol` is a cosmetic message from forge 1.8's
script preprocessor; it appears even after `forge clean` and does not affect the run.

### 0. Dry runs (no RPC, nothing broadcast)

```
$ DEPLOY_CONFIG="$(cat script/config/deploy.json)" forge script script/Deploy.s.sol
No files changed, compilation skipped
Warning: Detected artifacts built from source files that no longer exist. Run `forge clean` to make sure builds are in sync with project files.
 - <repo>/foundry-pp/DeployHelper27.sol
Script ran successfully.
Gas used: 2317095

== Return ==
0: struct Deploy.Deployment Deployment({ deployer: 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38, token: 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496, vestings: [0x34A1D3fff3958843C43aD80F30b94c510645C316, 0xA8452Ec99ce0C64f20701dB7dD3abDb607c00496, 0xDB8cFf278adCCF9E9b5da745B44E754fC4EE3C76] })

== Logs ==
  Deployer   0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38
  VestToken  0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496
  LinearVesting 0x34A1D3fff3958843C43aD80F30b94c510645C316
    beneficiary     0x70997970C51812dc3A010C7d01b50e0d17dc79C8
    amount          100000000000000000000000000
    start           1800000000
    cliffSeconds    7776000
    durationSeconds 31536000
  LinearVesting 0xA8452Ec99ce0C64f20701dB7dD3abDb607c00496
    beneficiary     0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
    amount          50000000000000000000000000
    start           1800000000
    cliffSeconds    15552000
    durationSeconds 63072000
  LinearVesting 0xDB8cFf278adCCF9E9b5da745B44E754fC4EE3C76
    beneficiary     0x90F79bf6EB2c4f870365E785982E1f101E93b906
    amount          25000000000000000000000000
    start           1800000000
    cliffSeconds    0
    durationSeconds 7776000
  Unallocated supply left with deployer 825000000000000000000000000

If you wish to simulate on-chain transactions pass a RPC URL.
[exit 0]

$ forge script script/Deploy.s.sol 2>&1 | head -8
No files changed, compilation skipped
Warning: Detected artifacts built from source files that no longer exist. Run `forge clean` to make sure builds are in sync with project files.
 - <repo>/foundry-pp/DeployHelper27.sol
Script ran successfully.
Gas used: 2322243

== Return ==
0: struct Deploy.Deployment Deployment({ deployer: 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38, token: 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496, vestings: [0x34A1D3fff3958843C43aD80F30b94c510645C316, 0xA8452Ec99ce0C64f20701dB7dD3abDb607c00496, 0xDB8cFf278adCCF9E9b5da745B44E754fC4EE3C76] })
[exit 0]

$ DEPLOY_CONFIG="$(cat script/config/deploy.example.json)" forge script script/Deploy.s.sol 2>&1 | grep -E "Script ran|LinearVesting|beneficiary"
Script ran successfully.
  LinearVesting 0x34A1D3fff3958843C43aD80F30b94c510645C316
    beneficiary     0x1111111111111111111111111111111111111111
  LinearVesting 0xA8452Ec99ce0C64f20701dB7dD3abDb607c00496
    beneficiary     0x2222222222222222222222222222222222222222
[exit 0]
```

### 1. Fresh anvil

```
$ anvil --port 8545 --chain-id 31337   # in another terminal

$ cast chain-id --rpc-url http://127.0.0.1:8545
31337
[exit 0]

$ cast block-number --rpc-url http://127.0.0.1:8545
0
[exit 0]

$ cast nonce 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url http://127.0.0.1:8545
0
[exit 0]
```

### 2. Rejected configs revert before any deployment

Each bad config is derived from `deploy.json` with `sed`, and each run is a full
`--broadcast` invocation; the script reverts during validation, so forge never
reaches `startBroadcast` and no transaction is sent. Block number, nonce and the
absence of a `broadcast/` directory confirm it afterwards.

Wrong chain id (`31337` → `1`):

```
$ DEPLOY_CONFIG="$(sed "s/31337/1/" script/config/deploy.json)" forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
No files changed, compilation skipped
[trace elided]
Error: script failed: ChainMismatch(1, 31337 [3.133e4])
[exit 1]
```

Duplicate beneficiary (third entry's account replaced by the first's):

```
$ DEPLOY_CONFIG="$(sed "s/0x90F79bf6EB2c4f870365E785982E1f101E93b906/0x70997970C51812dc3A010C7d01b50e0d17dc79C8/" script/config/deploy.json)" forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
No files changed, compilation skipped
[trace elided]
Error: script failed: DuplicateBeneficiary(0x70997970C51812dc3A010C7d01b50e0d17dc79C8)
[exit 1]
```

Over-supply total (third amount raised so the sum is `10^27 + 1`):

```
$ DEPLOY_CONFIG="$(sed "s/\"25000000000000000000000000\"/\"850000000000000000000000001\"/" script/config/deploy.json)" forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
No files changed, compilation skipped
[trace elided]
Error: script failed: AllocationExceedsSupply(1000000000000000000000000001 [1e27], 1000000000000000000000000000 [1e27])
[exit 1]
```

Nothing happened on the node:

```
$ cast block-number --rpc-url http://127.0.0.1:8545
0
[exit 0]

$ cast nonce 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url http://127.0.0.1:8545
0
[exit 0]

$ ls broadcast 2>&1
ls: cannot access 'broadcast': No such file or directory
[exit 2]
```

### 3. Broadcast

```
$ DEPLOY_CONFIG="$(cat script/config/deploy.json)" forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
No files changed, compilation skipped
Warning: Detected artifacts built from source files that no longer exist. Run `forge clean` to make sure builds are in sync with project files.
 - <repo>/foundry-pp/DeployHelper27.sol
Script ran successfully.

== Return ==
0: struct Deploy.Deployment Deployment({ deployer: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, token: 0x5FbDB2315678afecb367f032d93F642f64180aa3, vestings: [0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512, 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9, 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707] })

== Logs ==
  Deployer   0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
  VestToken  0x5FbDB2315678afecb367f032d93F642f64180aa3
  LinearVesting 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
    beneficiary     0x70997970C51812dc3A010C7d01b50e0d17dc79C8
    amount          100000000000000000000000000
    start           1800000000
    cliffSeconds    7776000
    durationSeconds 31536000
  LinearVesting 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9
    beneficiary     0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
    amount          50000000000000000000000000
    start           1800000000
    cliffSeconds    15552000
    durationSeconds 63072000
  LinearVesting 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707
    beneficiary     0x90F79bf6EB2c4f870365E785982E1f101E93b906
    amount          25000000000000000000000000
    start           1800000000
    cliffSeconds    0
    durationSeconds 7776000
  Unallocated supply left with deployer 825000000000000000000000000

## Setting up 1 EVM.

==========================

Chain 31337

Estimated max fee per gas: 2.000000001 gwei
Estimated base fee per gas: 1 gwei
Estimated max priority fee per gas: 0.000000001 gwei

Estimated total gas used for script: 2496753

Estimated amount required: 0.004993506002496753 ETH

==========================


==========================

ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.

Transactions saved to: <repo>/broadcast/Deploy.s.sol/31337/run-latest.json

Sensitive values saved to: <repo>/cache/Deploy.s.sol/31337/run-latest.json

[exit 0]

$ cast block-number --rpc-url http://127.0.0.1:8545
1
[exit 0]

$ cast nonce 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url http://127.0.0.1:8545
7
[exit 0]
```

Seven transactions from account 0: four `CREATE`s (token + 3 vaults) and three
`transfer`s. The vault addresses are the `CREATE` addresses at nonces 1, 3 and 5.

### 4. Read back with cast

```
$ cast call 0x5FbDB2315678afecb367f032d93F642f64180aa3 symbol()(string) --rpc-url http://127.0.0.1:8545
"VDEMO"
[exit 0]

$ cast call 0x5FbDB2315678afecb367f032d93F642f64180aa3 totalSupply()(uint256) --rpc-url http://127.0.0.1:8545
1000000000000000000000000000 [1e27]
[exit 0]

$ cast call 0x5FbDB2315678afecb367f032d93F642f64180aa3 balanceOf(address)(uint256) 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url http://127.0.0.1:8545
825000000000000000000000000 [8.25e26]
[exit 0]

$ cast call 0x5FbDB2315678afecb367f032d93F642f64180aa3 balanceOf(address)(uint256) 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 --rpc-url http://127.0.0.1:8545
100000000000000000000000000 [1e26]
[exit 0]

$ cast call 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 token()(address) --rpc-url http://127.0.0.1:8545
0x5FbDB2315678afecb367f032d93F642f64180aa3
[exit 0]

$ cast call 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 beneficiary()(address) --rpc-url http://127.0.0.1:8545
0x70997970C51812dc3A010C7d01b50e0d17dc79C8
[exit 0]

$ cast call 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 start()(uint64) --rpc-url http://127.0.0.1:8545
1800000000 [1.8e9]
[exit 0]

$ cast call 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 cliffSeconds()(uint64) --rpc-url http://127.0.0.1:8545
7776000 [7.776e6]
[exit 0]

$ cast call 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 durationSeconds()(uint64) --rpc-url http://127.0.0.1:8545
31536000 [3.153e7]
[exit 0]

$ cast call 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 released()(uint256) --rpc-url http://127.0.0.1:8545
0
[exit 0]

$ cast call 0x5FbDB2315678afecb367f032d93F642f64180aa3 balanceOf(address)(uint256) 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9 --rpc-url http://127.0.0.1:8545
50000000000000000000000000 [5e25]
[exit 0]

$ cast call 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9 token()(address) --rpc-url http://127.0.0.1:8545
0x5FbDB2315678afecb367f032d93F642f64180aa3
[exit 0]

$ cast call 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9 beneficiary()(address) --rpc-url http://127.0.0.1:8545
0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
[exit 0]

$ cast call 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9 start()(uint64) --rpc-url http://127.0.0.1:8545
1800000000 [1.8e9]
[exit 0]

$ cast call 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9 cliffSeconds()(uint64) --rpc-url http://127.0.0.1:8545
15552000 [1.555e7]
[exit 0]

$ cast call 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9 durationSeconds()(uint64) --rpc-url http://127.0.0.1:8545
63072000 [6.307e7]
[exit 0]

$ cast call 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9 released()(uint256) --rpc-url http://127.0.0.1:8545
0
[exit 0]

$ cast call 0x5FbDB2315678afecb367f032d93F642f64180aa3 balanceOf(address)(uint256) 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707 --rpc-url http://127.0.0.1:8545
25000000000000000000000000 [2.5e25]
[exit 0]

$ cast call 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707 token()(address) --rpc-url http://127.0.0.1:8545
0x5FbDB2315678afecb367f032d93F642f64180aa3
[exit 0]

$ cast call 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707 beneficiary()(address) --rpc-url http://127.0.0.1:8545
0x90F79bf6EB2c4f870365E785982E1f101E93b906
[exit 0]

$ cast call 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707 start()(uint64) --rpc-url http://127.0.0.1:8545
1800000000 [1.8e9]
[exit 0]

$ cast call 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707 cliffSeconds()(uint64) --rpc-url http://127.0.0.1:8545
0
[exit 0]

$ cast call 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707 durationSeconds()(uint64) --rpc-url http://127.0.0.1:8545
7776000 [7.776e6]
[exit 0]

$ cast call 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707 released()(uint256) --rpc-url http://127.0.0.1:8545
0
[exit 0]
```

Summary of the on-chain state after the broadcast:

| Contract | Address (fresh anvil, account 0) | Beneficiary | VDEMO balance | start |
| --- | --- | --- | --- | --- |
| VestToken | `0x5FbDB2315678afecb367f032d93F642f64180aa3` | — | deployer keeps 825,000,000 × 10^18 | — |
| LinearVesting #0 | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` | `0x7099…79C8` (anvil 1) | 100,000,000 × 10^18 | 1800000000 |
| LinearVesting #1 | `0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9` | `0x3C44…93BC` (anvil 2) | 50,000,000 × 10^18 | 1800000000 |
| LinearVesting #2 | `0x5FC8d32690cc91D4c39d9d3abcBD16989F875707` | `0x90F7…b906` (anvil 3) | 25,000,000 × 10^18 | 1800000000 |

The addresses are deterministic for a fresh anvil and account 0; on any other node or
sender, take them from `== Return ==` or from `broadcast/Deploy.s.sol/31337/run-latest.json`.

## Tests

`test/Deploy.t.sol` (30 tests) covers the script without touching the process
environment: `run()` is only exercised by `forge script` above, because tests share one
environment and run in parallel, so `vm.setEnv` in a test would leak into the others.

- parsing: every field, key order independence, unknown keys ignored, `amount` as
  string or number, `start` at `2^64 - 1`, values above `uint64`, missing keys,
  empty array, the built-in default equals `deploy.json`
- wiring: token metadata and supply; per vault `token`, `beneficiary`, `start`,
  `cliffSeconds`, `durationSeconds`, `released`, balance, `totalAllocation`; the
  remainder stays with the broadcaster; the script and test contracts hold nothing;
  vaults actually release to their beneficiaries at the end of the schedule
- rejections, each asserting the sender's nonce did not move and no code appeared at
  the next `CREATE` address: wrong chain id, 0 and 21 beneficiaries, zero account,
  duplicate account, zero amount, single and cumulative over-supply, a `uint256.max`
  amount (no overflow), zero duration, cliff longer than duration
- the configured chain need not be anvil (`vm.chainId(1)` + `chainId: 1` deploys)

## What the script does not do

- It does not verify source on a block explorer (`forge verify-contract` or
  `--verify` on a network with an explorer; not applicable to anvil).
- It does not call `release()`; that is permissionless and left to the beneficiary,
  the deployer or a keeper after each cliff.
- It does not move the unallocated remainder anywhere; it stays with the broadcaster.
- It does not broadcast to any public network, and this repository provides no key,
  RPC URL or runbook for doing so. A real launch needs a separate reviewed procedure
  and an independent review of the contracts.
