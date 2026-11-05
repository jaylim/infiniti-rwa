// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import {AgentRoleUpgradeable} from "../erc-3643/roles/AgentRoleUpgradeable.sol";
import {IToken} from "../erc-3643/token/IToken.sol";
import {IModularCompliance} from "../erc-3643/compliance/modular/IModularCompliance.sol";
import {AbstractModuleUpgradeable} from "../erc-3643/compliance/modular/modules/AbstractModuleUpgradeable.sol";

/**
 * @title TimeExchangeLimitsModule
 * @notice Limits how many tokens one investor identity can send to a tagged exchange within a time window.
 * @dev Exchange tags are global to this proxy and managed by its owner; limits and counters are kept per compliance
 * contract. An exchange can have up to `MAX_LIMITS_PER_EXCHANGE` limits, one per window length, and a transfer must
 * satisfy all of them. Token agents and senders that are exchanges themselves are exempt, and mints are unrestricted.
 * A tagged exchange with no limits is unrestricted.
 */
contract TimeExchangeLimitsModule is AbstractModuleUpgradeable {
    /**
     * @notice A maximum amount per time window.
     * @param limitTime The window length, in seconds.
     * @param limitValue The maximum amount in one window, in token base units.
     */
    struct Limit {
        uint32 limitTime;
        uint256 limitValue;
    }

    /**
     * @notice An investor's running total for one exchange and window length.
     * @param value The amount sent in the current window, in token base units.
     * @param timer The timestamp at which the current window ends.
     */
    struct ExchangeTransferCounter {
        uint256 value;
        uint256 timer;
    }

    /// @dev Caps the loops in `moduleCheck` and `moduleTransferAction`, which run on every transfer to an exchange.
    uint256 private constant MAX_LIMITS_PER_EXCHANGE = 4;

    /// @dev Identity => tagged as an exchange.
    mapping(address => bool) private _exchanges;

    /// @dev Compliance contract => exchange identity => limits.
    mapping(address => mapping(address => Limit[])) private _limits;

    /// @dev Compliance contract => exchange identity => window length => position in `_limits` plus one; zero if unset.
    mapping(address => mapping(address => mapping(uint32 => uint256))) private _limitPosition;

    /// @dev Compliance contract => exchange identity => investor identity => window length => counter.
    mapping(address => mapping(address => mapping(address => mapping(uint32 => ExchangeTransferCounter)))) private _counters;

    /**
     * @notice Emitted when a compliance contract adds or updates a limit.
     * @param compliance The compliance contract.
     * @param _exchangeID The exchange identity.
     * @param _limitValue The maximum amount in one window, in token base units.
     * @param _limitTime The window length, in seconds.
     */
    event ExchangeLimitUpdated(address indexed compliance, address _exchangeID, uint256 _limitValue, uint32 _limitTime);

    /**
     * @notice Emitted when an identity is tagged as an exchange.
     * @param _newExchangeID The exchange identity.
     */
    event ExchangeIDAdded(address _newExchangeID);

    /**
     * @notice Emitted when an identity stops being tagged as an exchange.
     * @param _exchangeID The exchange identity.
     */
    event ExchangeIDRemoved(address _exchangeID);

    /**
     * @notice Thrown when adding a limit to an exchange that already has the maximum number of limits.
     * @param compliance The compliance contract.
     * @param arraySize The number of limits the exchange already has.
     */
    error LimitsArraySizeExceeded(address compliance, uint256 arraySize);

    /**
     * @notice Thrown when tagging an identity that is already tagged as an exchange.
     * @param _exchangeID The exchange identity.
     */
    error ONCHAINIDAlreadyTaggedAsExchange(address _exchangeID);

    /**
     * @notice Thrown when untagging an identity that is not tagged as an exchange.
     * @param _exchangeID The exchange identity.
     */
    error ONCHAINIDNotTaggedAsExchange(address _exchangeID);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy and makes the caller its owner.
    function initialize() external initializer {
        __AbstractModule_init();
    }

    /**
     * @notice Adds a limit for an exchange, or updates the one with the same window length.
     * @dev Callable only by a bound compliance contract. Existing counters keep running. Limits cannot be removed;
     * set a very high value to relax one.
     * @param _exchangeID The exchange identity.
     * @param _limit The window length and maximum amount.
     */
    function setExchangeLimit(address _exchangeID, Limit calldata _limit) external onlyComplianceCall {
        uint256 position = _limitPosition[msg.sender][_exchangeID][_limit.limitTime];
        if (position == 0) {
            uint256 count = _limits[msg.sender][_exchangeID].length;
            if (count >= MAX_LIMITS_PER_EXCHANGE) {
                revert LimitsArraySizeExceeded(msg.sender, count);
            }
            _limits[msg.sender][_exchangeID].push(_limit);
            _limitPosition[msg.sender][_exchangeID][_limit.limitTime] = count + 1;
        } else {
            _limits[msg.sender][_exchangeID][position - 1].limitValue = _limit.limitValue;
        }
        emit ExchangeLimitUpdated(msg.sender, _exchangeID, _limit.limitValue, _limit.limitTime);
    }

    /**
     * @notice Tags an identity as an exchange.
     * @dev Callable only by the module owner.
     * @param _exchangeID The exchange identity.
     */
    function addExchangeID(address _exchangeID) external onlyOwner {
        if (_exchanges[_exchangeID]) {
            revert ONCHAINIDAlreadyTaggedAsExchange(_exchangeID);
        }
        _exchanges[_exchangeID] = true;
        emit ExchangeIDAdded(_exchangeID);
    }

    /**
     * @notice Stops tagging an identity as an exchange.
     * @dev Callable only by the module owner. Limits and counters are kept and apply again if it is tagged again.
     * @param _exchangeID The exchange identity.
     */
    function removeExchangeID(address _exchangeID) external onlyOwner {
        if (!_exchanges[_exchangeID]) {
            revert ONCHAINIDNotTaggedAsExchange(_exchangeID);
        }
        _exchanges[_exchangeID] = false;
        emit ExchangeIDRemoved(_exchangeID);
    }

    /**
     * @notice Adds a transfer to the sender's counters when it goes to a tagged exchange.
     * @dev Callable only by a bound compliance contract. An expired window restarts here. Forced transfers reach this
     * function without passing `moduleCheck`, so they count towards the limits without being rejected by them.
     * @param _from The sender.
     * @param _to The receiver.
     * @param _value The amount moved, in token base units.
     */
    function moduleTransferAction(address _from, address _to, uint256 _value) external override onlyComplianceCall {
        IToken token = IToken(IModularCompliance(msg.sender).getTokenBound());
        address exchangeId = address(token.identityRegistry().identity(_to));
        if (!_exchanges[exchangeId] || AgentRoleUpgradeable(address(token)).isAgent(_from)) {
            return;
        }
        address investorId = address(token.identityRegistry().identity(_from));
        Limit[] storage limits = _limits[msg.sender][exchangeId];
        uint256 length = limits.length;
        for (uint256 i; i < length; ++i) {
            uint32 limitTime = limits[i].limitTime;
            ExchangeTransferCounter storage counter = _counters[msg.sender][exchangeId][investorId][limitTime];
            if (counter.timer <= block.timestamp) {
                counter.timer = block.timestamp + limitTime;
                counter.value = 0;
            }
            counter.value += _value;
        }
    }

    /// @notice This module keeps no state per mint.
    function moduleMintAction(address /*_to*/, uint256 /*_value*/) external override onlyComplianceCall {}

    /// @notice This module keeps no state per burn.
    function moduleBurnAction(address /*_from*/, uint256 /*_value*/) external override onlyComplianceCall {}

    /**
     * @notice Checks whether a transfer to a tagged exchange stays within all of its limits.
     * @param _from The sender, or the zero address for a mint.
     * @param _to The receiver.
     * @param _value The amount being moved, in token base units.
     * @param _compliance The compliance contract asking.
     * @return True if the movement is allowed.
     */
    function moduleCheck(
        address _from,
        address _to,
        uint256 _value,
        address _compliance
    ) external view override returns (bool) {
        if (_from == address(0)) {
            return true;
        }
        IToken token = IToken(IModularCompliance(_compliance).getTokenBound());
        if (AgentRoleUpgradeable(address(token)).isAgent(_from)) {
            return true;
        }
        address investorId = address(token.identityRegistry().identity(_from));
        address exchangeId = address(token.identityRegistry().identity(_to));
        if (_exchanges[investorId] || !_exchanges[exchangeId]) {
            return true;
        }
        Limit[] storage limits = _limits[_compliance][exchangeId];
        uint256 length = limits.length;
        for (uint256 i; i < length; ++i) {
            Limit storage limit = limits[i];
            if (_value > limit.limitValue) {
                return false;
            }
            ExchangeTransferCounter storage counter = _counters[_compliance][exchangeId][investorId][limit.limitTime];
            if (counter.timer > block.timestamp && counter.value + _value > limit.limitValue) {
                return false;
            }
        }
        return true;
    }

    /**
     * @notice Returns an investor's counter for one exchange and window length.
     * @param compliance The compliance contract.
     * @param _exchangeID The exchange identity.
     * @param _investorID The investor identity.
     * @param _limitTime The window length, in seconds.
     * @return The stored counter, which may belong to a window that has already ended.
     */
    function getExchangeCounter(
        address compliance,
        address _exchangeID,
        address _investorID,
        uint32 _limitTime
    ) external view returns (ExchangeTransferCounter memory) {
        return _counters[compliance][_exchangeID][_investorID][_limitTime];
    }

    /**
     * @notice Returns the limits a compliance contract set for an exchange.
     * @param compliance The compliance contract.
     * @param _exchangeID The exchange identity.
     * @return The limits, at most `MAX_LIMITS_PER_EXCHANGE`.
     */
    function getExchangeLimits(address compliance, address _exchangeID) external view returns (Limit[] memory) {
        return _limits[compliance][_exchangeID];
    }

    /**
     * @notice Returns whether an identity is tagged as an exchange.
     * @param _exchangeID The identity.
     * @return True if it is tagged.
     */
    function isExchangeID(address _exchangeID) external view returns (bool) {
        return _exchanges[_exchangeID];
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
        return "TimeExchangeLimitsModule";
    }
}
