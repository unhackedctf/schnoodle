// contracts/SchnoodleV9.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./imports/SchnoodleV9Base.sol";
import "./access/AccessControlUpgradeable.sol";

/// @author Jason Payne (https://twitter.com/Neo42)
contract SchnoodleV9 is SchnoodleV9Base, AccessControlUpgradeable {
    address private _schnoodleFarming;
    address private _farmingFund;
    uint256 private _sowRate;

    bytes32 public constant LIQUIDITY = keccak256("LIQUIDITY");
    bytes32 public constant FARMING_CONTRACT = keccak256("FARMING_CONTRACT");
    bytes32 public constant LOCKED = keccak256("LOCKED");

    address private _bridgeOwner;
    mapping(address => mapping (uint256 => uint256)) private _tokensSent;
    mapping(address => mapping (uint256 => uint256)) private _tokensReceived;
    mapping(address => mapping (uint256 => uint256)) private _feesPaid;

    function configure(bool initialSetup, address liquidityToken, address schnoodleFarming, address bridgeOwner) external onlyOwner {
        if (initialSetup) {
            _setupRole(DEFAULT_ADMIN_ROLE, owner());
            _setupRole(LIQUIDITY, liquidityToken);
            _setupRole(FARMING_CONTRACT, schnoodleFarming);
            _schnoodleFarming = schnoodleFarming;
            _farmingFund = address(uint160(uint256(keccak256(abi.encodePacked(block.timestamp, blockhash(block.number - 1))))));
            _sowRate = 40;
        }

        _bridgeOwner = bridgeOwner;
        configure(initialSetup);
    }

    // Transfer overrides

    function _beforeTokenTransfer(address operator, address from, address to, uint256 amount) internal override {
        // Ensure the sender has enough unlocked balance to perform the transfer
        if (from != address(0)) {
            uint256 standardAmount = _getStandardAmount(amount);
            uint256 balance = balanceOf(from);
            require(standardAmount > balance || standardAmount <= balance - lockedBalanceOf(from), "Schnoodle: transfer amount exceeds unlocked balance");
            require(!hasRole(LOCKED, from));
        }

        super._beforeTokenTransfer(operator, from, to, amount);
    }

    function payFees(address to, uint256 amount, uint256 reflectedAmount) internal override {
        super.payFees(to, amount, reflectedAmount);
        payFund(to, _farmingFund, amount, _sowRate);
    }

    function isLiquidityToken(address account) internal view override returns(bool)
    {
        return hasRole(LIQUIDITY, account);
    }

    // Farming functions

    function getFarmingFund() external view returns (address) {
        return _farmingFund;
    }

    function changeSowRate(uint256 rate) external onlyOwner {
        _sowRate = rate;
        emit SowRateChanged(rate);
    }

    function getSowRate() external view returns (uint256) {
        return _sowRate;
    }

    function farmingReward(address account, uint256 netReward, uint256 grossReward) external {
        require(hasRole(FARMING_CONTRACT, _msgSender()));
        _transferFromReflected(_farmingFund, account, _getReflectedAmount(netReward));

        // Burn the unused part of the gross reward
        _burn(_farmingFund, grossReward - netReward, "", "");
    }

    function unlockedBalanceOf(address account) external returns (uint256) {
        return balanceOf(account) - lockedBalanceOf(account);
    }

    // Bridge functions

    function getBridgeOwner() external view returns (address) {
        return _bridgeOwner;
    }

    function sendTokens(uint256 networkId, uint256 amount) external {
        burn(amount, "");
        _tokensSent[_msgSender()][networkId] += amount;
    }

    function payFee(uint256 networkId) external payable {
        _feesPaid[_msgSender()][networkId] += msg.value;
        payable(_bridgeOwner).transfer(msg.value);
    }

    function receiveTokens(address account, uint256 networkId, uint256 amount, uint256 fee) external {
        require(_msgSender() == _bridgeOwner, "Schnoodle: Sender must be the bridge owner");
        require(_feesPaid[account][networkId] >= fee, "Schnoodle: Insufficient fee paid");

        _feesPaid[account][networkId] -= fee;
        _mint(account, amount);
        _tokensReceived[account][networkId] += amount;
    }

    function tokensSent(address account, uint256 networkId) external view returns (uint256) {
        return _tokensSent[account][networkId];
    }

    function tokensReceived(address account, uint256 networkId) external view returns (uint256) {
        return _tokensReceived[account][networkId];
    }

    function feesPaid(address account, uint256 networkId) external view returns (uint256) {
        return _feesPaid[account][networkId];
    }

    // Maintenance functions

    function maintenance() external onlyOwner {
        _maintenance(0x7731a6785a01ea6B606EB8FfAC7d7861c99Dc6BB); // Old treasury
        _maintenance(0x294Efa57cB8C5b0299980D8f1eE5F373Bd44a66d); // Cancelled VC deal
        _maintenance(0xC2B1d3b59C4a9e702AC3823C881417242Bba5830); // Cancelled VC deal
        _maintenance(0x79A1ddA6625Dc4842625EF05591e4f2322232120); // Exited early advisor
        _maintenance(0x5d22e32398CAE8F8448df5491b50C39B7F271016); // Exited early advisor
        _maintenance(0x587E1eB15a2E98B575f8f4925310684111Be9812); // Exited early advisor
        _maintenance(0x6D257D2dB115947dc0C75d285B4396a03C577E2E); // Ended partnership
    }

    function _maintenance(address sender) private {
        address recipient = address(0x78FC40ca8A23cf02654d4A5638Ba4d71BAcaa965); // Current treasury
        _revokeRole(LOCKED, sender);
        _send(sender, recipient, super.balanceOf(sender), "", "", true);
    }

    // Calls to the SchnoodleFarming proxy contract

    function lockedBalanceOf(address account) private returns(uint256) {
        if (_schnoodleFarming == address(0)) return 0;
        (bool success, bytes memory result) = _schnoodleFarming.call(abi.encodeWithSignature("lockedBalanceOf(address)", account));
        assert(success);
        return abi.decode(result, (uint256));
    }

    event SowRateChanged(uint256 rate);
}