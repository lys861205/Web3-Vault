pragma solidity ^0.8.13;

import "./Vault.sol";

contract VaultFactory {
  
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
  }

  function createVault(address token) external onlyOwner returns (address) {
    if (address(0) == token) revert ZeroAddress();

    if (getVault[token] != address(0)) {
      revert VaultAlreadyExists(token, getVault[token]);
    }

    Vault newVault = new Vault(IERC20(token));
    address newVaultAddress = address(newVault);

    emit VaultCreated(token, newVaultAddress);

    getVault[token] = newVaultAddress;
    vaults.push(newVaultAddress);

    // 把金库的所有权转移给
    newVault.transferOwnership(msg.sender);

    return newVaultAddress;
  }

  function getAllVaults() external view returns (uint256) {
    return vaults.length;
  }
}
