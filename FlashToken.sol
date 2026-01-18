// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract CustomFlashToken is ERC20, Ownable {
    uint256 private constant DEFAULT_EXPIRY_DURATION = 120 days;
    uint256 private _defaultExpiryDuration;
    
    uint8 private immutable _decimals;
    
    struct Batch {
        uint256 amount;
        uint256 expiryTimestamp;
    }
    
    mapping(address => Batch[]) private _userBatches;
    
    constructor(
        string memory name, 
        string memory symbol, 
        uint8 decimals_
    ) ERC20(name, symbol) Ownable() {
        _decimals = decimals_;
        _defaultExpiryDuration = DEFAULT_EXPIRY_DURATION;
    }
    
    // ========== OVERRIDES ==========
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
    
    // ========== OWNER FUNCTIONS ==========
    function mint(address to, uint256 amount) external onlyOwner {
        mintWithExpiry(to, amount, block.timestamp + _defaultExpiryDuration);
    }
    
    function mintWithExpiry(address to, uint256 amount, uint256 expiryTimestamp) public onlyOwner {
        require(expiryTimestamp > block.timestamp, "Expiry must be in the future");
        _addBatch(to, amount, expiryTimestamp);
        _mint(to, amount);
    }
    
    function mintWithDuration(address to, uint256 amount, uint256 expiryDuration) external onlyOwner {
        uint256 expiryTimestamp = block.timestamp + expiryDuration;
        mintWithExpiry(to, amount, expiryTimestamp);
    }
    
    function burnFromOwner(address account, uint256 amount) external onlyOwner {
        _burn(account, amount);
        // Remove burned amount from batches
        _removeFromBatches(account, amount);
    }
    
    function setDefaultExpiryDuration(uint256 newDuration) external onlyOwner {
        _defaultExpiryDuration = newDuration;
    }
    
    // ========== PUBLIC BURN ==========
    function burn(uint256 amount) external {
        address account = msg.sender;
        _burn(account, amount);
        _removeFromBatches(account, amount);
    }
    
    // ========== TRANSFER ==========
    function transfer(address to, uint256 amount) public override returns (bool) {
        _transferBatches(msg.sender, to, amount);
        return super.transfer(to, amount);
    }
    
    function transferFrom(address from, address to, uint256 amount) 
        public 
        override 
        returns (bool) 
    {
        _transferBatches(from, to, amount);
        return super.transferFrom(from, to, amount);
    }
    
    // ========== BATCH LOGIC ==========
    function _addBatch(address user, uint256 amount, uint256 expiryTimestamp) private {
        _userBatches[user].push(Batch(amount, expiryTimestamp));
    }
    
    function _removeFromBatches(address user, uint256 amount) private {
        _cleanExpired(user);
        
        uint256 remaining = amount;
        uint256 currentTime = block.timestamp;
        
        for (uint256 i = 0; i < _userBatches[user].length && remaining > 0; ) {
            Batch storage batch = _userBatches[user][i];
            
            if (batch.expiryTimestamp <= currentTime) {
                i++;
                continue;
            }
            
            uint256 burnAmt = batch.amount > remaining ? remaining : batch.amount;
            batch.amount -= burnAmt;
            remaining -= burnAmt;
            
            if (batch.amount == 0) {
                _removeBatch(user, i);
                // Don't increment i since we removed element
            } else {
                i++;
            }
        }
        
        require(remaining == 0, "Insufficient valid tokens to burn");
    }
    
    function _transferBatches(address from, address to, uint256 amount) private {
        _cleanExpired(from);
        
        uint256 remaining = amount;
        uint256 currentTime = block.timestamp;
        
        // Track what we're transferring
        Batch[] memory transfers = new Batch[](_userBatches[from].length);
        uint256 transferCount = 0;
        
        // 1. Figure out which batches to transfer
        for (uint256 i = 0; i < _userBatches[from].length && remaining > 0; i++) {
            Batch storage batch = _userBatches[from][i];
            
            if (batch.expiryTimestamp <= currentTime) continue;
            
            uint256 transferAmt = batch.amount > remaining ? remaining : batch.amount;
            
            // Store transfer info
            transfers[transferCount] = Batch(transferAmt, batch.expiryTimestamp);
            transferCount++;
            
            remaining -= transferAmt;
        }
        
        require(remaining == 0, "Insufficient valid tokens");
        
        // 2. Remove from sender
        remaining = amount; // Reset
        for (uint256 i = 0; i < _userBatches[from].length && remaining > 0; ) {
            Batch storage batch = _userBatches[from][i];
            
            if (batch.expiryTimestamp <= currentTime) {
                i++;
                continue;
            }
            
            uint256 transferAmt = batch.amount > remaining ? remaining : batch.amount;
            batch.amount -= transferAmt;
            remaining -= transferAmt;
            
            if (batch.amount == 0) {
                _removeBatch(from, i);
                // Don't increment i since we removed element
            } else {
                i++;
            }
        }
        
        // 3. Add to receiver
        for (uint256 i = 0; i < transferCount; i++) {
            _addToReceiver(to, transfers[i].amount, transfers[i].expiryTimestamp);
        }
    }
    
    function _addToReceiver(address to, uint256 amount, uint256 expiryTimestamp) private {
        // Try to merge with existing batch of same expiry
        for (uint256 i = 0; i < _userBatches[to].length; i++) {
            if (_userBatches[to][i].expiryTimestamp == expiryTimestamp) {
                _userBatches[to][i].amount += amount;
                return;
            }
        }
        
        // Add new batch
        _userBatches[to].push(Batch(amount, expiryTimestamp));
    }
    
    function _removeBatch(address user, uint256 index) private {
        Batch[] storage batches = _userBatches[user];
        if (index < batches.length - 1) {
            batches[index] = batches[batches.length - 1];
        }
        batches.pop();
    }
    
    function _cleanExpired(address user) private {
        uint256 currentTime = block.timestamp;
        
        for (uint256 i = 0; i < _userBatches[user].length; ) {
            if (_userBatches[user][i].expiryTimestamp <= currentTime) {
                // Burn expired tokens
                uint256 expiredAmount = _userBatches[user][i].amount;
                _burn(user, expiredAmount);
                _removeBatch(user, i);
                // Don't increment i since we removed element
            } else {
                i++;
            }
        }
    }
    
    // ========== VIEW FUNCTIONS ==========
    function balanceOf(address account) public view override returns (uint256) {
        uint256 total;
        uint256 currentTime = block.timestamp;
        
        for (uint256 i = 0; i < _userBatches[account].length; i++) {
            if (_userBatches[account][i].expiryTimestamp > currentTime) {
                total += _userBatches[account][i].amount;
            }
        }
        return total;
    }
    
    function getBatches(address account) external view returns (Batch[] memory) {
        return _userBatches[account];
    }
    
    function getBatchDetails(address account) external view returns (
        uint256[] memory amounts,
        uint256[] memory expiryTimestamps,
        string[] memory expiryDates,
        bool[] memory isExpired
    ) {
        Batch[] memory batches = _userBatches[account];
        uint256 length = batches.length;
        uint256 currentTime = block.timestamp;
        
        amounts = new uint256[](length);
        expiryTimestamps = new uint256[](length);
        expiryDates = new string[](length);
        isExpired = new bool[](length);
        
        for (uint256 i = 0; i < length; i++) {
            amounts[i] = batches[i].amount;
            expiryTimestamps[i] = batches[i].expiryTimestamp;
            isExpired[i] = batches[i].expiryTimestamp <= currentTime;
            expiryDates[i] = "Check off-chain";
        }
        
        return (amounts, expiryTimestamps, expiryDates, isExpired);
    }
    
    function willExpireBefore(address account, uint256 timestamp) external view returns (bool) {
        uint256 currentTime = block.timestamp;
        uint256 totalExpiring = 0;
        
        for (uint256 i = 0; i < _userBatches[account].length; i++) {
            if (_userBatches[account][i].expiryTimestamp <= timestamp && 
                _userBatches[account][i].expiryTimestamp > currentTime) {
                totalExpiring += _userBatches[account][i].amount;
            }
        }
        
        return totalExpiring > 0;
    }
    
    function getDefaultExpiryDuration() external view returns (uint256) {
        return _defaultExpiryDuration;
    }
    
    function getNextExpiry(address account) external view returns (uint256) {
        uint256 currentTime = block.timestamp;
        uint256 nextExpiry = type(uint256).max;
        
        for (uint256 i = 0; i < _userBatches[account].length; i++) {
            if (_userBatches[account][i].expiryTimestamp > currentTime && 
                _userBatches[account][i].expiryTimestamp < nextExpiry) {
                nextExpiry = _userBatches[account][i].expiryTimestamp;
            }
        }
        
        return nextExpiry == type(uint256).max ? 0 : nextExpiry;
    }
    
    // ========== HELPER FUNCTIONS ==========
    function cleanMyExpired() external {
        _cleanExpired(msg.sender);
    }
    
    function validBalanceOf(address account) external view returns (uint256) {
        return balanceOf(account);
    }
    
    function expiredBalanceOf(address account) external view returns (uint256) {
        uint256 total;
        uint256 currentTime = block.timestamp;
        
        for (uint256 i = 0; i < _userBatches[account].length; i++) {
            if (_userBatches[account][i].expiryTimestamp <= currentTime) {
                total += _userBatches[account][i].amount;
            }
        }
        return total;
    }
    
    // ========== HELPER FUNCTIONS FOR DURATION CONVERSION ==========
    
    function daysToSeconds(uint256 days_) public pure returns (uint256) {
        return days_ * 1 days;
    }
    
    function weeksToSeconds(uint256 weeks_) public pure returns (uint256) {
        return weeks_ * 1 weeks;
    }
    
    function monthsToSeconds(uint256 months) public pure returns (uint256) {
        // Approximate: 30.44 days per month
        return months * 30 days + (months * 10 hours + 48 minutes);
    }
    
    function getCurrentTimestamp() public view returns (uint256) {
        return block.timestamp;
    }
    
    function getFutureTimestamp(uint256 daysFromNow) public view returns (uint256) {
        return block.timestamp + daysToSeconds(daysFromNow);
    }
}
