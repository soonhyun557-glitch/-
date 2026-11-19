// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title FestivalOutcomeOracle (classroom mock)
 * @notice A simple authorized off-chain -> on-chain message relay.
 * @dev The reporter attests to mock off-chain data; this DOES NOT independently
 *      establish that a real festival was held. Not a Chainlink or decentralized oracle.
 */
interface IEventOutcomeConsumer {
    function onOracleOutcome(uint256 eventId, uint8 outcome, bytes32 evidenceHash) external;
}

contract FestivalOutcomeOracle {
    address public immutable reporter;

    struct Report {
        uint8 outcome;            // 1 = Held, 2 = Cancelled
        bytes32 evidenceHash;
        uint64 reportedAt;
    }
    mapping(address => mapping(uint256 => Report)) private _reports;

    event OracleReportSubmitted(
        address indexed escrow,
        uint256 indexed eventId,
        address indexed reporter,
        uint8 outcome,
        bytes32 evidenceHash
    );

    constructor(address reporter_) {
        require(reporter_ != address(0), "Invalid reporter");
        reporter = reporter_;
    }

    function getReport(address escrow, uint256 eventId) external view returns (Report memory) {
        return _reports[escrow][eventId];
    }

    function submitOutcome(address escrow, uint256 eventId, uint8 outcome, bytes32 evidenceHash) external {
        require(msg.sender == reporter, "Oracle reporter only");
        require(escrow.code.length > 0, "Invalid escrow");
        require(outcome == 1 || outcome == 2, "Invalid outcome");
        require(evidenceHash != bytes32(0), "Missing evidence hash");
        require(_reports[escrow][eventId].reportedAt == 0, "Already reported");

        _reports[escrow][eventId] = Report(outcome, evidenceHash, uint64(block.timestamp));
        // On-chain callback. If the escrow rejects the report, this whole tx reverts.
        IEventOutcomeConsumer(escrow).onOracleOutcome(eventId, outcome, evidenceHash);
        emit OracleReportSubmitted(escrow, eventId, msg.sender, outcome, evidenceHash);
    }
}
