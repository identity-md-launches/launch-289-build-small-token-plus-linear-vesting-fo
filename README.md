# Vest Demo: token + linear vesting

A small Foundry project: a fixed-supply ERC-20 (`VestToken`) and a permissionless,
ownerless linear vesting vault (`LinearVesting`). Solidity `0.8.26`, no external
dependencies beyond `forge-std` (vendored as plain files under `lib/`).

```
src/VestToken.sol            fixed-supply ERC-20 "Vest Demo" / "VDEMO"
src/LinearVesting.sol        one beneficiary, cliff + linear release, no admin
src/interfaces/IERC20.sol    minimal ERC-20 interface
test/VestToken.t.sol         token unit tests
test/LinearVesting.t.sol     vesting unit + fuzz tests
test/mocks/MockTokens.sol    misbehaving tokens used by failure tests
test/Deploy.t.sol            deployment script tests (parse / validate / deploy in memory)
script/Deploy.s.sol          deployment script: JSON config -> token + one vault per beneficiary
script/config/deploy.json    local-anvil configuration (anvil default accounts 1-3)
script/config/deploy.example.json  template with placeholder addresses
script/README.md             parameter reference, commands, and the recorded anvil proof
```

## Build and test

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `ffi = false` and an empty `fs_permissions`.
Tests read no environment variables and do not depend on the calling address, so
they can run in any order, in parallel, and offline once solc is installed.

## Contracts

### VestToken

| Property | Value |
| --- | --- |
| Name / symbol / decimals | `Vest Demo` / `VDEMO` / 18 |
| Supply | 1,000,000,000 × 10^18, minted once to `msg.sender` in the constructor |
| Admin surface | none: no mint, burn, pause, owner or upgrade |
| Constructor arguments | none |

A self-contained ERC-20 (custom errors, unlimited allowance is not decremented).
`totalSupply` is immutable and equals `INITIAL_SUPPLY` forever.

### LinearVesting

```
constructor(address token, address beneficiary, uint64 start, uint64 cliffSeconds, uint64 durationSeconds)
```

| Check | Error |
| --- | --- |
| `token != 0` and `beneficiary != 0` | `ZeroAddress()` |
| `durationSeconds > 0` | `ZeroDuration()` |
| `cliffSeconds <= durationSeconds` | `CliffExceedsDuration()` |

All five parameters are immutable. There is no owner, no revoke, no way to change
the beneficiary, and the contract neither accepts nor holds ETH.

**Allocation.** The contract has no notion of a fixed grant. Its allocation is
whatever it holds: `total = token.balanceOf(this) + released`. Tokens sent at any
time, before or after `start`, join the same curve.

**Schedule.** `vestedAmount(t)`:

- `0` while `t < start + cliffSeconds`
- `total` once `t >= start + durationSeconds`
- otherwise `floor(total * (t - start) / durationSeconds)`

Timestamps are widened to `uint256` before adding, so `start + cliff` cannot
overflow even at `type(uint64).max`.

**Release.** `release()` is callable by anyone and transfers
`vestedAmount(block.timestamp) - released` to the beneficiary, emitting
`Released(amount)`. It reverts with `NothingToRelease()` when that difference is
zero. `released()` is the running total; `releasable()`, `totalAllocation()`,
`cliff()` and `end()` are convenience views.

The token transfer is checked: a `false` return or a revert from the token reverts
the release with `TransferFailed()` (state is rolled back). Tokens that return no
data (USDT-style) are accepted. `released` is updated before the external call.

## Assumptions

- **Plain ERC-20 only.** The allocation is derived from `balanceOf`, so
  fee-on-transfer, rebasing, or balance-mutating tokens break the accounting.
  `VestToken` is the intended token; anything else is at the deployer's risk.
- **Rounding down.** Every intermediate `vestedAmount` is floored. The dust that
  rounding leaves behind is released in full at or after `start + durationSeconds`.
  A tiny allocation over a long duration may show `0` releasable for a long time.
