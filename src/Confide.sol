// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./ReputationRegistry.sol";
import "./IZkVerifier.sol";

/**
 * @title ConfideFi - Privacy-Preserving DeFi Lending Platform
 * @dev Smart contract for managing loans with ZK-proof verified creditworthiness
 */
contract ConfideFi {
    // ZK Verifier interface
    IZkVerifier public zkVerifier;
    
    // Reputation registry contract
    ReputationRegistry public reputationRegistry;

    // Loan status enum
    enum LoanStatus {
        Pending,
        Approved,
        Active,
        Repaid,
        Defaulted,
        Rejected
    }

    // Loan data structure
    struct Loan {
        uint256 loanId;
        address borrower;
        address lender;
        uint256 amount;
        uint256 interestRate; // in basis points (1% = 100)
        uint256 duration; // in seconds
        uint256 startTime;
        uint256 endTime;
        uint256 collateralAmount;
        LoanStatus status;
        uint256 reputationScoreSnapshot; // ZK-verified score at loan creation
        uint256 amountRepaid;
        uint256 nextPaymentDue;
        uint256 paymentInterval; // in seconds
    }

    // Lender's loan offer structure
    struct LoanOffer {
        address lender;
        uint256 amount;
        uint256 interestRate;
        uint256 duration;
        uint256 requiredCollateralRatio; // in basis points (e.g., 15000 = 150%)
        uint256 minimumReputationScore;
        bool active;
    }

    // ZK Proof verification result structure
    struct VerificationResult {
        bool isValid;
        uint256 reputationScore;
        bool isProcessed;
    }

    // Mapping of loan IDs to Loan data
    mapping(uint256 => Loan) public loans;
    
    // Mapping of offer IDs to Loan offers
    mapping(uint256 => LoanOffer) public loanOffers;
    
    // Mapping of ZK proof hashes to verification results
    mapping(bytes32 => VerificationResult) public verificationResults;
    
    // Mapping of borrower addresses to their active loan IDs
    mapping(address => uint256[]) public borrowerLoans;
    
    // Mapping of lender addresses to their active loan IDs
    mapping(address => uint256[]) public lenderLoans;
    
    // Mapping of lender addresses to their loan offer IDs
    mapping(address => uint256[]) public lenderOffers;
    
    // Loan counter for generating unique IDs
    uint256 private loanIdCounter;
    
    // Loan offer counter for generating unique IDs
    uint256 private offerIdCounter;
    
    // Contract owner
    address public owner;
    
    // Events
    event LoanOfferCreated(uint256 indexed offerId, address indexed lender, uint256 amount, uint256 interestRate);
    event ZkProofReceived(bytes32 indexed proofHash, address indexed borrower);
    event ZkProofVerified(bytes32 indexed proofHash, bool isValid, uint256 reputationScore);
    event LoanRequested(address indexed borrower, uint256 indexed offerId, bytes32 proofHash);
    event LoanApproved(uint256 indexed loanId, address indexed lender, address indexed borrower);
    event LoanRejected(address indexed borrower, uint256 indexed offerId, string reason);
    event LoanFunded(uint256 indexed loanId, uint256 amount);
    event PaymentMade(uint256 indexed loanId, uint256 amount, uint256 remaining);
    event LoanRepaid(uint256 indexed loanId);
    event LoanDefaulted(uint256 indexed loanId);
    event CollateralLiquidated(uint256 indexed loanId, uint256 collateralAmount);
    event ReputationUpdated(address indexed borrower, uint256 newScore);
    
    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }
    
    modifier onlyBorrower(uint256 _loanId) {
        require(msg.sender == loans[_loanId].borrower, "Only borrower can call this function");
        _;
    }
    
    modifier onlyLender(uint256 _loanId) {
        require(msg.sender == loans[_loanId].lender, "Only lender can call this function");
        _;
    }
    
    /**
     * @dev Contract constructor
     * @param _zkVerifier Address of the ZK proof verifier contract
     * @param _reputationRegistry Address of the reputation registry contract
     */
    constructor(
        address _zkVerifier,
        address _reputationRegistry
    ) {
        owner = msg.sender;
        zkVerifier = IZkVerifier(_zkVerifier);
        reputationRegistry = ReputationRegistry(_reputationRegistry);
        
        loanIdCounter = 1;
        offerIdCounter = 1;
    }
    
    /**
     * @dev Allows a lender to create a loan offer
     * @param _amount Amount of tokens to lend
     * @param _interestRate Interest rate in basis points
     * @param _duration Duration of the loan in seconds
     * @param _requiredCollateralRatio Required collateral ratio in basis points
     * @param _minimumReputationScore Minimum reputation score required
     */
    function createLoanOffer(
        uint256 _amount,
        uint256 _interestRate,
        uint256 _duration,
        uint256 _requiredCollateralRatio,
        uint256 _minimumReputationScore
    ) external {
        require(_amount > 0, "Loan amount must be greater than 0");
        require(_duration > 0, "Loan duration must be greater than 0");
        
        uint256 offerId = offerIdCounter++;
        
        loanOffers[offerId] = LoanOffer({
            lender: msg.sender,
            amount: _amount,
            interestRate: _interestRate,
            duration: _duration,
            requiredCollateralRatio: _requiredCollateralRatio,
            minimumReputationScore: _minimumReputationScore,
            active: true
        });
        
        lenderOffers[msg.sender].push(offerId);
        
        emit LoanOfferCreated(offerId, msg.sender, _amount, _interestRate);
    }
    
    /**
     * @dev Receives and stores ZK proof verification result
     * @param _proofHash Hash of the ZK proof
     * @param _borrower Address of the borrower
     * @param _isValid Whether the proof is valid
     * @param _reputationScore Reputation score extracted from the proof
     * @notice This function would be called by a trusted oracle or TEE after off-chain verification
     */
    function receiveZkProofResult(
        bytes32 _proofHash,
        address _borrower,
        bool _isValid,
        uint256 _reputationScore
    ) external onlyOwner {
        verificationResults[_proofHash] = VerificationResult({
            isValid: _isValid,
            reputationScore: _reputationScore,
            isProcessed: false
        });
        
        emit ZkProofVerified(_proofHash, _isValid, _reputationScore);
        
        if (_isValid) {
            // Update the borrower's reputation score
            reputationRegistry.updateScore(_borrower, _reputationScore);
            emit ReputationUpdated(_borrower, _reputationScore);
        }
    }
    
    /**
     * @dev Allows a borrower to request a loan using a ZK proof
     * @param _offerId ID of the loan offer
     * @param _proofHash Hash of the ZK proof that was processed off-chain
     */
    function requestLoan(
        uint256 _offerId,
        bytes32 _proofHash
    ) external payable {
        LoanOffer storage offer = loanOffers[_offerId];
        
        require(offer.active, "Loan offer is not active");
        require(verificationResults[_proofHash].isValid, "Invalid or unverified ZK proof");
        require(!verificationResults[_proofHash].isProcessed, "ZK proof already used");
        
        uint256 requiredCollateral = (offer.amount * offer.requiredCollateralRatio) / 10000;
        require(msg.value >= requiredCollateral, "Insufficient collateral");
        
        uint256 reputationScore = verificationResults[_proofHash].reputationScore;
        require(reputationScore >= offer.minimumReputationScore, "Reputation score too low");
        
        emit LoanRequested(msg.sender, _offerId, _proofHash);
        
        // Mark the proof as processed
        verificationResults[_proofHash].isProcessed = true;
        
        // Create a new loan
        uint256 loanId = loanIdCounter++;
        
        Loan storage loan = loans[loanId];
        loan.loanId = loanId;
        loan.borrower = msg.sender;
        loan.lender = offer.lender;
        loan.amount = offer.amount;
        loan.interestRate = offer.interestRate;
        loan.duration = offer.duration;
        loan.startTime = block.timestamp;
        loan.endTime = block.timestamp + offer.duration;
        loan.collateralAmount = msg.value;
        loan.status = LoanStatus.Approved;
        loan.reputationScoreSnapshot = reputationScore;
        
        // Set up repayment schedule
        loan.paymentInterval = offer.duration / 4; // Example: 4 payments
        loan.nextPaymentDue = block.timestamp + loan.paymentInterval;
        
        // Add loan to borrower's and lender's lists
        borrowerLoans[msg.sender].push(loanId);
        lenderLoans[offer.lender].push(loanId);
        
        emit LoanApproved(loanId, offer.lender, msg.sender);
        
        // Transfer the loan amount from the lender to the borrower
        // In a real implementation, you would need to handle token transfers
        // For simplicity, we'll assume the lender has pre-authorized the contract
        
        // Update loan status
        loan.status = LoanStatus.Active;
        
        emit LoanFunded(loanId, offer.amount);
        
        // Deactivate the offer if fully utilized
        offer.active = false;
    }
    
    /**
     * @dev Allows a borrower to make a loan payment
     * @param _loanId ID of the loan
     */
    function makePayment(uint256 _loanId) external payable onlyBorrower(_loanId) {
        Loan storage loan = loans[_loanId];
        
        require(loan.status == LoanStatus.Active, "Loan is not active");
        require(msg.value > 0, "Payment amount must be greater than 0");
        
        // Calculate remaining amount
        uint256 totalDue = loan.amount + (loan.amount * loan.interestRate / 10000);
        uint256 remaining = totalDue - loan.amountRepaid;
        
        // Update repayment amount
        if (msg.value >= remaining) {
            // Loan fully repaid
            loan.amountRepaid = totalDue;
            loan.status = LoanStatus.Repaid;
            
            // Return any excess payment
            if (msg.value > remaining) {
                (bool sent, ) = msg.sender.call{value: msg.value - remaining}("");
                require(sent, "Failed to return excess payment");
            }
            
            // Transfer the repayment to the lender
            (bool lenderSent, ) = loan.lender.call{value: remaining}("");
            require(lenderSent, "Failed to send repayment to lender");
            
            // Return collateral to borrower
            if (loan.collateralAmount > 0) {
                (bool collateralSent, ) = loan.borrower.call{value: loan.collateralAmount}("");
                require(collateralSent, "Failed to return collateral to borrower");
            }
            
            // Increase borrower's reputation score
            uint256 currentScore = reputationRegistry.getScore(loan.borrower);
            uint256 newScore = currentScore + 50; // Example: +50 points for successful repayment
            reputationRegistry.updateScore(loan.borrower, newScore);
            
            emit LoanRepaid(_loanId);
            emit ReputationUpdated(loan.borrower, newScore);
        } else {
            // Partial payment
            loan.amountRepaid += msg.value;
            
            // Update next payment due date if this payment was on time
            if (block.timestamp <= loan.nextPaymentDue) {
                loan.nextPaymentDue = block.timestamp + loan.paymentInterval;
            }
            
            // Transfer the payment to the lender
            (bool sent, ) = loan.lender.call{value: msg.value}("");
            require(sent, "Failed to send payment to lender");
            
            emit PaymentMade(_loanId, msg.value, remaining - msg.value);
        }
    }
    
    /**
     * @dev Allows anyone to check for defaulted loans and trigger liquidation
     * @param _loanId ID of the loan to check
     */
    function checkLoanDefault(uint256 _loanId) external {
        Loan storage loan = loans[_loanId];
        
        require(loan.status == LoanStatus.Active, "Loan is not active");
        
        // Check if payment is overdue (e.g., more than 7 days late)
        if (block.timestamp > loan.nextPaymentDue + 7 days) {
            // Mark loan as defaulted
            loan.status = LoanStatus.Defaulted;
            
            // Liquidate collateral and send to lender
            if (loan.collateralAmount > 0) {
                (bool sent, ) = loan.lender.call{value: loan.collateralAmount}("");
                require(sent, "Failed to liquidate collateral");
            }
            
            // Decrease borrower's reputation score
            uint256 currentScore = reputationRegistry.getScore(loan.borrower);
            uint256 newScore = currentScore > 100 ? currentScore - 100 : 0; // Example: -100 points for default
            reputationRegistry.updateScore(loan.borrower, newScore);
            
            emit LoanDefaulted(_loanId);
            emit CollateralLiquidated(_loanId, loan.collateralAmount);
            emit ReputationUpdated(loan.borrower, newScore);
        }
    }
    
    /**
     * @dev Submit a ZK proof hash for verification
     * @param _proofHash Hash of the ZK proof
     * @notice This function would initiate the verification process
     * which would be completed off-chain in a TEE
     */
    function submitZkProof(bytes32 _proofHash) external {
        // In a real implementation, this would trigger an off-chain verification process
        // For simplicity, we just emit an event that the off-chain verifier would listen for
        emit ZkProofReceived(_proofHash, msg.sender);
    }
    
    /**
     * @dev Get all active loans for a borrower
     * @param _borrower Address of the borrower
     * @return Array of loan IDs
     */
    function getBorrowerLoans(address _borrower) external view returns (uint256[] memory) {
        return borrowerLoans[_borrower];
    }
    
    /**
     * @dev Get all active loans for a lender
     * @param _lender Address of the lender
     * @return Array of loan IDs
     */
    function getLenderLoans(address _lender) external view returns (uint256[] memory) {
        return lenderLoans[_lender];
    }
    
    /**
     * @dev Get all active loan offers from a lender
     * @param _lender Address of the lender
     * @return Array of offer IDs
     */
    function getLenderOffers(address _lender) external view returns (uint256[] memory) {
        return lenderOffers[_lender];
    }
    
    /**
     * @dev Get detailed information about a loan
     * @param _loanId ID of the loan
     * @return Full loan data
     */
    function getLoanDetails(uint256 _loanId) external view returns (Loan memory) {
        return loans[_loanId];
    }
    
    /**
     * @dev Get detailed information about a loan offer
     * @param _offerId ID of the loan offer
     * @return Full loan offer data
     */
    function getLoanOfferDetails(uint256 _offerId) external view returns (LoanOffer memory) {
        return loanOffers[_offerId];
    }
    
    /**
     * @dev Get a borrower's current reputation score
     * @param _borrower Address of the borrower
     * @return Reputation score
     */
    function getBorrowerScore(address _borrower) external view returns (uint256) {
        return reputationRegistry.getScore(_borrower);
    }
}