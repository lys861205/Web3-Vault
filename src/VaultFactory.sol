pragma solidity ^0.8.13;

import "./Vault.sol";

contract VaultFactory {
  
  /// 金库具体实现
  address public immutable vaultImpl;

  address public owner;

  /// 代币地址 => 金库地址
  mapping(address => address) public getVault;
  // 金库列表
  address[] public vaults;

  error ZeroAddress();
  error VaultAlreadyExists(address token, address vault);
  error Unauthorized();

  event VaultCreated(address indexed token, address indexed valutAddress);

  modifier onlyOwner() {
    if (msg.sender != owner) revert Unauthorized();
    _;
  }

  constructor() {
    owner = msg.sender;
    /// 预先部署金库的母体合约
    vaultImpl = address(new Vault());
  }

  function createVault(address token) external onlyOwner returns (address) {
    if (address(0) == token) revert ZeroAddress();

    if (getVault[token] != address(0)) {
      revert VaultAlreadyExists(token, getVault[token]);
    }
    address vaultAddress = _clone(vaultImpl);
    Vault(vaultAddress).initialize(IERC20(token), msg.sender);

    emit VaultCreated(token, vaultAddress);

    getVault[token] = vaultAddress;
    vaults.push(vaultAddress);

    return vaultAddress;
  }

  function getAllVaults() external view returns (uint256) {
    return vaults.length;
  }

  function _clone(address impl) internal returns (address instance) {
    bytes memory bytecode = abi.encodePacked(
      hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
      impl,
      hex"5af43d82803e903d91602b57fd5bf3"
    );
    assembly {
      instance := create(0, add(bytecode, 0x20), mload(bytecode))
    }
    if (address(0) == instance) revert ZeroAddress();
  }

}
