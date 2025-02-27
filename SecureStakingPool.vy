# @version ^0.4.0

"""
@title Secure Staking Pool Contract
@author Your Assistant
@notice A secure staking pool with enhanced protection against attacks
@dev Implements reentrancy protection, rate limiting, and secure token handling
"""

from ethereum.ercs import IERC20

# Security settings
DECIMALS: constant(uint256) = 10**18  # Standard ERC20 decimals
RATE_LIMIT_PERIOD: constant(uint256) = 86400  # 24 hours
MIN_STAKE_AMOUNT: constant(uint256) = 1000  # Minimum stake to prevent dust
MAX_STAKE_AMOUNT: constant(uint256) = 1000000000000000000000000  # Maximum stake (1M tokens)
MAX_DAILY_WITHDRAW: constant(uint256) = 100000000000000000000000  # Maximum daily withdrawal (100K tokens)
TIMELOCK_PERIOD: constant(uint256) = 3600  # 1 hour minimum stake time
MAX_REWARD_RATE: constant(uint256) = 1000000000000000000  # Maximum reward rate (1 token/second)

# Events
event Staked:
    user: indexed(address)
    amount: uint256
    timestamp: uint256

event Withdrawn:
    user: indexed(address)
    amount: uint256
    timestamp: uint256

event RewardClaimed:
    user: indexed(address)
    amount: uint256
    timestamp: uint256

event EmergencyWithdrawn:
    user: indexed(address)
    amount: uint256
    timestamp: uint256

event RateUpdated:
    old_rate: uint256
    new_rate: uint256
    timestamp: uint256

event BridgeStaked:
    user: indexed(address)
    recipient: indexed(address)
    amount: uint256
    target_chain: uint256
    timestamp: uint256

# State Variables
owner: public(address)
pending_owner: public(address)
token: public(address)
bridge_contract: public(address)
reward_rate: public(uint256)
total_staked: public(uint256)
total_rewards_paid: public(uint256)
min_stake_time: public(uint256)
last_update_time: public(uint256)  # Last time rewards were updated
rewards_per_token_stored: public(uint256)  # Accumulated rewards per token

# User state
balances: public(HashMap[address, uint256])
stake_timestamps: public(HashMap[address, uint256])
rewards_per_token_paid: public(HashMap[address, uint256])
user_reward_per_token_paid: public(HashMap[address, uint256])
rewards: public(HashMap[address, uint256])

# Security state
is_paused: public(bool)
entered: bool  # Reentrancy guard
daily_withdrawals: public(HashMap[address, uint256])
last_withdrawal_reset: public(HashMap[address, uint256])
supported_chains: public(HashMap[uint256, bool])

@deploy
def __init__(_token: address, _reward_rate: uint256, _min_stake_time: uint256):
    """
    @notice Initialize the staking pool
    @param _token Token address
    @param _reward_rate Reward rate per second
    @param _min_stake_time Minimum stake time
    """
    assert _token != empty(address), "Invalid token"
    assert _reward_rate <= MAX_REWARD_RATE, "Rate too high"
    assert _min_stake_time >= TIMELOCK_PERIOD, "Timelock too short"
    
    self.owner = msg.sender
    self.token = _token
    self.reward_rate = _reward_rate
    self.min_stake_time = _min_stake_time
    self.last_update_time = block.timestamp
    self.entered = False

@internal
def _ensure_not_entered():
    """
    @notice Prevent reentrant calls
    """
    assert not self.entered, "Reentrant call"
    self.entered = True

@internal
def _exit_reentrancy_guard():
    """
    @notice Exit reentrancy guard safely
    """
    self.entered = False

@internal
def _ensure_not_paused():
    """
    @notice Check if contract is not paused
    """
    assert not self.is_paused, "Contract is paused"

@internal
def _check_daily_withdraw_limit(user: address, amount: uint256):
    """
    @notice Check and update daily withdrawal limits
    @param user User address
    @param amount Withdrawal amount
    """
    current_time: uint256 = block.timestamp
    last_reset: uint256 = self.last_withdrawal_reset[user]
    
    # Reset if period has elapsed
    if current_time - last_reset >= RATE_LIMIT_PERIOD:
        self.daily_withdrawals[user] = amount
        self.last_withdrawal_reset[user] = current_time
    else:
        # Calculate new amount
        new_amount: uint256 = self.daily_withdrawals[user] + amount
        assert new_amount <= MAX_DAILY_WITHDRAW, "Daily limit exceeded"
        assert new_amount >= self.daily_withdrawals[user], "Overflow check"
        self.daily_withdrawals[user] = new_amount

