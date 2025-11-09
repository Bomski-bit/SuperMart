// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DeploySuperMart} from "../../script/DeploySuperMart.s.sol";
import {SuperMart} from "../../src/SuperMart.sol";

/**
 * @title DeploySuperMartTests
 * @notice Tests the deployment and configuration logic of the DeploySuperMart script.
 * @dev This test file treats the deploy script as a contract to be tested.
 * It checks that the script correctly handles both default values and
 * environment variables.
 */
contract DeploySuperMartTests is Test {
    DeploySuperMart public deployScript;

    function setUp() public {
        deployScript = new DeploySuperMart();

        vm.setEnv("INITIAL_FEE_BPS", "");
    }

    function test_A_DeployScriptWithDefaultFee() public {
        // --- 1. Arrange ---
        uint256 expectedFee = 250;

        // --- 2. Act ---
        SuperMart superMart = deployScript.run();

        // --- 3. Assert ---
        (, uint256 actualFee) = superMart.getPlatformFeeInfo();
        assertEq(actualFee, expectedFee, "Fee should be the default 250");
    }

    function test_B_DeployScriptWithCustomFee() public {
        // --- 1. Arrange ---
        uint256 customFee = 500;

        // We override the 'setUp' and set our custom value
        vm.setEnv("INITIAL_FEE_BPS", vm.toString(customFee));

        // --- 2. Act ---
        SuperMart superMart = deployScript.run();

        // --- 3. Assert ---
        (, uint256 actualFee) = superMart.getPlatformFeeInfo();
        assertEq(actualFee, customFee, "Fee should be the custom 500");
    }
}
