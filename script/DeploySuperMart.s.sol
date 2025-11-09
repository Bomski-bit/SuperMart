// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DeploySuperMart
 * @notice Foundry deployment script for SuperMart.
 */
import {Script, console} from "forge-std/Script.sol";
import {SuperMart} from "../src/SuperMart.sol";

contract DeploySuperMart is Script {
    function run() external returns (SuperMart) {
        uint256 initialFeeBps;
        try vm.envUint("INITIAL_FEE_BPS") returns (uint256 val) {
            initialFeeBps = val;
        } catch {
            initialFeeBps = 250;
        }

        vm.startBroadcast(msg.sender);
        SuperMart superMart = new SuperMart(initialFeeBps);
        vm.stopBroadcast();

        console.log("SuperMart deployed at:", address(superMart));
        console.log("Initial platform fee (bps):", initialFeeBps);
        console.log("Deploying to network chain ID:", block.chainid);

        return superMart;
    }
}
