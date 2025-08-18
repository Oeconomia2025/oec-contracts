// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DDBFaucet.sol";

/**
 * One-click deploy faucet for DooDoo Butt (DDB) on Sepolia.
 * Sends 1,000 DDB per wallet per 24h (uses token.decimals() to scale).
 * TOKEN: 0x02675d29817Dd82E4268A58cd11Ba3d3868bd9B3 (Sepolia)
 */
contract DDBFaucetSepolia is DDBFaucet {
    constructor() DDBFaucet(
        0x02675d29817Dd82E4268A58cd11Ba3d3868bd9B3, // DDB token (Sepolia)
        0                                         // 0 = default 1,000 * 10^decimals
    ) {}
}
