// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import {IToken} from "../erc-3643/token/IToken.sol";
import {IModularCompliance} from "../erc-3643/compliance/modular/IModularCompliance.sol";
import {AbstractModuleUpgradeable} from "../erc-3643/compliance/modular/modules/AbstractModuleUpgradeable.sol";

/**
 * @title SupplyLimitModule
 * @notice Rejects any mint that would take a token's total supply above the limit set by its compliance contract.
 * @dev One proxy can serve several compliance contracts; each keeps its own limit. A limit that was never set is
 * zero, which rejects every mint, so a compliance contract should set the limit as soon as it binds this module.
 * A limit may be set below the current supply: existing tokens are unaffected and further mints are rejected.
 */
contract SupplyLimitModule is AbstractModuleUpgradeable {
    /// @dev Compliance contract => maximum total supply, in token base units.
    mapping(address => uint256) private _supplyLimits;

    /**
     * @notice Emitted when a compliance contract sets its supply limit.
     * @param _compliance The compliance contract that set the limit.
     * @param _limit The new maximum total supply, in token base units.
     */
    event SupplyLimitSet(address _compliance, uint256 _limit);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy and makes the caller its owner.
    function initialize() external initializer {
        __AbstractModule_init();
    }

    /**
     * @notice Sets the calling compliance contract's supply limit.
     * @dev Callable only by a bound compliance contract.
     * @param _limit The new maximum total supply, in token base units.
     */
    function setSupplyLimit(uint256 _limit) external onlyComplianceCall {
        _supplyLimits[msg.sender] = _limit;
        emit SupplyLimitSet(msg.sender, _limit);
    }

    /// @notice This module keeps no state per transfer.
    function moduleTransferAction(address _from, address _to, uint256 _value) external override onlyComplianceCall {}

    /// @notice This module keeps no state per mint; the limit is read from the token's total supply.
    function moduleMintAction(address _to, uint256 _value) external override onlyComplianceCall {}

    /// @notice This module keeps no state per burn; burning makes room through the token's total supply.
    function moduleBurnAction(address _from, uint256 _value) external override onlyComplianceCall {}

    /**
     * @notice Checks whether a token movement keeps the total supply within the limit.
     * @dev Only mints are restricted, identified by a zero `_from`. Reverts on arithmetic overflow.
     * @param _from The sender, or the zero address for a mint.
     * @param _value The amount being moved, in token base units.
     * @param _compliance The compliance contract asking.
     * @return True if the movement is allowed.
     */
    function moduleCheck(
        address _from,
        address /*_to*/,
        uint256 _value,
        address _compliance
    ) external view override returns (bool) {
        if (_from != address(0)) {
            return true;
        }
        IToken token = IToken(IModularCompliance(_compliance).getTokenBound());
        return token.totalSupply() + _value <= _supplyLimits[_compliance];
    }

    /**
     * @notice Returns a compliance contract's supply limit.
     * @param _compliance The compliance contract.
     * @return The maximum total supply, in token base units.
     */
    function getSupplyLimit(address _compliance) external view returns (uint256) {
        return _supplyLimits[_compliance];
    }

    /// @notice Any compliance contract can bind this module.
    function canComplianceBind(address /*_compliance*/) external view override returns (bool) {
        return true;
    }

    /// @notice This module needs no preset state, so it can bind to a token that already has supply.
    function isPlugAndPlay() external pure override returns (bool) {
        return true;
    }

    /// @notice Returns the module's name.
    function name() public pure override returns (string memory _name) {
        return "SupplyLimitModule";
    }
}
