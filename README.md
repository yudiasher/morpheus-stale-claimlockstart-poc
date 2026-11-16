# Morpheus — Stale `claimLockStart` inflates the lock multiplier (PoC)

Foundry proof of concept for a bug in Morpheus `DepositPool.lockClaim`
(`DepositPool.sol:323`): a re-lock keeps a stale `claimLockStart` from a
long-expired lock, so the lock multiplier is computed over years the user was
never locked. Target: DepositPool USDC
`0x6cCE082851Add4c535352f596662521B4De4750E` (Ethereum mainnet, Appendix A).

## Run it (one command, from a clean clone)

```sh
forge test --match-contract StaleLockStartTest -vv
```

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).
The test forks Ethereum mainnet at block 26426622 via the public RPC
`https://ethereum.publicnode.com` (hardcoded in `setUp`); no RPC URL or
other setup is needed.

## What it proves

100,000 USDC, 2-year stale start, 30-day forward lock:

- Attacker `virtualDeposited` after re-lock: **358,250,019,590 = 3.5825x**
  the deposit (control fresh lock: 1.0x).
- 30-day reward gain on the same 72,196.78 MOR window emission to the USDC
  pool: attacker **21,894.74 MOR** vs control **7,583.48 MOR**.
- Excess: **14,311.25 MOR = $10,245.58** at MOR $0.715911, claimed in full
  on the fork. The excess dilutes honest stakers' shares of the fixed
  per-period emission and is minted as MOR via the Distributor.

No privileged accounts are used: the attacker and control are fresh EOAs;
only fork cheatcodes (`deal`, `warp`, `prank`, `mockCall` on the Chainlink
adapter for price freshness) are used.
