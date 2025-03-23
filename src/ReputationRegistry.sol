// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title ReputationRegistry
 * @dev Contract for storing and managing borrower reputation scores
 */
contract ReputationRegistry {
    // Owner of the contract
    address public owner;
    
    // Mapping of borrower addresses to their reputation scores
    mapping(address => uint256) private reputationScores;
    
    // Authorized contracts that can update scores
    mapping(address => bool) public authorizedContracts;
    
    // Events
    event ScoreUpdated(address indexed borrower, uint256 newScore);
    event ContractAuthorized(address indexed contractAddress);
    event ContractDeauthorized(address indexed contractAddress);
    
    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }
    
    modifier onlyAuthorized() {
        require(authorizedContracts[msg.sender] || msg.sender == owner, "Not authorized");
        _;
    }
    
    /**
     * @dev Contract constructor
     */
    constructor() {
        owner = msg.sender;
    }
    
    /**
     * @dev Authorizes a contract to update reputation scores
     * @param _contract Address of the contract to authorize
     */
    function authorizeContract(address _contract) external onlyOwner {
        authorizedContracts[_contract] = true;
        emit ContractAuthorized(_contract);
    }
    
    /**
     * @dev Deauthorizes a contract from updating reputation scores
     * @param _contract Address of the contract to deauthorize
     */
    function deauthorizeContract(address _contract) external onlyOwner {
        authorizedContracts[_contract] = false;
        emit ContractDeauthorized(_contract);
    }
    
    /**
     * @dev Updates a borrower's reputation score
     * @param _borrower Address of the borrower
     * @param _score New reputation score
     */
    function updateScore(address _borrower, uint256 _score) external onlyAuthorized {
        reputationScores[_borrower] = _score;
        emit ScoreUpdated(_borrower, _score);
    }
    
    /**
     * @dev Gets a borrower's reputation score
     * @param _borrower Address of the borrower
     * @return The borrower's reputation score
     */
    function getScore(address _borrower) external view returns (uint256) {
        return reputationScores[_borrower];
    }
    
    /**
     * @dev Initializes a borrower's reputation score if not set
     * @param _borrower Address of the borrower
     * @param _initialScore Initial reputation score
     */
    function initializeScore(address _borrower, uint256 _initialScore) external onlyAuthorized {
        if (reputationScores[_borrower] == 0) {
            reputationScores[_borrower] = _initialScore;
            emit ScoreUpdated(_borrower, _initialScore);
        }
    }
}