// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title EventEscrowOracle
 * @notice Educational ERC-20 escrow: auto-refund on mock-oracle CANCELLED.
 * @dev Push refunds are bounded to 20 wallets per event. Mock demo only.
 *      No independent verification of real-world festival facts,
 *      no dispute resolution, no external security audit. Do NOT use real funds.
 */
interface IERCTokenMinimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract EventEscrowOracle {
    enum Status { Registration, AwaitingOutcome, Failed, Held, Cancelled }

    struct EventInfo {
        address organizer;
        string title;
        uint256 fee;
        uint32 minimum;
        uint64 registrationDeadline;
        uint64 eventTime;
        uint32 activeCount;
        uint256 heldBalance;
        uint256 cancellationFeesHeld;
        Status status;
        bool withdrawn;
        uint32 daySeconds;
        uint64 oracleReportedAt;
        bytes32 oracleEvidenceHash;
    }

    struct Participant {
        bool joined;
        bool cancelled;
        bool refundClaimed;
        uint256 heldFee;
    }

    address public immutable paymentToken;
    address public immutable oracleFeed;
    uint256 public eventCount;
    uint32 public constant MAX_AUTO_REFUND_PARTICIPANTS = 20;
    mapping(uint256 => address[]) private _participantWallets;
    uint256 private _reentrancyLock = 1;
    mapping(uint256 => EventInfo) private _events;
    mapping(uint256 => mapping(address => Participant)) private _participants;

    event EventCreated(uint256 indexed eventId, address indexed organizer);
    event Joined(uint256 indexed eventId, address indexed participant, uint256 amount);
    event ParticipationCancelled(uint256 indexed eventId, address indexed participant, uint256 immediateRefund, uint256 heldFee);
    event RegistrationFinalized(uint256 indexed eventId, Status status, uint32 activeCount);
    event OracleOutcomeAccepted(uint256 indexed eventId, Status status, bytes32 evidenceHash);
    event RefundClaimed(uint256 indexed eventId, address indexed participant, uint256 amount);
    event AutoRefundPaid(uint256 indexed eventId, address indexed participant, uint256 amount);
    event FundsWithdrawn(uint256 indexed eventId, address indexed organizer, uint256 amount);

    modifier nonReentrant() {
        require(_reentrancyLock == 1, "Reentrancy blocked");
        _reentrancyLock = 2;
        _;
        _reentrancyLock = 1;
    }

    constructor(address token_, address oracleFeed_) {
        require(token_ != address(0) && token_.code.length > 0, "Invalid ERC20 token");
        require(oracleFeed_ != address(0) && oracleFeed_.code.length > 0, "Invalid oracle feed");
        paymentToken = token_;
        oracleFeed = oracleFeed_;
    }

    function createEvent(
        string calldata title,
        uint256 fee,
        uint32 minimum,
        uint64 registrationDeadline,
        uint64 eventTime,
        bool demoMode
    ) external returns (uint256 eventId) {
        require(bytes(title).length > 0 && bytes(title).length <= 100, "Invalid title");
        require(fee > 0 && minimum > 0, "Invalid fee/minimum");
        require(registrationDeadline > block.timestamp, "Deadline must be future");
        require(eventTime > registrationDeadline, "Event must follow deadline");
        eventId = ++eventCount;
        EventInfo storage e = _events[eventId];
        e.organizer = msg.sender;
        e.title = title;
        e.fee = fee;
        e.minimum = minimum;
        e.registrationDeadline = registrationDeadline;
        e.eventTime = eventTime;
        e.daySeconds = demoMode ? 20 : 86400;
        e.status = Status.Registration;
        emit EventCreated(eventId, msg.sender);
    }

    function getEvent(uint256 eventId) external view returns (EventInfo memory) {
        _requireEvent(eventId);
        return _events[eventId];
    }

    function automaticRefunds() external pure returns (bool) { return true; }

    function getParticipantWallets(uint256 eventId) external view returns (address[] memory) {
        _requireEvent(eventId);
        return _participantWallets[eventId];
    }

    function getParticipant(uint256 eventId, address participant) external view returns (Participant memory) {
        _requireEvent(eventId);
        return _participants[eventId][participant];
    }

