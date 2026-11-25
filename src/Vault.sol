pragma solidity ^0.8.13;

interface IERC20 {
  function balanceOf(address account) external view returns(uint256);
  function transfer(address to, uint256 amount) external returns(bool);
  function transferFrom(address from, address to, uint256 amount) external returns(bool);
  function approve(address account, uint256 amount) external returns (bool);
}

interface IAave {
  function supply(
    address asset,
    uint256 amount,
    address onBehalfOf,
    uint16  referralCode
  ) external;

  function withdraw(
    address asset,
    uint256 amount,
    address to
  ) external;
}

contract Vault {

  IERC20 public token;
  mapping(address => uint256) public balanceOf;

  //权限控制
  address public owner;
  bool public paused;

  //防止冲入控制变量
  uint256 private constant _NOT_ENTERED = 1;
  uint256 private constant _ENTERED = 2;
  uint256 private _status;


  // 投资或者生息的合约地址
  address public aavePool;

  event OwnershipTrasferred(address indexed previousOwner, address indexed newOwner);
  event Paused(address indexed account);
  event Unpaused(address indexed account);

  event Deposit(address indexed user, uint256 amount);
  event Withdraw(address indexed user, uint256 amount);
  event UpdateAavePool(address indexed oldAavePool, address indexed newAavePool);

  error Unauthorized();
  error EnforcedPause();
  error ExpectedPause();
  error ReentrancyGuardReentrantCall();
  error AlreadyInitialize();

  error Insufficient(uint256 available, uint256 required);
  error ZeroAddress();
  error SameAddress();
  error ZeroAmount();
  error TransferFailed();

  /// @notice 权限控制：仅管理员可用
  modifier onlyOwner() {
    if (msg.sender != owner)  revert Unauthorized();
    _;
  }

  /// @notice 暂停控制：未暂停时才可用
  modifier whenNotPaused() {
    if (paused) revert EnforcedPause();
    _;
  }

  /// @notice 暂停控制：暂停时才可用
  modifier whenPaused() {
    if (!paused) revert ExpectedPause();
    _;
  }
  
  /// @notice 防重入控制：执行期间加锁，防止重复进入
  modifier nonReentrant() {
    if (_status == _ENTERED) revert ReentrancyGuardReentrantCall();
    _status = _ENTERED;
    _;
    _status = _NOT_ENTERED;
  }
  
  function initialize(IERC20 _token, address _owner) external {
    if (address(0) != owner) {
      revert AlreadyInitialize();   
    }
    if (address(0) == _owner) {
      revert ZeroAddress();
    }
    token = _token;
    owner = _owner;
    emit OwnershipTrasferred(address(0), owner);
  }

  function pause() external onlyOwner whenNotPaused {
    paused = true;
    emit Paused(msg.sender);
  }

  function unpause() external onlyOwner whenPaused {
    paused = false;
    emit Unpaused(msg.sender);
  }

  function transferOwnership(address newOwner) external onlyOwner {
    if (newOwner == address(0)) revert ZeroAddress();
    emit OwnershipTrasferred(owner, newOwner);
    owner = newOwner;
  }

  function deposit(uint256 amount) external nonReentrant whenNotPaused {
    if (amount == 0) {
      revert ZeroAmount();
    }
      
    uint256 actualAmount = token.balanceOf(msg.sender);
    if (actualAmount < amount) {
      revert Insufficient(actualAmount, amount);
    }
    balanceOf[msg.sender] += amount;
    emit Deposit(msg.sender, amount);

    _safeTransferFrom(msg.sender, address(this), amount);
  }

  function withdraw(uint256 amount) external nonReentrant whenNotPaused {
    if (amount == 0) {
      revert ZeroAmount();
    } 

    uint256 balance = balanceOf[msg.sender];
    if (balance < amount) {
      revert Insufficient(balance, amount);
    }
    // 1. 
    balanceOf[msg.sender] = balance - amount;
    emit Withdraw(msg.sender, amount);

    // 2. 检查手头资金够不够
    uint256 liquidBalance = token.balanceOf(address(this));
    if (liquidBalance < amount) {
      uint256 delta = amount - liquidBalance;
      if (address(0) == aavePool) {
        revert ZeroAddress();
      }
      // 3. 从aave取回资金
      IAave(aavePool).withdraw(address(token), delta, address(this));
    }

    _safeTransfer(msg.sender, amount);
  }

  function migrateAavePool(address newAavePool) external onlyOwner {
    if (address(0) == newAavePool) {
      revert ZeroAddress();
    }
    if (newAavePool == aavePool) {
      revert SameAddress();
    }
    if (address(0) != aavePool) {
      // 从旧策略中取出所有的资金
      IAave(aavePool).withdraw(address(token), type(uint256).max, address(this));
      // 取出钱之后，解除授权
      token.approve(aavePool, 0);
    }
    emit UpdateAavePool(aavePool, newAavePool);
    aavePool = newAavePool;
  }

  function investToAave(uint256 amount) external onlyOwner {
    if (amount == 0) {
      revert ZeroAmount();
    }

    if (address(0) == aavePool) {
      revert ZeroAddress();
    }
    
    uint256 actualAmount = token.balanceOf(address(this));
    if (actualAmount < amount) {
      revert Insufficient(actualAmount, amount);
    }
    
    //1 金库授权Aave合约，允许转移amount的token代币
    token.approve(aavePool, amount);

    //2 把金库的代币转给aave
    IAave(aavePool).supply(address(token), amount, address(this), 0);
  }

  function _safeTransfer(address to, uint256 amount) internal {
    (bool success, bytes memory data) = address(token).call(
      abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
    if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
      revert TransferFailed();
    }
  }

  function _safeTransferFrom(address from, address to, uint256 amount) internal {
    (bool success, bytes memory data) = address(token).call(
      abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
    if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
      revert TransferFailed();
    }
  }
}
