// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../lib/forge-std/src/Test.sol";
import "../src/Trifecta.sol";
import "../src/IZkVerifier.sol";
import "../src/ReputationRegistry.sol";

contract MockZkVerifier is IZkVerifier {
    bool private shouldVerify;
    mapping(address => bool) public authorized;
    uint256 private mockScore;
    
    constructor() {
        shouldVerify = false;
        mockScore = 800; // Default mock score
    }
    
    function setShouldVerify(bool _shouldVerify) external {
        shouldVerify = _shouldVerify;
    }
    
    function setMockScore(uint256 _score) external {
        mockScore = _score;
    }
    
    function authorize(address user) external {
        authorized[user] = true;
    }
    
    function verify(bytes memory) external view override returns (bool) {
        require(authorized[msg.sender], "Not authorized");
        return shouldVerify;
    }

    function extractScore(bytes memory) external view override returns (uint256) {
        require(authorized[msg.sender], "Not authorized");
        return mockScore;
    }
}

contract TrifectaTest is Test {
    // Events from Trifecta contract that we'll be testing
    event ZkProofReceived(bytes32 indexed proofHash, address indexed borrower);
    event ZkProofVerified(bytes32 indexed proofHash, bool isValid, uint256 reputationScore);
    event LoanRequested(address indexed borrower, uint256 indexed offerId, bytes32 proofHash);
    event LoanApproved(uint256 indexed loanId, address indexed lender, address indexed borrower);
    event LoanFunded(uint256 indexed loanId, uint256 amount);
    event PaymentMade(uint256 indexed loanId, uint256 amount, uint256 remaining);
    event LoanRepaid(uint256 indexed loanId);
    event LoanDefaulted(uint256 indexed loanId);
    event CollateralLiquidated(uint256 indexed loanId, uint256 collateralAmount);
    event ReputationUpdated(address indexed borrower, uint256 newScore);

    Trifecta trifecta;
    MockZkVerifier mockZkVerifier;
    ReputationRegistry reputationRegistry;
    
    // Test addresses
    address owner;
    address borrower;
    address lender;
    
    // Test constants
    uint256 constant INITIAL_BALANCE = 100 ether;
    uint256 constant LOAN_AMOUNT = 10 ether;
    uint256 constant INTEREST_RATE = 1000; // 10% in basis points
    uint256 constant LOAN_DURATION = 30 days;
    uint256 constant COLLATERAL_RATIO = 15000; // 150% in basis points
    uint256 constant MIN_REPUTATION_SCORE = 700;
    
    function setUp() public {
        // Setup test addresses
        owner = makeAddr("owner");
        borrower = makeAddr("borrower");
        lender = makeAddr("lender");
        
        // Deploy mock contracts
        vm.startPrank(owner);
        mockZkVerifier = new MockZkVerifier();
        reputationRegistry = new ReputationRegistry();
        trifecta = new Trifecta(address(mockZkVerifier), address(reputationRegistry));
        
        // Authorize the Trifecta contract and set verification to true
        mockZkVerifier.authorize(address(trifecta));
        mockZkVerifier.setShouldVerify(true);
        
        // Authorize Trifecta contract in ReputationRegistry
        reputationRegistry.authorizeContract(address(trifecta));
        vm.stopPrank();
        
        // Setup initial balances
        vm.deal(lender, INITIAL_BALANCE);
        vm.deal(borrower, INITIAL_BALANCE);
        
        // Setup initial reputation score for borrower
        vm.prank(owner);
        reputationRegistry.updateScore(borrower, MIN_REPUTATION_SCORE);
    }
    
    // Helper function to create a loan offer
    function createTestLoanOffer() internal returns (uint256) {
        vm.prank(lender);
        trifecta.createLoanOffer(
            LOAN_AMOUNT,
            INTEREST_RATE,
            LOAN_DURATION,
            COLLATERAL_RATIO,
            MIN_REPUTATION_SCORE
        );
        return 1; // First offer ID
    }
    
    // Helper function to generate a mock ZK proof hash
    function generateProofHash(address _borrower) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_borrower, "test_proof"));
    }

    // Contract Setup Tests
    function testConstructor() public view {
        assertEq(address(trifecta.zkVerifier()), address(mockZkVerifier));
        assertEq(address(trifecta.reputationRegistry()), address(reputationRegistry));
        assertEq(trifecta.owner(), owner);
    }

    // Loan Offer Tests
    function testCreateLoanOffer() public {
        uint256 offerId = createTestLoanOffer();
        
        Trifecta.LoanOffer memory offer = trifecta.getLoanOfferDetails(offerId);
        assertEq(offer.lender, lender);
        assertEq(offer.amount, LOAN_AMOUNT);
        assertEq(offer.interestRate, INTEREST_RATE);
        assertEq(offer.duration, LOAN_DURATION);
        assertEq(offer.requiredCollateralRatio, COLLATERAL_RATIO);
        assertEq(offer.minimumReputationScore, MIN_REPUTATION_SCORE);
        assertTrue(offer.active);
    }

    function testCreateLoanOfferWithZeroAmount() public {
        vm.prank(lender);
        vm.expectRevert("Loan amount must be greater than 0");
        trifecta.createLoanOffer(
            0,
            INTEREST_RATE,
            LOAN_DURATION,
            COLLATERAL_RATIO,
            MIN_REPUTATION_SCORE
        );
    }

    function testCreateLoanOfferWithZeroDuration() public {
        vm.prank(lender);
        vm.expectRevert("Loan duration must be greater than 0");
        trifecta.createLoanOffer(
            LOAN_AMOUNT,
            INTEREST_RATE,
            0,
            COLLATERAL_RATIO,
            MIN_REPUTATION_SCORE
        );
    }

    function testGetLenderOffers() public {
        uint256 offerId = createTestLoanOffer();
        
        uint256[] memory offers = trifecta.getLenderOffers(lender);
        assertEq(offers.length, 1);
        assertEq(offers[0], offerId);
    }

    function testMultipleLoanOffers() public {
        // Create first offer
        uint256 firstOfferId = createTestLoanOffer();
        
        // Create second offer with different terms
        vm.prank(lender);
        trifecta.createLoanOffer(
            LOAN_AMOUNT * 2,
            INTEREST_RATE * 2,
            LOAN_DURATION * 2,
            COLLATERAL_RATIO,
            MIN_REPUTATION_SCORE
        );
        uint256 secondOfferId = 2;
        
        // Verify both offers exist and have correct terms
        Trifecta.LoanOffer memory firstOffer = trifecta.getLoanOfferDetails(firstOfferId);
        Trifecta.LoanOffer memory secondOffer = trifecta.getLoanOfferDetails(secondOfferId);
        
        assertEq(firstOffer.amount, LOAN_AMOUNT);
        assertEq(secondOffer.amount, LOAN_AMOUNT * 2);
        assertEq(firstOffer.interestRate, INTEREST_RATE);
        assertEq(secondOffer.interestRate, INTEREST_RATE * 2);
        
        // Verify lender's offer list
        uint256[] memory offers = trifecta.getLenderOffers(lender);
        assertEq(offers.length, 2);
        assertEq(offers[0], firstOfferId);
        assertEq(offers[1], secondOfferId);
    }

    // ZK Proof Verification Tests
    function testSubmitZkProof() public {
        bytes32 proofHash = generateProofHash(borrower);
        
        vm.prank(borrower);
        vm.expectEmit(true, true, false, false);
        emit ZkProofReceived(proofHash, borrower);
        trifecta.submitZkProof(proofHash);
    }

    function testReceiveZkProofResult() public {
        bytes32 proofHash = generateProofHash(borrower);
        uint256 newScore = 800;
        
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit ZkProofVerified(proofHash, true, newScore);
        vm.expectEmit(true, false, false, true);
        emit ReputationUpdated(borrower, newScore);
        trifecta.receiveZkProofResult(proofHash, borrower, true, newScore);
        
        (bool isValid, uint256 score, bool isProcessed) = trifecta.verificationResults(proofHash);
        assertTrue(isValid);
        assertEq(score, newScore);
        assertFalse(isProcessed);
    }

    function testReceiveZkProofResultNotOwner() public {
        bytes32 proofHash = generateProofHash(borrower);
        
        vm.prank(borrower);
        vm.expectRevert("Only owner can call this function");
        trifecta.receiveZkProofResult(proofHash, borrower, true, 800);
    }

    // Loan Request Tests
    function testRequestLoan() public {
        uint256 offerId = createTestLoanOffer();
        bytes32 proofHash = generateProofHash(borrower);
        uint256 requiredCollateral = (LOAN_AMOUNT * COLLATERAL_RATIO) / 10000;
        
        // Setup proof verification
        vm.prank(owner);
        trifecta.receiveZkProofResult(proofHash, borrower, true, MIN_REPUTATION_SCORE);
        
        // Request loan
        vm.prank(borrower);
        vm.expectEmit(true, true, false, true);
        emit LoanRequested(borrower, offerId, proofHash);
        emit LoanApproved(1, lender, borrower);
        emit LoanFunded(1, LOAN_AMOUNT);
        trifecta.requestLoan{value: requiredCollateral}(offerId, proofHash);
        
        // Verify loan details
        Trifecta.Loan memory loan = trifecta.getLoanDetails(1);
        assertEq(loan.borrower, borrower);
        assertEq(loan.lender, lender);
        assertEq(loan.amount, LOAN_AMOUNT);
        assertEq(loan.interestRate, INTEREST_RATE);
        assertEq(loan.duration, LOAN_DURATION);
        assertEq(loan.collateralAmount, requiredCollateral);
        assertEq(uint256(loan.status), uint256(Trifecta.LoanStatus.Active));
    }

    function testRequestLoanInsufficientCollateral() public {
        uint256 offerId = createTestLoanOffer();
        bytes32 proofHash = generateProofHash(borrower);
        uint256 requiredCollateral = (LOAN_AMOUNT * COLLATERAL_RATIO) / 10000;
        
        // Setup proof verification
        vm.prank(owner);
        trifecta.receiveZkProofResult(proofHash, borrower, true, MIN_REPUTATION_SCORE);
        
        // Request loan with insufficient collateral
        vm.prank(borrower);
        vm.expectRevert("Insufficient collateral");
        trifecta.requestLoan{value: requiredCollateral - 1 ether}(offerId, proofHash);
    }

    function testRequestLoanInvalidProof() public {
        uint256 offerId = createTestLoanOffer();
        bytes32 proofHash = generateProofHash(borrower);
        uint256 requiredCollateral = (LOAN_AMOUNT * COLLATERAL_RATIO) / 10000;
        
        // Request loan without proof verification
        vm.prank(borrower);
        vm.expectRevert("Invalid or unverified ZK proof");
        trifecta.requestLoan{value: requiredCollateral}(offerId, proofHash);
    }

    function testRequestLoanLowReputationScore() public {
        uint256 offerId = createTestLoanOffer();
        bytes32 proofHash = generateProofHash(borrower);
        uint256 requiredCollateral = (LOAN_AMOUNT * COLLATERAL_RATIO) / 10000;
        
        // Setup proof verification with low score
        vm.prank(owner);
        trifecta.receiveZkProofResult(proofHash, borrower, true, MIN_REPUTATION_SCORE - 100);
        
        // Request loan
        vm.prank(borrower);
        vm.expectRevert("Reputation score too low");
        trifecta.requestLoan{value: requiredCollateral}(offerId, proofHash);
    }

    function testRequestLoanInactiveLoanOffer() public {
        uint256 offerId = createTestLoanOffer();
        bytes32 proofHash = generateProofHash(borrower);
        uint256 requiredCollateral = (LOAN_AMOUNT * COLLATERAL_RATIO) / 10000;
        
        // Setup proof verification
        vm.prank(owner);
        trifecta.receiveZkProofResult(proofHash, borrower, true, MIN_REPUTATION_SCORE);
        
        // Request and complete first loan
        vm.prank(borrower);
        trifecta.requestLoan{value: requiredCollateral}(offerId, proofHash);
        
        // Try to request the same offer again
        bytes32 newProofHash = generateProofHash(borrower);
        vm.prank(owner);
        trifecta.receiveZkProofResult(newProofHash, borrower, true, MIN_REPUTATION_SCORE);
        
        vm.prank(borrower);
        vm.expectRevert("Loan offer is not active");
        trifecta.requestLoan{value: requiredCollateral}(offerId, newProofHash);
    }

    // Loan Management and Repayment Tests
    function testMakeFullPayment() public {
        // Setup and request loan
        uint256 offerId = createTestLoanOffer();
        bytes32 proofHash = generateProofHash(borrower);
        uint256 requiredCollateral = (LOAN_AMOUNT * COLLATERAL_RATIO) / 10000;
        
        vm.prank(owner);
        trifecta.receiveZkProofResult(proofHash, borrower, true, MIN_REPUTATION_SCORE);
        
        vm.prank(borrower);
        trifecta.requestLoan{value: requiredCollateral}(offerId, proofHash);
        
        // Calculate total repayment amount
        uint256 totalDue = LOAN_AMOUNT + (LOAN_AMOUNT * INTEREST_RATE / 10000);
        
        // Make full payment
        vm.prank(borrower);
        vm.expectEmit(true, false, false, true);
        emit LoanRepaid(1);
        trifecta.makePayment{value: totalDue}(1);
        
        // Verify loan status and repayment
        Trifecta.Loan memory loan = trifecta.getLoanDetails(1);
        assertEq(uint256(loan.status), uint256(Trifecta.LoanStatus.Repaid));
        assertEq(loan.amountRepaid, totalDue);
    }

    function testMakePartialPayment() public {
        // Setup and request loan
        uint256 offerId = createTestLoanOffer();
        bytes32 proofHash = generateProofHash(borrower);
        uint256 requiredCollateral = (LOAN_AMOUNT * COLLATERAL_RATIO) / 10000;
        
        vm.prank(owner);
        trifecta.receiveZkProofResult(proofHash, borrower, true, MIN_REPUTATION_SCORE);
        
        vm.prank(borrower);
        trifecta.requestLoan{value: requiredCollateral}(offerId, proofHash);
        
        // Make partial payment
        uint256 partialPayment = LOAN_AMOUNT / 2;
        vm.prank(borrower);
        vm.expectEmit(true, false, false, true);
        emit PaymentMade(1, partialPayment, LOAN_AMOUNT + (LOAN_AMOUNT * INTEREST_RATE / 10000) - partialPayment);
        trifecta.makePayment{value: partialPayment}(1);
        
        // Verify loan status and partial repayment
        Trifecta.Loan memory loan = trifecta.getLoanDetails(1);
        assertEq(uint256(loan.status), uint256(Trifecta.LoanStatus.Active));
        assertEq(loan.amountRepaid, partialPayment);
    }

    function testMakePaymentNotBorrower() public {
        // Setup and request loan
        uint256 offerId = createTestLoanOffer();
        bytes32 proofHash = generateProofHash(borrower);
        uint256 requiredCollateral = (LOAN_AMOUNT * COLLATERAL_RATIO) / 10000;
        
        vm.prank(owner);
        trifecta.receiveZkProofResult(proofHash, borrower, true, MIN_REPUTATION_SCORE);
        
        vm.prank(borrower);
        trifecta.requestLoan{value: requiredCollateral}(offerId, proofHash);
        
        // Try to make payment from different address
        vm.prank(lender);
        vm.expectRevert("Only borrower can call this function");
        trifecta.makePayment{value: LOAN_AMOUNT}(1);
    }

    function testCheckLoanDefault() public {
        // Setup and request loan
        uint256 offerId = createTestLoanOffer();
        bytes32 proofHash = generateProofHash(borrower);
        uint256 requiredCollateral = (LOAN_AMOUNT * COLLATERAL_RATIO) / 10000;
        
        vm.prank(owner);
        trifecta.receiveZkProofResult(proofHash, borrower, true, MIN_REPUTATION_SCORE);
        
        vm.prank(borrower);
        trifecta.requestLoan{value: requiredCollateral}(offerId, proofHash);
        
        // Move time forward past default threshold
        vm.warp(block.timestamp + LOAN_DURATION + 8 days);
        
        // Check loan default
        vm.expectEmit(true, false, false, true);
        emit LoanDefaulted(1);
        emit CollateralLiquidated(1, requiredCollateral);
        trifecta.checkLoanDefault(1);
        
        // Verify loan status
        Trifecta.Loan memory loan = trifecta.getLoanDetails(1);
        assertEq(uint256(loan.status), uint256(Trifecta.LoanStatus.Defaulted));
    }

    function testCheckLoanDefaultBeforeThreshold() public {
        // Setup and request loan
        uint256 offerId = createTestLoanOffer();
        bytes32 proofHash = generateProofHash(borrower);
        uint256 requiredCollateral = (LOAN_AMOUNT * COLLATERAL_RATIO) / 10000;
        
        vm.prank(owner);
        trifecta.receiveZkProofResult(proofHash, borrower, true, MIN_REPUTATION_SCORE);
        
        vm.prank(borrower);
        trifecta.requestLoan{value: requiredCollateral}(offerId, proofHash);
        
        // Get initial loan state
        Trifecta.Loan memory initialLoan = trifecta.getLoanDetails(1);
        uint256 initialNextPaymentDue = initialLoan.nextPaymentDue;
        
        // Move time forward but not past default threshold (7 days)
        vm.warp(initialNextPaymentDue + 6 days);
        
        // Check loan default - should not default yet
        trifecta.checkLoanDefault(1);
        
        // Verify loan still active
        Trifecta.Loan memory loan = trifecta.getLoanDetails(1);
        assertEq(uint256(loan.status), uint256(Trifecta.LoanStatus.Active));
    }

    function testReputationUpdateAfterRepayment() public {
        // Setup and request loan
        uint256 offerId = createTestLoanOffer();
        bytes32 proofHash = generateProofHash(borrower);
        uint256 requiredCollateral = (LOAN_AMOUNT * COLLATERAL_RATIO) / 10000;
        
        vm.prank(owner);
        trifecta.receiveZkProofResult(proofHash, borrower, true, MIN_REPUTATION_SCORE);
        
        vm.prank(borrower);
        trifecta.requestLoan{value: requiredCollateral}(offerId, proofHash);
        
        // Get initial reputation score
        uint256 initialScore = trifecta.getBorrowerScore(borrower);
        
        // Make full payment
        uint256 totalDue = LOAN_AMOUNT + (LOAN_AMOUNT * INTEREST_RATE / 10000);
        vm.prank(borrower);
        trifecta.makePayment{value: totalDue}(1);
        
        // Verify reputation score increased
        uint256 newScore = trifecta.getBorrowerScore(borrower);
        assertTrue(newScore > initialScore);
    }
} 