    function joinEvent(uint256 eventId) external nonReentrant {
        EventInfo storage e = _getEvent(eventId);
        require(e.status == Status.Registration, "Registration not open");
        require(block.timestamp < e.registrationDeadline, "Registration closed");
        Participant storage p = _participants[eventId][msg.sender];
        require(!p.joined, "Wallet already registered");
        require(_participantWallets[eventId].length < MAX_AUTO_REFUND_PARTICIPANTS, "Demo max 20 wallets");
        _participantWallets[eventId].push(msg.sender);
        p.joined = true;
        e.activeCount += 1;
        e.heldBalance += e.fee;
        _safeTransferFrom(msg.sender, address(this), e.fee);
        emit Joined(eventId, msg.sender, e.fee);
    }

    function cancelParticipation(uint256 eventId) external nonReentrant {
        EventInfo storage e = _getEvent(eventId);
        require(e.status == Status.Registration || e.status == Status.AwaitingOutcome, "Cancellation unavailable");
        require(block.timestamp < e.eventTime, "Event time passed");
        Participant storage p = _participants[eventId][msg.sender];
        require(p.joined && !p.cancelled, "No active registration");
        uint256 remaining = uint256(e.eventTime) - block.timestamp;
        uint256 feeBps = remaining >= uint256(e.daySeconds) * 7
            ? 0 : remaining >= uint256(e.daySeconds) * 3 ? 3000 : 5000;
        uint256 withheld = e.fee * feeBps / 10000;
        uint256 immediateRefund = e.fee - withheld;
        p.cancelled = true;
        p.heldFee = withheld;
        e.activeCount -= 1;
        e.heldBalance -= immediateRefund;
        e.cancellationFeesHeld += withheld;

        if (block.timestamp >= e.registrationDeadline && e.activeCount < e.minimum) {
            e.status = Status.Failed;
            emit RegistrationFinalized(eventId, Status.Failed, e.activeCount);
        } else if (block.timestamp >= e.registrationDeadline && e.status == Status.Registration) {
            e.status = Status.AwaitingOutcome;
            emit RegistrationFinalized(eventId, Status.AwaitingOutcome, e.activeCount);
        }
        _safeTransfer(msg.sender, immediateRefund);
        emit ParticipationCancelled(eventId, msg.sender, immediateRefund, withheld);
    }

    function finalizeRegistration(uint256 eventId) external {
        EventInfo storage e = _getEvent(eventId);
        require(e.status == Status.Registration, "Already finalized");
        require(block.timestamp >= e.registrationDeadline, "Deadline not reached");
        e.status = e.activeCount >= e.minimum ? Status.AwaitingOutcome : Status.Failed;
        emit RegistrationFinalized(eventId, e.status, e.activeCount);
    }

    /**
     * @notice Invoked ONLY by the trusted FestivalOutcomeOracle contract.
     *         The authorized oracle reporter supplies MOCK off-chain evidence.
     */
    function onOracleOutcome(uint256 eventId, uint8 outcome, bytes32 evidenceHash) external nonReentrant {
        require(msg.sender == oracleFeed, "Only configured oracle feed");
        require(evidenceHash != bytes32(0), "Missing evidence hash");
        EventInfo storage e = _getEvent(eventId);
        require(e.oracleReportedAt == 0, "Already reported");
        require(e.status == Status.Registration || e.status == Status.AwaitingOutcome, "Outcome closed");
        if (outcome == 1) {
            require(e.status == Status.AwaitingOutcome, "Finalize registration first");
            require(block.timestamp >= e.eventTime, "Event time not reached");
            require(e.activeCount >= e.minimum, "Below minimum");
            e.status = Status.Held;
        } else if (outcome == 2) {
            e.status = Status.Cancelled;
        } else {
            revert("Invalid outcome");
        }
        e.oracleEvidenceHash = evidenceHash;
        e.oracleReportedAt = uint64(block.timestamp);
        if (outcome == 2) {
            _refundAllOnCancellation(eventId, e);
        }
        emit OracleOutcomeAccepted(eventId, e.status, evidenceHash);
    }

