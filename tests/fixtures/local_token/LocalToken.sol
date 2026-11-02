// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;
/// Isolated local-node fixture. Never included in either Flutter app.
contract LocalToken {
    mapping(address => uint256) public balanceOf;
    event Transfer(address indexed from, address indexed to, uint256 value);
    function mint(address recipient, uint256 value) external { balanceOf[recipient] += value; }
    function transfer(address recipient, uint256 value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "balance");
        balanceOf[msg.sender] -= value;
        balanceOf[recipient] += value;
        emit Transfer(msg.sender, recipient, value);
        return true;
    }
}
