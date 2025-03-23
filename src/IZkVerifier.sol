// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title IZkVerifier
 * @dev Interface for zero-knowledge proof verification
 */
interface IZkVerifier {
    /**
     * @dev Verifies a zero-knowledge proof
     * @param _proof The zero-knowledge proof to verify
     * @return True if the proof is valid
     */
    function verify(bytes memory _proof) external returns (bool);

    /**
     * @dev Extracts reputation score from a verified proof
     * @param _proof The zero-knowledge proof
     * @return The reputation score
     */
    function extractScore(bytes memory _proof) external view returns (uint256);
}
