// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title 工业级标准 ERC-20 代币合约
contract MyToken {
    // -------------------------------------------------------------
    // 元数据与代币基本信息
    // -------------------------------------------------------------

    string public name;                   // 代币全称，例如 "My Gold Token"
    string public symbol;                 // 代币符号，例如 "MGT"
    uint8 public constant decimals = 18;  // 代币精度：18（以太坊标准，用来模拟小数）
    uint256 public totalSupply;           // 当前全网总流通量

    address public owner;                 // 管理员/所有者

    // -------------------------------------------------------------
    // 核心账本（Storage 状态变量）
    // -------------------------------------------------------------

    // 账本 1：用户地址 => 代币余额
    mapping(address => uint256) public balanceOf;

    // 账本 2：所有者 => (被授权人/被授权合约 => 剩余授权额度)
    mapping(address => mapping(address => uint256)) public allowance;

    // -------------------------------------------------------------
    // 标准事件（前端、钱包、区块链浏览器监听转账必须依赖事件！）
    // -------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // -------------------------------------------------------------
    // 自定义错误（比 require 字符串更省 Gas）
    // -------------------------------------------------------------

    error InsufficientBalance(uint256 available, uint256 required);
    error InsufficientAllowance(uint256 available, uint256 required);
    error InvalidAddress();
    error OnlyOwner();

    // -------------------------------------------------------------
    // 构造函数
    // -------------------------------------------------------------

    /// @notice 部署代币并为部署者初始铸造一定数量的代币
    /// @param _name 代币全称
    /// @param _symbol 代币符号
    /// @param initialSupply 初始代币铸造数量（按枚为单位，例如 1,000,000）
    constructor(string memory _name, string memory _symbol, uint256 initialSupply) {
        name = _name;
        symbol = _symbol;
        owner = msg.sender;

        // 因为 decimals 是 18，所以实际存入底层的数值要乘以 10^18
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply * 10 ** decimals);
        }
    }

    // -------------------------------------------------------------
    // 核心标准函数 1：直接转账 (transfer)
    // -------------------------------------------------------------

    /// @notice 调用者直接向接收方转账
    /// @param to 接收方地址
    /// @param amount 转账金额（带 18 位精度）
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    // -------------------------------------------------------------
    // 核心标准函数 2：授权 (approve)
    // -------------------------------------------------------------

    /// @notice 授权指定地址/合约可以代表自己支配多少代币
    /// @param spender 被授权人（例如 Uniswap 合约地址）
    /// @param amount 授权额度
    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert InvalidAddress();

        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    // -------------------------------------------------------------
    // 核心标准函数 3：被授权方代理扣款 (transferFrom)
    // -------------------------------------------------------------

    /// @notice 被授权方（例如 DEX 路由合约）代替所有者将代币转给第三方
    /// @param from 代币出资人
    /// @param to 接收方
    /// @param amount 转移金额
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];

        // 检查授权额度是否充足（现代 Gas 优化：如果是“无限授权”，则免去扣除步骤）
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) {
                revert InsufficientAllowance(currentAllowance, amount);
            }
            // 扣除相应授权额度
            unchecked {
                allowance[from][msg.sender] = currentAllowance - amount;
            }
        }

        _transfer(from, to, amount);
        return true;
    }

    // -------------------------------------------------------------
    // 管理功能：增发与销毁 (Mint & Burn)
    // -------------------------------------------------------------

    /// @notice 管理员增发新代币（例如空投、流动性激励）
    function mint(address to, uint256 amount) external {
        if (msg.sender != owner) revert OnlyOwner();
        _mint(to, amount);
    }

    /// @notice 任何人都可以主动销毁自己手里的代币（通缩机制）
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    // -------------------------------------------------------------
    // 底层内部公共逻辑 (Internal Functions)
    // -------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0) || from == address(0)) revert InvalidAddress();

        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) {
            revert InsufficientBalance(fromBalance, amount);
        }

        // 扣减出资人余额，累加接收方余额
        unchecked {
            balanceOf[from] = fromBalance - amount;
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        if (to == address(0)) revert InvalidAddress();

        totalSupply += amount;
        unchecked {
            balanceOf[to] += amount;
        }

        // ERC-20 规范：新铸造代币时，from 规定为 0 地址
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        if (from == address(0)) revert InvalidAddress();

        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) {
            revert InsufficientBalance(fromBalance, amount);
        }

        unchecked {
            balanceOf[from] = fromBalance - amount;
            totalSupply -= amount;
        }

        // ERC-20 规范：销毁代币时，to 规定为 0 地址
        emit Transfer(from, address(0), amount);
    }
}
