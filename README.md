# Web3 Vault & Factory 智能合约金库系统

[![Solidity](https://img.shields.io/badge/Solidity-%5E0.8.13-363636?style=flat-square&logo=solidity)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FF4F00?style=flat-square&logo=ethereum)](https://getfoundry.sh/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](https://opensource.org/licenses/MIT)

本项目是一个遵循工业级安全标准的 **Web3 单币种保险库（Single-Asset Vault）与工厂合约（VaultFactory）系统**。支持任意标准 ERC-20 代币及非标代币（如以太坊主网上的 **USDT**）的安全充值与提取，内建权限管理、紧急熔断机制以及防重入保护。

---

## 目录

- [核心架构](#核心架构)
- [合约概览](#合约概览)
- [核心安全设计与技术亮点](#核心安全设计与技术亮点)
- [目录结构](#目录结构)
- [快速开始](#快速开始)
  - [依赖环境](#依赖环境)
  - [编译合约](#编译合约)
  - [运行测试](#运行测试)
- [核心业务流转与机制说明](#核心业务流转与机制说明)
- [许可证](#许可证)

---

## 核心架构

本项目采用 DeFi 领域主流的 **“单币金库 + 工厂合约”** 模式：

```text
                           ┌──────────────────────────────┐
                           │      VaultFactory (工厂)     │
                           │   - 统一创建与管理金库        │
                           │   - 维护 token => vault 映射 │
                           └──────────────┬───────────────┘
                                          │
                  ┌───────────────────────┼───────────────────────┐
                  ▼                       ▼                       ▼
       ┌─────────────────────┐ ┌─────────────────────┐ ┌─────────────────────┐
       │     Vault (USDT)    │ │     Vault (USDC)    │ │     Vault (DAI)     │
       │   - 资产独立隔离     │ │   - 资产独立隔离     │ │   - 资产独立隔离     │
       │   - 防重入/暂停机制  │ │   - 防重入/暂停机制  │ │   - 防重入/暂停机制  │
       └─────────────────────┘ └─────────────────────┘ └─────────────────────┘
```

---

## 合约概览

| 合约文件 | 职责说明 |
| :--- | :--- |
| [`src/Vault.sol`](./src/Vault.sol) | **单币种保险库合约**：负责托管特定代币，实现用户充值（`deposit`）与提现（`withdraw`），管理用户记账余额，支持紧急暂停与防重入。 |
| [`src/VaultFactory.sol`](./src/VaultFactory.sol) | **金库工厂合约**：用于动态部署新金库，建立 `token => vault` 索引，防止重复部署同代币金库，并将金库所有权交接给创建者。 |
| [`src/MyToken.sol`](./src/MyToken.sol) | **标准 ERC-20 测试代币**：工业级 ERC-20 实现，支持 `mint`、`burn`、无限授权（`type(uint256).max` Gas 优化）及标准事件抛出。 |

---

## 核心安全设计与技术亮点

### 1. 非标 ERC-20（USDT）完美兼容
以太坊主网上的 **USDT** 和早期代币（如 BNB、OMG）在 `transfer` 与 `transferFrom` 成功时不返回 `bool` 值。若直接使用高层接口调用 `IERC20(token).transfer(...)`，Solidity 0.5+ 会在底层因 `RETURNDATASIZE < 32` 强制 Revert。

`Vault.sol` 采用底层 `call` + **短路求值** 进行安全转账封装：
```solidity
function _safeTransfer(address to, uint256 amount) internal {
    (bool success, bytes memory data) = address(token).call(
        abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
    );
    // 兼容 USDT（data.length == 0）及返回 true 的标准代币，同时拦截返回 false 的异常代币
    if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
        revert TransferFailed();
    }
}
```

### 2. Gas 优化的防重入锁（Reentrancy Guard）
* 使用状态变量 `uint256 private _status`，以 `_NOT_ENTERED = 1` 和 `_ENTERED = 2` 作为锁状态。
* 避免了使用 `bool` 时从 `0` 修改为 `1` 的高昂 SSTORE Gas 消耗（Cold to Dirty 写入开销）。

### 3. 严格遵循 CEI 原则（Checks-Effects-Interactions）
* 在 `withdraw` 函数中，先校验余额，扣除内部账本，发射事件，**最后一步**才调用外部代币合约转账，杜绝跨函数重入风险。

### 4. 紧急熔断机制（Circuit Breaker / Pausable）
* 遭遇黑天鹅事件或极端市场风险时，管理员可调用 `pause()` 暂停金库的所有充值与提取。
* 风险排除后调用 `unpause()` 恢复正常业务。

### 5. 工厂模式的所有权交接
* 在工厂部署 `new Vault(token)` 时，EVM 的 `msg.sender` 会变成工厂合约地址。
* 工厂合约在创建完成后，立即执行 `newVault.transferOwnership(msg.sender)`，将金库管理权平滑交回给最初的发起人。

---

## 目录结构

```text
.
├── src/
│   ├── MyToken.sol           # 标准 ERC-20 代币合约
│   ├── Vault.sol             # 保险库合约
│   └── VaultFactory.sol      # 金库工厂合约
├── test/
│   └── Vault.t.sol           # 单元测试与 Fuzz 模糊测试（共 24 项测试）
├── foundry.toml              # Foundry 配置文件
└── README.md                 # 项目文档
```

---

## 快速开始

### 依赖环境

本项目基于 [Foundry](https://getfoundry.sh/) 构建。请先确保本地安装了 Foundry 工具链：

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### 编译合约

```bash
forge build
```

### 运行测试

本项目包含全方位的测试用例（包括边界检查、事件验证、权限拦截、多用户隔离与 Fuzz 随机模糊测试）：

```bash
# 运行全部测试
forge test

# 查看详细调用轨迹（Trace）
forge test -vvv

# 仅运行模糊测试 (Fuzz Testing)
forge test --match-test testFuzz -vv
```

---

## 核心业务流转与机制说明

### 1. 充值流程（Deposit）
1. 用户在代币合约中授权：`token.approve(vaultAddress, amount)`。
2. 用户调用金库充值：`vault.deposit(amount)`。
3. 金库校验 `amount > 0` 及用户余额，扣除代币并计入内部账本 `balanceOf[user]`。

### 2. 提取流程（Withdraw）
1. 用户调用金库提取：`vault.withdraw(amount)`。
2. 金库校验用户存款余额，扣减内部记账。
3. 金库通过 `_safeTransfer` 将代币安全转回给用户钱包。

### 3. 前端与合约交互范式（0 Gas 寻址）
前端不需要硬编码各币种的金库地址，而是通过工厂合约的公共映射实时查询：

```javascript
// 1. 查询代币对应的金库地址（免费只读调用）
const vaultAddress = await factoryContract.getVault(USDT_ADDRESS);

if (vaultAddress === ethers.ZeroAddress) {
    console.log("该代币金库尚未创建");
} else {
    // 2. 连接金库进行存取操作
    const vault = new ethers.Contract(vaultAddress, VaultABI, signer);
    await vault.deposit(ethers.parseEther("100"));
}
```

---

## 许可证

本项目采用 [MIT License](./LICENSE) 协议开源。