    /**
     * @notice Demo-only bounded push refunds. All participants are paid in the
     *         SAME oracle-report transaction. No claimRefund click required.
     *         If a transfer fails, the entire report and refunds revert.
     * @dev No more than 20 wallets may join each event: not suitable for
     *      arbitrary real festivals or fee-on-transfer ERC-20 tokens.
     */
    function _refundAllOnCancellation(uint256 eventId, EventInfo storage e) internal {
        address[] storage wallets = _participantWallets[eventId];
        uint256[] memory amounts = new uint256[](wallets.length);
        uint256 totalRefunded;
        for (uint256 i = 0; i < wallets.length; ++i) {
            Participant storage p = _participants[eventId][wallets[i]];
            if (!p.joined || p.refundClaimed) continue;
            uint256 amount = p.cancelled ? p.heldFee : e.fee;
            amounts[i] = amount;
            p.refundClaimed = true;
            p.heldFee = 0;
            totalRefunded += amount;
        }
        require(totalRefunded == e.heldBalance, "Refund accounting mismatch");
        // Effects before interactions. nonReentrant protects this callback.
        e.heldBalance = 0;
        e.cancellationFeesHeld = 0;
        for (uint256 i = 0; i < wallets.length; ++i) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            _safeTransfer(wallets[i], amount);
            emit AutoRefundPaid(eventId, wallets[i], amount);
            emit RefundClaimed(eventId, wallets[i], amount);
        }
    }

    function claimRefund(uint256 eventId) external nonReentrant {
        EventInfo storage e = _getEvent(eventId);
        require(e.status == Status.Failed, "Use auto refund on oracle cancellation");
        Participant storage p = _participants[eventId][msg.sender];
        require(p.joined && !p.refundClaimed, "Nothing to claim");
        uint256 amount = p.cancelled ? p.heldFee : e.fee;
        require(amount > 0, "No remaining refund");
        p.refundClaimed = true;
        e.heldBalance -= amount;
        if (p.cancelled) {
            e.cancellationFeesHeld -= amount;
            p.heldFee = 0;
        }
        _safeTransfer(msg.sender, amount);
        emit RefundClaimed(eventId, msg.sender, amount);
    }

    /** @notice After the Oracle confirms HELD, settle all remaining funds in one transaction.
     *  Includes active participants' full fees AND previously withheld cancellation fees.
     *  Example: 20 deposited, 7 immediate refund -> organizer receives 13.
     *  The payment is a separate organizer-initiated transaction, not automatic on Oracle report.
     */
    function withdrawFunds(uint256 eventId) external nonReentrant {
        EventInfo storage e = _getEvent(eventId);
        require(msg.sender == e.organizer, "Organizer only");
        require(e.status == Status.Held && !e.withdrawn, "Withdrawal unavailable");
        uint256 amount = e.heldBalance;
        require(amount > 0, "No remaining funds");
        e.withdrawn = true;
        e.heldBalance = 0;
        e.cancellationFeesHeld = 0;
        _safeTransfer(e.organizer, amount);
        emit FundsWithdrawn(eventId, msg.sender, amount);
    }

    function _requireEvent(uint256 eventId) internal view {
        require(eventId > 0 && eventId <= eventCount, "Unknown event");
    }
    function _getEvent(uint256 eventId) internal view returns (EventInfo storage e) {
        _requireEvent(eventId);
        e = _events[eventId];
    }
    function _safeTransfer(address to, uint256 amount) internal {
        (bool ok, bytes memory result) = paymentToken.call(
            abi.encodeWithSelector(IERCTokenMinimal.transfer.selector, to, amount)
        );
        require(ok && (result.length == 0 || abi.decode(result, (bool))), "ERC20 transfer failed");
    }
    function _safeTransferFrom(address from, address to, uint256 amount) internal {
        (bool ok, bytes memory result) = paymentToken.call(
            abi.encodeWithSelector(IERCTokenMinimal.transferFrom.selector, from, to, amount)
        );
        require(ok && (result.length == 0 || abi.decode(result, (bool))), "ERC20 transferFrom failed");
    }
}