@internal
def _update_reward(user: address):
    """
    @notice Update reward calculations
    @param user User address to update
    """
    # Update stored rewards per token
    if self.total_staked > 0:
        time_elapsed: uint256 = block.timestamp - self.last_update_time
        reward_per_token_delta: uint256 = (time_elapsed * self.reward_rate * DECIMALS) // self.total_staked
        self.rewards_per_token_stored += reward_per_token_delta
    
    self.last_update_time = block.timestamp
    
    # Update user rewards
    if user != empty(address):
        user_balance: uint256 = self.balances[user]
        pending_reward: uint256 = (user_balance * (self.rewards_per_token_stored - self.user_reward_per_token_paid[user])) // DECIMALS
        self.rewards[user] += pending_reward
        self.user_reward_per_token_paid[user] = self.rewards_per_token_stored

@external
def transfer_ownership(new_owner: address):
    """
    @notice Initiate ownership transfer
    @param new_owner New owner address
    """
    self._ensure_not_entered()
    assert msg.sender == self.owner, "Only owner"
    assert new_owner != empty(address), "Invalid address"
    assert new_owner != self.owner, "Already owner"
    self.pending_owner = new_owner
    self._exit_reentrancy_guard()

@external
def accept_ownership():
    """
    @notice Accept ownership transfer
    """
    self._ensure_not_entered()
    assert msg.sender == self.pending_owner, "Only pending owner"
    old_owner: address = self.owner
    self.owner = msg.sender
    self.pending_owner = empty(address)
    assert self.owner == msg.sender, "Transfer failed"
    self._exit_reentrancy_guard()

@external
def stake(amount: uint256):
    """
    @notice Stake tokens
    @param amount Amount to stake
    """
    self._ensure_not_entered()
    self._ensure_not_paused()
    assert amount >= MIN_STAKE_AMOUNT, "Amount too small"
    assert amount <= MAX_STAKE_AMOUNT, "Amount too large"
    
    # Update rewards
    self._update_reward(msg.sender)
    
    # Save old balance for verification
    old_balance: uint256 = staticcall IERC20(self.token).balanceOf(self)
    
    # Update state
    self.total_staked += amount
    self.balances[msg.sender] += amount
    self.stake_timestamps[msg.sender] = block.timestamp
    
    # Transfer tokens
    assert extcall IERC20(self.token).transferFrom(msg.sender, self, amount), "Transfer failed"
    
    # Verify transfer
    new_balance: uint256 = staticcall IERC20(self.token).balanceOf(self)
    assert new_balance == old_balance + amount, "Balance check failed"
    
    log Staked(msg.sender, amount, block.timestamp)
    self._exit_reentrancy_guard()

@external
def withdraw(amount: uint256):
    """
    @notice Withdraw staked tokens
    @param amount Amount to withdraw
    """
    self._ensure_not_entered()
    self._ensure_not_paused()
    assert amount > 0, "Invalid amount"
    assert self.balances[msg.sender] >= amount, "Insufficient balance"
    assert block.timestamp >= self.stake_timestamps[msg.sender] + self.min_stake_time, "Timelock active"
    
    # Check withdrawal limit
    self._check_daily_withdraw_limit(msg.sender, amount)
    
    # Update rewards
    self._update_reward(msg.sender)
    
    # Update state BEFORE transfer
    self.total_staked -= amount
    self.balances[msg.sender] -= amount
    
    # Save old balance for verification
    old_balance: uint256 = staticcall IERC20(self.token).balanceOf(self)
    
    # Transfer tokens
    assert extcall IERC20(self.token).transfer(msg.sender, amount), "Transfer failed"
    
    # Verify transfer
    new_balance: uint256 = staticcall IERC20(self.token).balanceOf(self)
    assert new_balance == old_balance - amount, "Balance check failed"
    
    log Withdrawn(msg.sender, amount, block.timestamp)
    self._exit_reentrancy_guard()

@external
def claim_reward():
    """
    @notice Claim accumulated rewards
    """
    self._ensure_not_entered()
    self._ensure_not_paused()
    
    # Update and get rewards
    self._update_reward(msg.sender)
    reward_amount: uint256 = self.rewards[msg.sender]
    assert reward_amount > 0, "No rewards"
    
    # Reset rewards BEFORE transfer
    self.rewards[msg.sender] = 0
    self.total_rewards_paid += reward_amount
    
    # Save old balance for verification
    old_balance: uint256 = staticcall IERC20(self.token).balanceOf(self)
    
    # Transfer rewards
    assert extcall IERC20(self.token).transfer(msg.sender, reward_amount), "Transfer failed"
    
    # Verify transfer
    new_balance: uint256 = staticcall IERC20(self.token).balanceOf(self)
    assert new_balance == old_balance - reward_amount, "Balance check failed"
    
    log RewardClaimed(msg.sender, reward_amount, block.timestamp)
    self._exit_reentrancy_guard()

