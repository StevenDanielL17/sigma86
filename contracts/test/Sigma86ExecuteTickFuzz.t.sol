// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Sigma86Vault.sol";

contract MockOneInchRouter2 {
    uint256 public returnAmount;
    constructor(uint256 _ret) { returnAmount = _ret; }
    fallback() external payable {
        uint256 ret = returnAmount;
        assembly { mstore(0x00, ret) return(0x00, 0x20) }
    }
}

contract MockChainlink2 {
    int256 public price;
    constructor(int256 _p) { price = _p; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

contract Sigma86ExecuteTickFuzzTest is Test {
    address owner = address(0x111);
    address upkeeper = address(0x222);

    function testFuzz_ExecuteTickRevertsForRandomCallers(address caller, bytes calldata data) public {
        vm.assume(caller != upkeeper);
        vm.assume(caller != address(this));
        MockOneInchRouter2 router = new MockOneInchRouter2(1);
        MockChainlink2 oracle = new MockChainlink2(1);
        vm.prank(owner);
        Sigma86Vault vault = new Sigma86Vault(upkeeper, address(router), address(oracle), 100);
        uint256[] memory s = new uint256[](1); s[0] = 1e18;
        vm.prank(owner); vault.startSchedule(s);
        vm.prank(caller);
        vm.expectRevert("Not authorized");
        vault.executeTick(data);
    }
}
