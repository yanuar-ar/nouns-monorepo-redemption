// SPDX-License-Identifier: BSD-3-Clause

/// @title The Nouns DAO executor and treasury

/*********************************
 * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ *
 * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ *
 * ░░░░░░█████████░░█████████░░░ *
 * ░░░░░░██░░░████░░██░░░████░░░ *
 * ░░██████░░░████████░░░████░░░ *
 * ░░██░░██░░░████░░██░░░████░░░ *
 * ░░██░░██░░░████░░██░░░████░░░ *
 * ░░░░░░█████████░░█████████░░░ *
 * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ *
 * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ *
 *********************************/

// LICENSE
// NounsDAOExecutor.sol is a modified version of Compound Lab's Timelock.sol:
// https://github.com/compound-finance/compound-protocol/blob/20abad28055a2f91df48a90f8bb6009279a4cb35/contracts/Timelock.sol
//
// Timelock.sol source code Copyright 2020 Compound Labs, Inc. licensed under the BSD-3-Clause license.
// With modifications by Nounders DAO.
//
// Additional conditions of BSD-3-Clause can be found here: https://opensource.org/licenses/BSD-3-Clause
//
// MODIFICATIONS
// NounsDAOExecutor.sol modifies Timelock to use Solidity 0.8.x receive(), fallback(), and built-in over/underflow protection
// This contract acts as executor of Nouns DAO governance and its treasury, so it has been modified to accept ETH.

pragma solidity ^0.8.6;

import '@paulrberg/contracts/math/PRBMath.sol';
import './NounsDAOInterfaces.sol';

