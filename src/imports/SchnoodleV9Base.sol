// contracts/imports/SchnoodleV9Base.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../proxy/utils/Initializable.sol";
import "../token/ERC777/presets/ERC777PresetFixedSupplyUpgradeable.sol";
import "../access/OwnableUpgradable.sol";
import "../utils/math/MathUpgradeable.sol";

abstract contract SchnoodleV9Base is ERC777PresetFixedSupplyUpgradeable, OwnableUpgradeable {
    uint256 private constant MAX = ~uint256(0);
    uint256 private _totalSupply;
    uint256 private _feeRate;
    address private _eleemosynaryAccount;
    uint256 private _donationRate;
    uint256 private _sellThreshold;
    TokenMeter private _sellQuota;
    uint256 private _rateEscalator;

    struct TokenMeter {
        uint256 blockMetric;
        int256 amount;
    }

    function initialize(uint256 initialTokens, address serviceAccount) public initializer {
        __Ownable_init();
        _totalSupply = initialTokens * 10 ** decimals();
        __ERC777PresetFixedSupply_init("Schnoodle", "SNOOD", new address[](0), MAX - (MAX % totalSupply()), serviceAccount);
    }

    function configure(bool initialSetup) internal onlyOwner {
        if (initialSetup) {
            _feeRate = 40;
            _rateEscalator = 6;
            _sellThreshold = 10 ** 9 * 10 ** decimals();
        }
    }

    // Transfer overrides

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _getStandardAmount(super.balanceOf(account));
    }

    function allowance(address holder, address spender) public view override returns (uint256) {
        return _getStandardAmount(super.allowance(holder, spender));
    }

    function _approve(address holder, address spender, uint256 value) internal override {
        super._approve(holder, spender, _getReflectedAmount(value));
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal override {
        super._spendAllowance(owner, spender, _getStandardAmount(amount));
    }

    function _mint(address account, uint256 amount) internal {
        super._mint(account, _getReflectedAmount(amount), "", "");
        _totalSupply += amount;
    }

    function _burn(address account, uint256 amount, bytes memory data, bytes memory operatorData) internal override {
        super._burn(account, _getReflectedAmount(amount), data, operatorData);
        _totalSupply -= amount;
    }

    function _send(address from, address to, uint256 amount, bytes memory userData, bytes memory operatorData, bool requireReceptionAck) internal override {
        uint256 reflectedAmount = _getReflectedAmount(amount);
        super._send(from, to, reflectedAmount, userData, operatorData, requireReceptionAck);
        processSwap(from, to, amount, reflectedAmount);
    }

    function _transformAmount(uint256 amount) internal view override returns (uint256) {
        return _getStandardAmount(amount);
    }

    // Reflection convenience functions

    function _transferFromReflected(address from, address to, uint256 reflectedAmount) internal {
        super._approve(from, _msgSender(), reflectedAmount);
        super.transferFrom(from, to, reflectedAmount);
    }

    function _getReflectedAmount(uint256 amount) internal view returns(uint256) {
        return amount * _getReflectRate();
    }

    function _getStandardAmount(uint256 reflectedAmount) internal view returns(uint256) {
        // Condition prevents a divide-by-zero error when the total supply is zero
        return reflectedAmount == 0 ? 0 : reflectedAmount / _getReflectRate();
    }

    function _getReflectRate() private view returns(uint256) {
        uint256 reflectedTotalSupply = super.totalSupply();
        return reflectedTotalSupply == 0 ? 0 : reflectedTotalSupply / totalSupply();
    }

    // Taxation functions

    function processSwap(address from, address to, uint256 amount, uint256 reflectedAmount) internal virtual {
        bool buy = isLiquidityToken(from);
        bool sell = !buy && isLiquidityToken(to);

        // Maintain a sell quota as the net of all daily buys and sells, plus a predefined threshold
        if (_sellThreshold > 0) {
            uint256 blockTimestamp = block.timestamp;

            if (_sellQuota.blockMetric == 0 || _sellQuota.blockMetric < blockTimestamp - 1 days) {
                _sellQuota.blockMetric = blockTimestamp;
                _sellQuota.amount = int256(_sellThreshold);
                emit SellQuotaChanged(_sellQuota.blockMetric, _sellQuota.amount);
            }

            _sellQuota.amount += (buy ? int256(1) : (sell ? -1 : int256(0))) * int256(amount);
            emit SellQuotaChanged(_sellQuota.blockMetric, _sellQuota.amount);
        }

        // Proceed to pay fee and tax if only a sell at this point
        if (!sell) return;

        payFees(to, amount, reflectedAmount);
    }

    function isLiquidityToken(address) internal view virtual returns(bool);

    function payFees(address to, uint256 amount, uint256 reflectedAmount) internal virtual {
        uint256 operativeFeeRate = getOperativeFeeRate();
        super._burn(to, reflectedAmount / 1000 * operativeFeeRate, "", "");

        payFund(to, _eleemosynaryAccount, amount, _donationRate);
    }

    function payFund(address from, address to, uint256 amount, uint256 rate) internal {
        // Skip if not enabled ('to' address not set)
        if (to != address(0)) {
            uint256 fundAmount = amount * rate / 1000;
            uint256 reflectedFundAmount = _getReflectedAmount(fundAmount);
            super._send(from, to, reflectedFundAmount, "", "", true);
        }
    }

    function changeFeeRate(uint256 rate) external onlyOwner {
        _feeRate = rate;
        emit FeeRateChanged(rate);
    }

    function getFeeRate() external view returns(uint256) {
        return _feeRate;
    }

    function getOperativeFeeRate() public view returns(uint256) {
        // Increase the fee linearly when the sell quota is negative (more daily sells than buys including the predefined threshold)
        if (_sellThreshold > 0 && _sellQuota.amount < 0)
        {
            return _feeRate + _feeRate * _rateEscalator * MathUpgradeable.min(uint256(-_sellQuota.amount), _sellThreshold) / _sellThreshold;
        }

        return _feeRate;
    }

    function changeEleemosynaryDetails(address eleemosynaryAccount, uint256 donationRate) external onlyOwner {
        _eleemosynaryAccount = eleemosynaryAccount;
        _donationRate = donationRate;
        emit EleemosynaryDetailsChanged(eleemosynaryAccount, donationRate);
    }

    function getEleemosynaryDetails() external view returns(address, uint256) {
        return (_eleemosynaryAccount, _donationRate);
    }

    // Price Support Mechanism functions

    function changeSellThresholdDetails(uint256 sellThreshold, uint256 rateEscalator) external onlyOwner {
        _sellThreshold = sellThreshold;
        _rateEscalator = rateEscalator;
        emit SellThresholdDetailsChanged(sellThreshold, rateEscalator);
    }

    function getSellThresholdDetails() external view returns(uint256, uint256) {
        return (_sellThreshold, _rateEscalator);
    }

    function getSellQuota() external view returns(TokenMeter memory) {
        return _sellQuota;
    }

    // Events

    event FeeRateChanged(uint256 rate);

    event EleemosynaryDetailsChanged(address indexed eleemosynaryAccount, uint256 donationRate);

    event SellThresholdDetailsChanged(uint256 sellThreshold, uint256 rateEscalator);

    event SellQuotaChanged(uint256 blockTimestamp, int256 amount);
}