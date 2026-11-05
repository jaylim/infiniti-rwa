// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import {OwnableUpgradeable} from "../openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IToken} from "../erc-3643/token/IToken.sol";
import {IModularCompliance} from "../erc-3643/compliance/modular/IModularCompliance.sol";
import {AbstractModuleUpgradeable} from "../erc-3643/compliance/modular/modules/AbstractModuleUpgradeable.sol";

/**
 * @title MaxBalanceModule
 * @notice Limits how many tokens one investor identity can hold, added up across all of its wallets.
 * @dev One proxy can serve several compliance contracts; each keeps its own limit and balances. The module tracks
 * balances itself, so it cannot bind to a token that already has supply until the compliance owner has preset the
 * existing identity balances and called `presetCompleted`. A limit that was never set is zero, which rejects every
 * mint and incoming transfer, so a compliance contract should set the limit as soon as it binds this module.
 */
contract MaxBalanceModule is AbstractModuleUpgradeable {
    /// @dev Compliance contract => maximum balance per identity, in token base units.
    mapping(address => uint256) private _maxBalance;

    /// @dev Compliance contract => identity => tracked balance, in token base units.
    mapping(address => mapping(address => uint256)) private _identityBalance;

    /// @dev Compliance contract => the owner has confirmed the preset balances are complete.
    mapping(address => bool) private _presetDone;

    /**
     * @notice Emitted when a compliance contract sets its limit.
     * @param _compliance The compliance contract.
     * @param _maxBalance The new maximum balance per identity, in token base units.
     */
    event MaxBalanceSet(address indexed _compliance, uint256 indexed _maxBalance);

    /**
     * @notice Emitted when the compliance owner presets an identity's balance.
     * @param _compliance The compliance contract.
     * @param _id The investor identity.
     * @param _balance The preset balance, in token base units.
     */
    event IDBalancePreSet(address indexed _compliance, address indexed _id, uint256 _balance);

    /**
     * @notice Emitted when the compliance owner confirms the preset balances are complete.
     * @param _compliance The compliance contract.
     */
    event PresetCompleted(address indexed _compliance);

    /**
     * @notice Thrown when batch preset arrays are empty or differ in length.
     * @param _compliance The compliance contract.
     * @param _id The identities supplied.
     * @param _balance The balances supplied.
     */
    error InvalidPresetValues(address _compliance, address[] _id, uint256[] _balance);

    /**
     * @notice Thrown when a mint or transfer would take an identity above the limit.
     * @param _compliance The compliance contract.
     * @param _value The amount being moved, in token base units.
     */
    error MaxBalanceExceeded(address _compliance, uint256 _value);

    /**
     * @notice Thrown when a preset function is called by anyone but the compliance owner.
     * @param _compliance The compliance contract.
     */
    error OnlyComplianceOwnerCanCall(address _compliance);

    /**
     * @notice Thrown when presetting a balance after the module is bound to the compliance contract.
     * @param _compliance The compliance contract.
     */
    error TokenAlreadyBound(address _compliance);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy and makes the caller its owner.
    function initialize() external initializer {
        __AbstractModule_init();
    }

    /**
     * @notice Sets the calling compliance contract's limit.
     * @dev Callable only by a bound compliance contract. Balances already above a lowered limit stay as they are;
     * those identities simply cannot receive more.
     * @param _max The new maximum balance per identity, in token base units.
     */
    function setMaxBalance(uint256 _max) external onlyComplianceCall {
        _maxBalance[msg.sender] = _max;
        emit MaxBalanceSet(msg.sender, _max);
    }

    /**
     * @notice Presets an identity's tracked balance before the module is bound.
     * @dev Callable only by the compliance owner, while the module is not bound.
     * @param _compliance The compliance contract.
     * @param _id The investor identity.
     * @param _balance The identity's balance across all its wallets, in token base units.
     */
    function preSetModuleState(address _compliance, address _id, uint256 _balance) external {
        _requirePresetAccess(_compliance);
        _preset(_compliance, _id, _balance);
    }

    /**
     * @notice Presets several identities' tracked balances before the module is bound, and marks presets complete.
     * @dev Callable only by the compliance owner, while the module is not bound. Allows binding to a token with
     * supply straight away, without emitting `PresetCompleted`, so send all balances in one batch or preset the rest
     * before binding. The caller is privileged and chooses the batch size.
     * @param _compliance The compliance contract.
     * @param _id The investor identities.
     * @param _balance Each identity's balance across all its wallets, in token base units.
     */
    function batchPreSetModuleState(address _compliance, address[] calldata _id, uint256[] calldata _balance) external {
        uint256 length = _id.length;
        if (length == 0 || length != _balance.length) {
            revert InvalidPresetValues(_compliance, _id, _balance);
        }
        _requirePresetAccess(_compliance);
        for (uint256 i; i < length; ++i) {
            _preset(_compliance, _id[i], _balance[i]);
        }
        _presetDone[_compliance] = true;
    }

    /**
     * @notice Confirms the preset balances are complete, which allows binding to a token with supply.
     * @dev Callable only by the compliance owner.
     * @param _compliance The compliance contract.
     */
    function presetCompleted(address _compliance) external {
        _requireComplianceOwner(_compliance);
        _presetDone[_compliance] = true;
        emit PresetCompleted(_compliance);
    }

    /**
     * @notice Moves tracked balance between two identities after a transfer.
     * @dev Callable only by a bound compliance contract. Also reverts here because forced transfers reach this
     * function without passing `moduleCheck`. Wallets sharing one identity net out before the limit is checked.
     * @param _from The sender.
     * @param _to The receiver.
     * @param _value The amount moved, in token base units.
     */
    function moduleTransferAction(address _from, address _to, uint256 _value) external override onlyComplianceCall {
        address fromId = _identityOf(msg.sender, _from);
        address toId = _identityOf(msg.sender, _to);
        _identityBalance[msg.sender][toId] += _value;
        _identityBalance[msg.sender][fromId] -= _value;
        if (_identityBalance[msg.sender][toId] > _maxBalance[msg.sender]) {
            revert MaxBalanceExceeded(msg.sender, _value);
        }
    }

    /**
     * @notice Adds to an identity's tracked balance after a mint.
     * @dev Callable only by a bound compliance contract.
     * @param _to The receiver.
     * @param _value The amount minted, in token base units.
     */
    function moduleMintAction(address _to, uint256 _value) external override onlyComplianceCall {
        address toId = _identityOf(msg.sender, _to);
        _identityBalance[msg.sender][toId] += _value;
        if (_identityBalance[msg.sender][toId] > _maxBalance[msg.sender]) {
            revert MaxBalanceExceeded(msg.sender, _value);
        }
    }

    /**
     * @notice Subtracts from an identity's tracked balance after a burn.
     * @dev Callable only by a bound compliance contract.
     * @param _from The holder.
     * @param _value The amount burnt, in token base units.
     */
    function moduleBurnAction(address _from, uint256 _value) external override onlyComplianceCall {
        _identityBalance[msg.sender][_identityOf(msg.sender, _from)] -= _value;
    }

    /**
     * @notice Checks whether the receiver's identity would stay within the limit.
     * @param _to The receiver.
     * @param _value The amount being moved, in token base units.
     * @param _compliance The compliance contract asking.
     * @return True if the movement is allowed.
     */
    function moduleCheck(
        address /*_from*/,
        address _to,
        uint256 _value,
        address _compliance
    ) external view override returns (bool) {
        uint256 limit = _maxBalance[_compliance];
        if (_value > limit) {
            return false;
        }
        return _identityBalance[_compliance][_identityOf(_compliance, _to)] + _value <= limit;
    }

    /**
     * @notice Returns an identity's tracked balance.
     * @param _compliance The compliance contract.
     * @param _identity The investor identity.
     * @return The tracked balance, in token base units.
     */
    function getIDBalance(address _compliance, address _identity) external view returns (uint256) {
        return _identityBalance[_compliance][_identity];
    }

    /**
     * @notice Returns whether a compliance contract can bind this module.
     * @param _compliance The compliance contract.
     * @return True if presets are confirmed complete or its token has no supply.
     */
    function canComplianceBind(address _compliance) external view override returns (bool) {
        if (_presetDone[_compliance]) {
            return true;
        }
        return IToken(IModularCompliance(_compliance).getTokenBound()).totalSupply() == 0;
    }

    /// @notice This module needs preset balances before it can bind to a token with supply.
    function isPlugAndPlay() external pure override returns (bool) {
        return false;
    }

    /// @notice Returns the module's name.
    function name() public pure override returns (string memory _name) {
        return "MaxBalanceModule";
    }

    function _preset(address compliance, address id, uint256 balance) private {
        _identityBalance[compliance][id] = balance;
        emit IDBalancePreSet(compliance, id, balance);
    }

    function _requirePresetAccess(address compliance) private view {
        _requireComplianceOwner(compliance);
        if (this.isComplianceBound(compliance)) {
            revert TokenAlreadyBound(compliance);
        }
    }

    function _requireComplianceOwner(address compliance) private view {
        if (OwnableUpgradeable(compliance).owner() != msg.sender) {
            revert OnlyComplianceOwnerCanCall(compliance);
        }
    }

    function _identityOf(address compliance, address wallet) private view returns (address id) {
        IToken token = IToken(IModularCompliance(compliance).getTokenBound());
        id = address(token.identityRegistry().identity(wallet));
        require(id != address(0), "identity not found");
    }
}