contract NounsDAOExecutor {
    event NewAdmin(address indexed newAdmin);
    event NewPendingAdmin(address indexed newPendingAdmin);
    event NewDelay(uint256 indexed newDelay);
    event CancelTransaction(
        bytes32 indexed txHash,
        address indexed target,
        uint256 value,
        string signature,
        bytes data,
        uint256 eta
    );
    event ExecuteTransaction(
        bytes32 indexed txHash,
        address indexed target,
        uint256 value,
        string signature,
        bytes data,
        uint256 eta
    );
    event QueueTransaction(
        bytes32 indexed txHash,
        address indexed target,
        uint256 value,
        string signature,
        bytes data,
        uint256 eta
    );

    uint256 public constant GRACE_PERIOD = 14 days;
    uint256 public constant MINIMUM_DELAY = 2 days;
    uint256 public constant MAXIMUM_DELAY = 30 days;
    uint256 MAX_REDEMPTION_RATE = 10000;
    uint256 redemptionRate = 7000;

    address public admin;
    address public pendingAdmin;
    uint256 public delay;

    //nouns
    address public nouns;
    address public DAOLogicV1;

    mapping(bytes32 => bool) public queuedTransactions;

    constructor(
        address nouns_,
        address admin_,
        uint256 delay_
    ) {
        require(delay_ >= MINIMUM_DELAY, 'NounsDAOExecutor::constructor: Delay must exceed minimum delay.');
        require(delay_ <= MAXIMUM_DELAY, 'NounsDAOExecutor::setDelay: Delay must not exceed maximum delay.');

        nouns = nouns_;
        DAOLogicV1 = admin_;
        admin = admin_;
        delay = delay_;
    }

    function setDelay(uint256 delay_) public {
        require(msg.sender == address(this), 'NounsDAOExecutor::setDelay: Call must come from NounsDAOExecutor.');
        require(delay_ >= MINIMUM_DELAY, 'NounsDAOExecutor::setDelay: Delay must exceed minimum delay.');
        require(delay_ <= MAXIMUM_DELAY, 'NounsDAOExecutor::setDelay: Delay must not exceed maximum delay.');
        delay = delay_;

        emit NewDelay(delay);
    }

    function acceptAdmin() public {
        require(msg.sender == pendingAdmin, 'NounsDAOExecutor::acceptAdmin: Call must come from pendingAdmin.');
        admin = msg.sender;
        pendingAdmin = address(0);

        emit NewAdmin(admin);
    }

    function setPendingAdmin(address pendingAdmin_) public {
        require(
            msg.sender == address(this),
            'NounsDAOExecutor::setPendingAdmin: Call must come from NounsDAOExecutor.'
        );
        pendingAdmin = pendingAdmin_;

        emit NewPendingAdmin(pendingAdmin);
    }

    function queueTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) public returns (bytes32) {
        require(msg.sender == admin, 'NounsDAOExecutor::queueTransaction: Call must come from admin.');
        require(
            eta >= getBlockTimestamp() + delay,
            'NounsDAOExecutor::queueTransaction: Estimated execution block must satisfy delay.'
        );

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        queuedTransactions[txHash] = true;

        emit QueueTransaction(txHash, target, value, signature, data, eta);
        return txHash;
    }

    function cancelTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) public {
        require(msg.sender == admin, 'NounsDAOExecutor::cancelTransaction: Call must come from admin.');

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        queuedTransactions[txHash] = false;

        emit CancelTransaction(txHash, target, value, signature, data, eta);
    }

    function executeTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) public returns (bytes memory) {
        require(msg.sender == admin, 'NounsDAOExecutor::executeTransaction: Call must come from admin.');

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        require(queuedTransactions[txHash], "NounsDAOExecutor::executeTransaction: Transaction hasn't been queued.");
        require(
            getBlockTimestamp() >= eta,
            "NounsDAOExecutor::executeTransaction: Transaction hasn't surpassed time lock."
        );
        require(
            getBlockTimestamp() <= eta + GRACE_PERIOD,
            'NounsDAOExecutor::executeTransaction: Transaction is stale.'
        );

        queuedTransactions[txHash] = false;

        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        // solium-disable-next-line security/no-call-value
        (bool success, bytes memory returnData) = target.call{ value: value }(callData);
        require(success, 'NounsDAOExecutor::executeTransaction: Transaction execution reverted.');

        emit ExecuteTransaction(txHash, target, value, signature, data, eta);

        return returnData;
    }

    function getBlockTimestamp() internal view returns (uint256) {
        // solium-disable-next-line security/no-block-members
        return block.timestamp;
    }

    function totalTreasury() public view returns (uint256) {
        return address(this).balance;
    }

    // MODIFICATION : JBSingleTokenPaymentTerminalStore.sol from Juicebox
    function _calculateRedemption(
        uint256 _redemptionRate,
        uint256 _totalSupply,
        uint256 _nonAllocatedTreasury
    ) private view returns (uint256) {
        // If the redemption rate is 0, nothing is claimable.
        if (_redemptionRate == 0) return 0;

        // Get a reference to the linear proportion.
        uint256 _base = PRBMath.mulDiv(_nonAllocatedTreasury, 1, _totalSupply);

        // These conditions are all part of the same curve. Edge conditions are separated because fewer operation are necessary.
        if (_redemptionRate == MAX_REDEMPTION_RATE) return _base;

        return
            PRBMath.mulDiv(
                _base,
                _redemptionRate + PRBMath.mulDiv(1, MAX_REDEMPTION_RATE - _redemptionRate, _totalSupply),
                MAX_REDEMPTION_RATE // 10000
            );
    }

    function calculateRedemption() public view returns (uint256) {
        uint256 nonAllocatedTreasury = totalTreasury() - allocatedTreasury();
        uint256 totalSupply = NounsTokenLike(nouns).totalSupply();

        return _calculateRedemption(redemptionRate, totalSupply, nonAllocatedTreasury);
    }

    function redeemForETH(uint256 tokenId) external {
        require(NounsTokenLike(nouns).ownerOf(tokenId) == msg.sender, 'Should be owner');
        uint256 redemptionValue = calculateRedemption();
        address redemptionAddress = msg.sender;

        (bool successBurn, ) = nouns.delegatecall(abi.encodeWithSignature('burn(uint256 tokenId) ', tokenId));
        require(successBurn, 'Unable to burn nouns');

        (bool successRedeem, ) = redemptionAddress.call{ value: redemptionValue }('');
        require(successRedeem, 'Unable to transfer ETH');
    }

    function setRedemptionRate(uint256 _redemptionRate) external {
        require(msg.sender == admin, 'NounsDAOExecutor::executeTransaction: Call must come from admin.');

        redemptionRate = _redemptionRate;
    }

    function allocatedTreasury() internal view returns (uint256) {
        uint256 _proposalCount = INounsDAOLogicV1(DAOLogicV1).proposalCount();
        uint256 allocated = 0;

        address[] memory targets;
        uint256[] memory values;
        string[] memory signatures;
        bytes[] memory calldatas;

        for (uint256 i = 0; i < _proposalCount; i++) {
            uint256 state = uint256(INounsDAOLogicV1(DAOLogicV1).state(i));
            if (state == 0 || state == 1 || state == 5) {
                (targets, values, signatures, calldatas) = INounsDAOLogicV1(DAOLogicV1).getActions(i);
                for (uint256 x = 0; x < values.length - 1; x++) {
                    allocated = allocated + values[x];
                }
            }
        }

        return allocated;
    }

    receive() external payable {}

    fallback() external payable {}
}
