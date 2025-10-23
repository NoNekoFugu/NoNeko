// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title NekoSafe v1.1
 * @notice Minimal DAO treasury for symbolic donations.
 *         Zen rules: reflect balances (no internal ledger), verify targets, keep voting simple.
 *
 * Philosophy:
 *  - One address = one vote. Or many wallets, one will.
 *  - Trust through transparency, not complexity.
 */

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract NekoSafe is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ─────────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────────

    EnumerableSet.AddressSet private verifiedCharities;

    struct Proposal {
        uint256 id;
        address token;        // bound token (immutable per proposal)
        address target;       // must be verified charity at execution
        uint256 amount;       // amount in ERC20 "token" decimals
        string  description;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 createdAt;    // timestamp for observability; voting is open until execution
        bool    executed;
    }

    uint256 public proposalCounter;
    mapping(uint256 => Proposal) private _proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────

    event CharityVerified(address indexed charity, bool allowed);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    event ProposalCreated(
        uint256 indexed id,
        address indexed token,
        address indexed target,
        uint256 amount,
        string description
    );

    event Voted(uint256 indexed id, address indexed voter, bool support);
    event Executed(
        uint256 indexed id,
        address indexed token,
        address indexed target,
        uint256 amount,
        uint256 yesVotes,
        uint256 noVotes
    );

    event Donated(address indexed from, address indexed token, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────────────
    // Donations (ERC20 only; balances are reflected from on-chain state)
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Donate ERC20 tokens into the treasury.
     * @dev No internal ledger: the source of truth is IERC20(token).balanceOf(address(this)).
     */
    function donate(address token, uint256 amount) external nonReentrant whenNotPaused {
        require(token != address(0), "Invalid token");
        require(amount > 0, "Amount=0");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Donated(msg.sender, token, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Governance (minimalistic by design)
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Create a proposal bound to a specific token and verified target.
     * @dev Owner-only by design (deterministic responsibility).
     */
    function createProposal(
        address token,
        address target,
        uint256 amount,
        string calldata description
    ) external onlyOwner whenNotPaused returns (uint256 id) {
        require(token != address(0), "Invalid token");
        require(target != address(0), "Invalid target");
        require(amount > 0, "Amount=0");

        id = ++proposalCounter;
        Proposal storage p = _proposals[id];
        p.id = id;
        p.token = token;
        p.target = target;
        p.amount = amount;
        p.description = description;
        p.createdAt = block.timestamp;

        emit ProposalCreated(id, token, target, amount, description);
    }

    /**
     * @notice One address = one vote; open until execution.
     */
    function vote(uint256 id, bool support) external whenNotPaused {
        Proposal storage p = _proposals[id];
        require(p.id != 0, "No such proposal");
        require(!p.executed, "Executed");
        require(!hasVoted[id][msg.sender], "Already voted");

        hasVoted[id][msg.sender] = true;
        if (support) p.yesVotes += 1;
        else p.noVotes += 1;

        emit Voted(id, msg.sender, support);
    }

    /**
     * @notice Execute approved proposal. Requires verified target and sufficient on-chain balance.
     * @dev Uses on-chain balance as the single source of truth; no internal ledger subtraction.
     */
    function executeProposal(uint256 id) external nonReentrant onlyOwner whenNotPaused {
        Proposal storage p = _proposals[id];
        require(p.id != 0, "No such proposal");
        require(!p.executed, "Already executed");
        require(p.yesVotes > p.noVotes, "Not approved");
        require(isVerifiedCharity(p.target), "Target not verified charity");

        IERC20 token = IERC20(p.token);
        uint256 bal = token.balanceOf(address(this));
        require(bal >= p.amount, "Insufficient funds");

        p.executed = true;
        token.safeTransfer(p.target, p.amount);

        emit Executed(id, p.token, p.target, p.amount, p.yesVotes, p.noVotes);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Admin: verify charities & pause
    // ─────────────────────────────────────────────────────────────────────────────

    function verifyCharity(address charity, bool allowed) external onlyOwner {
        require(charity != address(0), "Zero address");
        if (allowed) {
            verifiedCharities.add(charity);
        } else {
            verifiedCharities.remove(charity);
        }
        emit CharityVerified(charity, allowed);
    }

    function isVerifiedCharity(address charity) public view returns (bool) {
        return verifiedCharities.contains(charity);
    }

    function getAllCharities() external view returns (address[] memory) {
        return verifiedCharities.values();
    }

    function pause() external onlyOwner {
        _pause();
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        _unpause();
        emit Unpaused(msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────────

    function getProposal(uint256 id) external view returns (Proposal memory) {
        return _proposals[id];
    }

    function treasuryBalance(address token) external view returns (uint256) {
        if (token == address(0)) return 0;
        return IERC20(token).balanceOf(address(this));
    }
}