@external
def emergency_withdraw():
    """
    @notice Emergency withdrawal of staked tokens
    """
    self._ensure_not_entered()
    assert self.is_paused, "Not paused"
    
    amount: uint256 = self.balances[msg.sender]
    assert amount > 0, "No balance"
    
    # Update state BEFORE transfer
    self.total_staked -= amount
    self.balances[msg.sender] = 0
    
    # Save old balance for verification
    old_balance: uint256 = staticcall IERC20(self.token).balanceOf(self)
    
    # Transfer tokens
    assert extcall IERC20(self.token).transfer(msg.sender, amount), "Transfer failed"
    
    # Verify transfer
    new_balance: uint256 = staticcall IERC20(self.token).balanceOf(self)
    assert new_balance == old_balance - amount, "Balance check failed"
    
    log EmergencyWithdrawn(msg.sender, amount, block.timestamp)
    self._exit_reentrancy_guard()

@external
def set_bridge_contract(bridge: address):
    """
    @notice Set bridge contract address
    @param bridge Bridge contract address
    """
    self._ensure_not_entered()
    assert msg.sender == self.owner, "Only owner"
    assert bridge != empty(address), "Invalid address"
    self.bridge_contract = bridge
    self._exit_reentrancy_guard()

@external
def add_supported_chain(chain_id: uint256):
    """
    @notice Add supported chain for bridging
    @param chain_id Chain ID to support
    """
    self._ensure_not_entered()
    assert msg.sender == self.owner, "Only owner"
    assert chain_id > 0, "Invalid chain"
    self.supported_chains[chain_id] = True
    self._exit_reentrancy_guard()

@external
def bridge_stake(amount: uint256, recipient: address, target_chain: uint256):
    """
    @notice Bridge staked tokens to another chain
    @param amount Amount to bridge
    @param recipient Recipient address
    @param target_chain Target chain ID
    """
    self._ensure_not_entered()
    self._ensure_not_paused()
    assert self.bridge_contract != empty(address), "Bridge not set"
    assert self.supported_chains[target_chain], "Chain not supported"
    assert recipient != empty(address), "Invalid recipient"
    assert amount <= self.balances[msg.sender], "Insufficient balance"
    assert block.timestamp >= self.stake_timestamps[msg.sender] + self.min_stake_time, "Timelock active"
    
    # Update rewards
    self._update_reward(msg.sender)
    
    # Update state BEFORE transfer
    self.total_staked -= amount
    self.balances[msg.sender] -= amount
    
    # Save old balance for verification
    old_balance: uint256 = staticcall IERC20(self.token).balanceOf(self)
    
    # Approve bridge contract
    assert extcall IERC20(self.token).approve(self.bridge_contract, amount), "Approve failed"
    
    # Call bridge contract (this will transfer the tokens)
    raw_call(
        self.bridge_contract,
        concat(
            method_id("bridgeTokens(address,uint256,address,uint256)"),
            convert(self.token, bytes32),
            convert(amount, bytes32),
            convert(recipient, bytes32),
            convert(target_chain, bytes32)
        )
    )
    
    # Verify transfer
    new_balance: uint256 = staticcall IERC20(self.token).balanceOf(self)
    assert new_balance == old_balance - amount, "Balance check failed"
    
    log BridgeStaked(msg.sender, recipient, amount, target_chain, block.timestamp)
    self._exit_reentrancy_guard()

@external
def pause():
    """
    @notice Pause the contract
    """
    assert msg.sender == self.owner, "Only owner"
    self.is_paused = True

@external
def unpause():
    """
    @notice Unpause the contract
    """
    assert msg.sender == self.owner, "Only owner"
    self.is_paused = False

@external
def set_reward_rate(new_rate: uint256):
    """
    @notice Update reward rate
    @param new_rate New reward rate per second
    """
    self._ensure_not_entered()
    assert msg.sender == self.owner, "Only owner"
    assert new_rate <= MAX_REWARD_RATE, "Rate too high"
    
    old_rate: uint256 = self.reward_rate
    self.reward_rate = new_rate
    
    log RateUpdated(old_rate, new_rate, block.timestamp)
    self._exit_reentrancy_guard()

@view
@external
def get_pending_reward(user: address) -> uint256:
    """
    @notice Get pending rewards for a user
    @param user User address
    @return uint256 Pending reward amount
    """
    if self.balances[user] == 0:
        return 0
    
    # Calculate current rewards per token
    current_rewards_per_token: uint256 = self.rewards_per_token_stored
    if self.total_staked > 0:
        time_elapsed: uint256 = block.timestamp - self.last_update_time
        current_rewards_per_token += (time_elapsed * self.reward_rate * DECIMALS) // self.total_staked
    
    # Calculate pending rewards
    return self.rewards[user] + (self.balances[user] * (current_rewards_per_token - self.user_reward_per_token_paid[user])) // DECIMALS 