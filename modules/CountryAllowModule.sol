// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import {IToken} from "../erc-3643/token/IToken.sol";
import {IModularCompliance} from "../erc-3643/compliance/modular/IModularCompliance.sol";
import {AbstractModuleUpgradeable} from "../erc-3643/compliance/modular/modules/AbstractModuleUpgradeable.sol";

/**
 * @title CountryAllowModule
 * @notice Lets tokens reach only wallets whose registered investor country is on the compliance contract's allow list.
 * @dev One proxy can serve several compliance contracts; each keeps its own list. An empty list rejects every
 * mint and transfer, so a compliance contract should add its countries as soon as it binds this module. Countries
 * are ISO 3166-1 numeric codes, as stored in the token's identity registry. Only the receiver is checked.
 */
contract CountryAllowModule is AbstractModuleUpgradeable {
    /// @dev Compliance contract => country code => allowed.
    mapping(address => mapping(uint16 => bool)) private _allowed;

    /**
     * @notice Emitted when a compliance contract allows a country.
     * @param _compliance The compliance contract.
     * @param _country The ISO 3166-1 numeric country code.
     */
    event CountryAllowed(address _compliance, uint16 _country);

    /**
     * @notice Emitted when a compliance contract stops allowing a country.
     * @param _compliance The compliance contract.
     * @param _country The ISO 3166-1 numeric country code.
     */
    event CountryUnallowed(address _compliance, uint16 _country);

    /**
     * @notice Thrown when adding a country that is already allowed.
     * @param _compliance The compliance contract.
     * @param _country The ISO 3166-1 numeric country code.
     */
    error CountryAlreadyAllowed(address _compliance, uint16 _country);

    /**
     * @notice Thrown when removing a country that is not allowed.
     * @param _compliance The compliance contract.
     * @param _country The ISO 3166-1 numeric country code.
     */
    error CountryNotAllowed(address _compliance, uint16 _country);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy and makes the caller its owner.
    function initialize() external initializer {
        __AbstractModule_init();
    }

    /**
     * @notice Allows several countries for the calling compliance contract.
     * @dev Callable only by a bound compliance contract. Idempotent, unlike `addAllowedCountry`: a country that is
     * already allowed stays allowed and still emits an event. The caller is the privileged compliance owner, who
     * chooses the batch size.
     * @param _countries The ISO 3166-1 numeric country codes.
     */
    function batchAllowCountries(uint16[] calldata _countries) external onlyComplianceCall {
        uint256 length = _countries.length;
        for (uint256 i; i < length; ++i) {
            _allowed[msg.sender][_countries[i]] = true;
            emit CountryAllowed(msg.sender, _countries[i]);
        }
    }

    /**
     * @notice Stops allowing several countries for the calling compliance contract.
     * @dev Callable only by a bound compliance contract. Idempotent, unlike `removeAllowedCountry`: a country that is
     * not allowed stays that way and still emits an event. The caller is the privileged compliance owner, who
     * chooses the batch size.
     * @param _countries The ISO 3166-1 numeric country codes.
     */
    function batchDisallowCountries(uint16[] calldata _countries) external onlyComplianceCall {
        uint256 length = _countries.length;
        for (uint256 i; i < length; ++i) {
            _allowed[msg.sender][_countries[i]] = false;
            emit CountryUnallowed(msg.sender, _countries[i]);
        }
    }

    /**
     * @notice Allows a country for the calling compliance contract.
     * @dev Callable only by a bound compliance contract. Reverts if the country is already allowed.
     * @param _country The ISO 3166-1 numeric country code.
     */
    function addAllowedCountry(uint16 _country) external onlyComplianceCall {
        if (_allowed[msg.sender][_country]) {
            revert CountryAlreadyAllowed(msg.sender, _country);
        }
        _allowed[msg.sender][_country] = true;
        emit CountryAllowed(msg.sender, _country);
    }

    /**
     * @notice Stops allowing a country for the calling compliance contract.
     * @dev Callable only by a bound compliance contract. Reverts if the country is not allowed.
     * @param _country The ISO 3166-1 numeric country code.
     */
    function removeAllowedCountry(uint16 _country) external onlyComplianceCall {
        if (!_allowed[msg.sender][_country]) {
            revert CountryNotAllowed(msg.sender, _country);
        }
        _allowed[msg.sender][_country] = false;
        emit CountryUnallowed(msg.sender, _country);
    }

    /// @notice This module keeps no state per transfer.
    function moduleTransferAction(address _from, address _to, uint256 _value) external override onlyComplianceCall {}

    /// @notice This module keeps no state per mint.
    function moduleMintAction(address _to, uint256 _value) external override onlyComplianceCall {}

    /// @notice This module keeps no state per burn.
    function moduleBurnAction(address _from, uint256 _value) external override onlyComplianceCall {}

    /**
     * @notice Checks whether the receiver's registered country is allowed.
     * @param _to The receiver.
     * @param _compliance The compliance contract asking.
     * @return True if the movement is allowed.
     */
    function moduleCheck(
        address /*_from*/,
        address _to,
        uint256 /*_value*/,
        address _compliance
    ) external view override returns (bool) {
        IToken token = IToken(IModularCompliance(_compliance).getTokenBound());
        return _allowed[_compliance][token.identityRegistry().investorCountry(_to)];
    }

    /**
     * @notice Returns whether a compliance contract allows a country.
     * @param _compliance The compliance contract.
     * @param _country The ISO 3166-1 numeric country code.
     * @return True if the country is allowed.
     */
    function isCountryAllowed(address _compliance, uint16 _country) external view returns (bool) {
        return _allowed[_compliance][_country];
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
        return "CountryAllowModule";
    }
}
