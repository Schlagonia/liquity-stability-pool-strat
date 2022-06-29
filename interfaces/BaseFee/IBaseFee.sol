// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;

interface IBaseFee {
    function isCurrentBaseFeeAcceptable() external view returns (bool);
}

interface IBaseFeeOracle {
    function basefee_global() external view returns (uint256);
}