- **Donations are irreversible.** Any token sent to a `LinearVesting` belongs to its
  beneficiary; there is no recovery function, on purpose.
- **Beneficiary is final.** If the beneficiary address is wrong or its key is lost,
  the tokens are stranded. Verify addresses before funding.
- **`start` may be in the past.** Nothing prevents it; the contract just vests
  accordingly (immediately releasable if the schedule has already ended).
- **Block timestamps.** Vesting is measured in `block.timestamp`, which validators
  can nudge by a few seconds. That is immaterial for schedules measured in days.

## Deployment

The deployment script `script/Deploy.s.sol` reads one JSON document from the
`DEPLOY_CONFIG` environment variable (the script cannot open files: `fs_permissions`
is empty). When the variable is unset it falls back to a built-in copy of
`script/config/deploy.json`, the local-anvil configuration. Full reference, the
error each rule raises, and the recorded anvil proof are in
[`script/README.md`](script/README.md).

Dry run in forge's local EVM (no RPC, nothing broadcast):

```sh
DEPLOY_CONFIG="$(cat script/config/deploy.json)" forge script script/Deploy.s.sol
```

Broadcast to a local anvil, signing with anvil's unlocked account 0:

```sh
anvil --port 8545 --chain-id 31337      # separate terminal
DEPLOY_CONFIG="$(cat script/config/deploy.json)" forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast --unlocked \
  --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

Configuration shape:

```json
{
  "chainId": 31337,
  "beneficiaries": [
    {
      "account": "0x...",
      "amount": "1000000000000000000000000",
      "start": 1700000000,
      "cliffSeconds": 7776000,
      "durationSeconds": 31104000
    }
  ]
}
```

| Field | Meaning | Constraint | Default (`script/config/deploy.json`) |
| --- | --- | --- | --- |
| `chainId` | chain the script may run on | must equal `block.chainid` | `31337` |
| `beneficiaries[]` | one `LinearVesting` per entry | 1 to 20 entries | anvil accounts 1, 2, 3 |
| `account` | beneficiary | non-zero, unique across entries | `0x7099…79C8`, `0x3C44…93BC`, `0x90F7…b906` |
| `amount` | tokens transferred to that vault, base units (18 decimals), decimal string | `> 0`; sum ≤ 1,000,000,000 × 10^18 | 100 M, 50 M, 25 M tokens |
| `start` | unix seconds | any `uint64` | `1800000000` |
| `cliffSeconds` | cliff length | `≤ durationSeconds` | 90 d, 180 d, 0 |
| `durationSeconds` | schedule length | `> 0` | 1 y, 2 y, 90 d |

All rules are checked before `startBroadcast`, so a bad config sends nothing.
Sequence per run: deploy `VestToken` (deployer receives the full supply), deploy
one `LinearVesting` per beneficiary, transfer each `amount` from the deployer to its
vault, log every address, then assert every balance and parameter before the
broadcast stops. Any supply not allocated stays with the deployer. The sender always
comes from the command line (`--sender` with anvil's unlocked accounts, or
`--account`); there is no private key in the repository or config.

## Operational responsibilities

- **Before funding**: double-check every beneficiary address and schedule; nothing
  can be corrected afterwards.
- **After the cliff**: someone must call `release()` on each vault. It is
  permissionless, so the beneficiary, the deployer, or a keeper can do it. Each call
  pays gas once for all vested-and-unreleased tokens; there is no benefit to calling
  more often than the beneficiary wants funds.
- **Leftover supply**: whatever the deployer does not allocate remains in the
  deployer's wallet. Decide where it goes (treasury, further vaults, burn by sending
  to a dead address) as part of the launch plan.
- **Monitoring**: `releasable()` and `released()` on each vault, plus the token
  balance of each beneficiary, are enough to reconcile the schedule.
- **No public broadcast is part of this repository.** The script is proven only
  against a local anvil. Any real deployment needs a separate, reviewed runbook and
  an independent adversarial review of these contracts; passing tests are not an
  audit.
