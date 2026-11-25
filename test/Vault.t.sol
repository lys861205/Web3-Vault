// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Vault, IERC20} from "../src/Vault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {MyToken} from "../src/MyToken.sol";

/// @notice 用于测试防重入的恶意代币合约
contract MaliciousReentrantToken is IERC20 {
    Vault public vault;
    mapping(address => uint256) public override balanceOf;
    bool public hasAttacked;
    bool public attackSuccess;

    function setVault(Vault _vault) external {
        vault = _vault;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        // 模拟重入攻击：在转账回调期间尝试再次调用 vault.withdraw
        if (!hasAttacked && address(vault) != address(0)) {
            hasAttacked = true;
            // 尝试重入
            try vault.withdraw(amount) {
                attackSuccess = true;
            } catch {
                attackSuccess = false;
                // 重入被拦截，继续正常抛出以使交易失败
                revert("Reentrancy blocked");
            }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract VaultTest is Test {
    Vault public vault;
    VaultFactory public factory;
    MyToken public token;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant INITIAL_SUPPLY = 1_000_000; // 1,000,000 枚
    uint256 public constant ALICE_MINT_AMOUNT = 1_000 * 10 ** 18;
    uint256 public constant BOB_MINT_AMOUNT = 2_000 * 10 ** 18;

    // 事件定义（用于测试 expectEmit）
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event OwnershipTrasferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event VaultCreated(address indexed token, address indexed valutAddress);

    function setUp() public {
        vm.startPrank(owner);
        // 1. 部署代币合约：初始给 owner 铸造 1,000,000 枚
        token = new MyToken("Test Token", "TT", INITIAL_SUPPLY);

        // 2. 部署 Vault 保险库合约并调用 initialize 初始化
        vault = new Vault();
        vault.initialize(IERC20(address(token)), owner);

        // 3. 部署工厂合约
        factory = new VaultFactory();

        // 4. 分发代币给测试用户 Alice 和 Bob
        token.transfer(alice, ALICE_MINT_AMOUNT);
        token.transfer(bob, BOB_MINT_AMOUNT);
        vm.stopPrank();
    }

    // =============================================================
    // 1. 初始化函数 (initialize) 测试
    // =============================================================

    function test_Initialize_Success() public view {
        assertEq(address(vault.token()), address(token));
        assertEq(vault.owner(), owner);
        assertFalse(vault.paused());
    }

    function test_Initialize_Emit_OwnershipTransferred() public {
        Vault freshVault = new Vault();
        vm.expectEmit(true, true, false, true, address(freshVault));
        emit OwnershipTrasferred(address(0), alice);
        freshVault.initialize(IERC20(address(token)), alice);

        assertEq(freshVault.owner(), alice);
        assertEq(address(freshVault.token()), address(token));
    }

    function test_Initialize_RevertWhen_AlreadyInitialized() public {
        // 重复调用 initialize 应当被拦截
        vm.expectRevert(Vault.AlreadyInitialize.selector);
        vault.initialize(IERC20(address(token)), alice);
    }

    // =============================================================
    // 2. 存入 (Deposit) 测试
    // =============================================================

    function test_Deposit_Success() public {
        uint256 depositAmount = 100 * 10 ** 18;

        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);

        // 验证 Deposit 事件是否正常抛出
        vm.expectEmit(true, false, false, true, address(vault));
        emit Deposit(alice, depositAmount);

        vault.deposit(depositAmount);
        vm.stopPrank();

        // 验证 Vault 内部记账
        assertEq(vault.balanceOf(alice), depositAmount);
        // 验证 Vault 合约实际持有的代币数
        assertEq(token.balanceOf(address(vault)), depositAmount);
        // 验证 Alice 钱包扣除后的代币数
        assertEq(token.balanceOf(alice), ALICE_MINT_AMOUNT - depositAmount);
    }

    function test_Deposit_MultipleTimes() public {
        uint256 firstDeposit = 100 * 10 ** 18;
        uint256 secondDeposit = 200 * 10 ** 18;

        vm.startPrank(alice);
        token.approve(address(vault), firstDeposit + secondDeposit);

        vault.deposit(firstDeposit);
        assertEq(vault.balanceOf(alice), firstDeposit);

        vault.deposit(secondDeposit);
        assertEq(vault.balanceOf(alice), firstDeposit + secondDeposit);
        vm.stopPrank();

        assertEq(token.balanceOf(address(vault)), firstDeposit + secondDeposit);
    }

    function test_Deposit_RevertWhen_ZeroAmount() public {
        vm.startPrank(alice);
        vm.expectRevert(Vault.ZeroAmount.selector);
        vault.deposit(0);
        vm.stopPrank();
    }

    function test_Deposit_RevertWhen_InsufficientBalance() public {
        uint256 depositAmount = ALICE_MINT_AMOUNT + 1; // 超过 Alice 钱包实际余额

        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);

        // 预期报错：Vault.Insufficient(available, required)
        vm.expectRevert(
            abi.encodeWithSelector(Vault.Insufficient.selector, ALICE_MINT_AMOUNT, depositAmount)
        );
        vault.deposit(depositAmount);
        vm.stopPrank();
    }

    function test_Deposit_RevertWhen_InsufficientAllowance() public {
        uint256 depositAmount = 100 * 10 ** 18;

        vm.startPrank(alice);
        // 仅授权 50 枚代币
        token.approve(address(vault), 50 * 10 ** 18);

        // Vault 使用底层 call 捕获了代币转账失败，并统一包装抛出 TransferFailed
        vm.expectRevert(Vault.TransferFailed.selector);
        vault.deposit(depositAmount);
        vm.stopPrank();
    }

    // =============================================================
    // 3. 提取 (Withdraw) 测试
    // =============================================================

    function test_Withdraw_PartialSuccess() public {
        uint256 depositAmount = 100 * 10 ** 18;
        uint256 withdrawAmount = 40 * 10 ** 18;

        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.deposit(depositAmount);

        // 验证 Withdraw 事件是否正常抛出
        vm.expectEmit(true, false, false, true, address(vault));
        emit Withdraw(alice, withdrawAmount);

        vault.withdraw(withdrawAmount);
        vm.stopPrank();

        // 验证 Vault 内部记账减少
        assertEq(vault.balanceOf(alice), depositAmount - withdrawAmount);
        // 验证 Vault 合约实际持有的代币数减少
        assertEq(token.balanceOf(address(vault)), depositAmount - withdrawAmount);
        // 验证 Alice 钱包代币已退回
        assertEq(token.balanceOf(alice), ALICE_MINT_AMOUNT - depositAmount + withdrawAmount);
    }

    function test_Withdraw_FullSuccess() public {
        uint256 depositAmount = 100 * 10 ** 18;

        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.deposit(depositAmount);

        vault.withdraw(depositAmount);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(alice), ALICE_MINT_AMOUNT);
    }

    function test_Withdraw_RevertWhen_ZeroAmount() public {
        vm.startPrank(alice);
        vm.expectRevert(Vault.ZeroAmount.selector);
        vault.withdraw(0);
        vm.stopPrank();
    }

    function test_Withdraw_RevertWhen_InsufficientVaultBalance() public {
        uint256 depositAmount = 50 * 10 ** 18;
        uint256 withdrawAmount = 100 * 10 ** 18;

        vm.startPrank(alice);
        token.approve(address(vault), depositAmount);
        vault.deposit(depositAmount);

        // 预期报错：Vault.Insufficient(available, required)
        vm.expectRevert(
            abi.encodeWithSelector(Vault.Insufficient.selector, depositAmount, withdrawAmount)
        );
        vault.withdraw(withdrawAmount);
        vm.stopPrank();
    }

    function test_Withdraw_RevertWhen_NoDeposit() public {
        vm.startPrank(bob);
        // Bob 从未存入过代币，余额为 0
        vm.expectRevert(
            abi.encodeWithSelector(Vault.Insufficient.selector, 0, 10 * 10 ** 18)
        );
        vault.withdraw(10 * 10 ** 18);
        vm.stopPrank();
    }

    // =============================================================
    // 4. 多用户资产隔离测试
    // =============================================================

    function test_MultipleUsers_Isolation() public {
        uint256 aliceDeposit = 100 * 10 ** 18;
        uint256 bobDeposit = 250 * 10 ** 18;

        // Alice 存入
        vm.startPrank(alice);
        token.approve(address(vault), aliceDeposit);
        vault.deposit(aliceDeposit);
        vm.stopPrank();

        // Bob 存入
        vm.startPrank(bob);
        token.approve(address(vault), bobDeposit);
        vault.deposit(bobDeposit);
        vm.stopPrank();

        // 验证金库总余额 = Alice + Bob
        assertEq(token.balanceOf(address(vault)), aliceDeposit + bobDeposit);
        assertEq(vault.balanceOf(alice), aliceDeposit);
        assertEq(vault.balanceOf(bob), bobDeposit);

        // Alice 取出全部存款
        vm.prank(alice);
        vault.withdraw(aliceDeposit);

        // 验证 Alice 余额归零，Bob 的存款完好无损
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), bobDeposit);
        assertEq(token.balanceOf(address(vault)), bobDeposit);
    }

    // =============================================================
    // 5. 模糊测试 (Fuzz Testing)
    // =============================================================

    function testFuzz_DepositAndWithdraw(uint256 amount) public {
        // 限制模糊测试金额在 (0, ALICE_MINT_AMOUNT] 合理区间
        amount = bound(amount, 1, ALICE_MINT_AMOUNT);

        vm.startPrank(alice);
        token.approve(address(vault), amount);
        vault.deposit(amount);

        assertEq(vault.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(vault)), amount);

        vault.withdraw(amount);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(alice), ALICE_MINT_AMOUNT);
        vm.stopPrank();
    }

    // =============================================================
    // 6. 权限控制 (Access Control) 与 紧急暂停测试
    // =============================================================

    function test_Pause_Success() public {
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true, address(vault));
        emit Paused(owner);

        vault.pause();
        assertTrue(vault.paused());
        vm.stopPrank();
    }

    function test_Pause_RevertWhen_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert(Vault.Unauthorized.selector);
        vault.pause();
        vm.stopPrank();
    }

    function test_Unpause_Success() public {
        vm.startPrank(owner);
        vault.pause();
        assertTrue(vault.paused());

        vm.expectEmit(true, false, false, true, address(vault));
        emit Unpaused(owner);

        vault.unpause();
        assertFalse(vault.paused());
        vm.stopPrank();
    }

    function test_Unpause_RevertWhen_NotOwner() public {
        vm.prank(owner);
        vault.pause();

        vm.startPrank(alice);
        vm.expectRevert(Vault.Unauthorized.selector);
        vault.unpause();
        vm.stopPrank();
    }

    function test_Deposit_RevertWhen_Paused() public {
        vm.prank(owner);
        vault.pause();

        vm.startPrank(alice);
        token.approve(address(vault), 100 * 10 ** 18);

        vm.expectRevert(Vault.EnforcedPause.selector);
        vault.deposit(100 * 10 ** 18);
        vm.stopPrank();
    }

    function test_Withdraw_RevertWhen_Paused() public {
        // 先在正常状态存入
        vm.startPrank(alice);
        token.approve(address(vault), 100 * 10 ** 18);
        vault.deposit(100 * 10 ** 18);
        vm.stopPrank();

        // 管理员紧急暂停
        vm.prank(owner);
        vault.pause();

        // 尝试提现，应被拦截
        vm.startPrank(alice);
        vm.expectRevert(Vault.EnforcedPause.selector);
        vault.withdraw(100 * 10 ** 18);
        vm.stopPrank();
    }

    function test_TransferOwnership_Success() public {
        address newOwner = makeAddr("newOwner");

        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true, address(vault));
        emit OwnershipTrasferred(owner, newOwner);

        vault.transferOwnership(newOwner);
        assertEq(vault.owner(), newOwner);
        vm.stopPrank();

        // 新 Owner 可以调用 pause
        vm.prank(newOwner);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_TransferOwnership_RevertWhen_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert(Vault.Unauthorized.selector);
        vault.transferOwnership(alice);
        vm.stopPrank();
    }

    function test_TransferOwnership_RevertWhen_ZeroAddress() public {
        vm.startPrank(owner);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vault.transferOwnership(address(0));
        vm.stopPrank();
    }

    // =============================================================
    // 7. 防重入保护测试 (Reentrancy Guard)
    // =============================================================

    function test_ReentrancyGuard_BlocksAttack() public {
        // 部署恶意重入代币
        MaliciousReentrantToken attackToken = new MaliciousReentrantToken();
        Vault attackVault = new Vault();
        attackVault.initialize(IERC20(address(attackToken)), address(this));
        attackToken.setVault(attackVault);

        // 给 Alice 铸造代币
        uint256 amount = 100 * 10 ** 18;
        attackToken.mint(alice, amount);

        // Alice 存入恶意代币
        vm.startPrank(alice);
        attackToken.mint(address(attackVault), amount); // 模拟金库中已有代币
        attackVault.deposit(amount);

        // Alice 尝试在提现时重入，将被 nonReentrant 拦截并导致提现失败回滚
        vm.expectRevert(Vault.TransferFailed.selector);
        attackVault.withdraw(amount);
        vm.stopPrank();

        // 确认恶意代币未能完成重入攻击
        assertFalse(attackToken.attackSuccess());
    }

    // =============================================================
    // 8. 金库工厂合约测试 (VaultFactory & EIP-1167 Clone)
    // =============================================================

    function test_Factory_CreateVault_Success() public {
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, false, address(factory));
        emit VaultCreated(address(token), address(0));

        address vaultAddr = factory.createVault(address(token));
        assertEq(factory.getVault(address(token)), vaultAddr);
        assertEq(factory.getAllVaults(), 1);

        // 验证克隆出的金库属性是否正确初始化
        Vault clonedVault = Vault(vaultAddr);
        assertEq(address(clonedVault.token()), address(token));
        assertEq(clonedVault.owner(), owner);
        assertFalse(clonedVault.paused());
        vm.stopPrank();
    }

    function test_Factory_CreateVault_RevertWhen_NotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert(VaultFactory.Unauthorized.selector);
        factory.createVault(address(token));
        vm.stopPrank();
    }

    function test_Factory_CreateVault_RevertWhen_ZeroAddress() public {
        vm.startPrank(owner);
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.createVault(address(0));
        vm.stopPrank();
    }

    function test_Factory_CreateVault_RevertWhen_AlreadyExists() public {
        vm.startPrank(owner);
        address firstVault = factory.createVault(address(token));

        vm.expectRevert(
            abi.encodeWithSelector(VaultFactory.VaultAlreadyExists.selector, address(token), firstVault)
        );
        factory.createVault(address(token));
        vm.stopPrank();
    }

    function test_Factory_ClonedVault_DepositAndWithdraw() public {
        // 验证通过工厂克隆部署的金库，能够正常接收存款与提取
        vm.prank(owner);
        address vaultAddr = factory.createVault(address(token));
        Vault clonedVault = Vault(vaultAddr);

        uint256 depositAmount = 50 * 10 ** 18;
        vm.startPrank(alice);
        token.approve(vaultAddr, depositAmount);
        clonedVault.deposit(depositAmount);

        assertEq(clonedVault.balanceOf(alice), depositAmount);
        assertEq(token.balanceOf(vaultAddr), depositAmount);

        clonedVault.withdraw(depositAmount);
        assertEq(clonedVault.balanceOf(alice), 0);
        assertEq(token.balanceOf(vaultAddr), 0);
        assertEq(token.balanceOf(alice), ALICE_MINT_AMOUNT);
        vm.stopPrank();
    }
}
