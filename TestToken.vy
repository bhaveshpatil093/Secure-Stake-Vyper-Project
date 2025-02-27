# @version ^0.4.0

"""
@title Test ERC20 Token
@author Iqbal
@notice A secure ERC20 token with enhanced security features
@dev Added reentrancy protection, overflow checks, and input validation
@custom:acknowledgments 
    - ERC20 standard by Ethereum
    - Vyper language by Vyper Team
"""

from ethereum.ercs import IERC20

implements: IERC20

# Events
event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    value: uint256

event Approval:
    owner: indexed(address)
    spender: indexed(address)
    value: uint256

# State Variables
name: public(String[32])
symbol: public(String[32])
decimals: public(uint8)
totalSupply: public(uint256)
balanceOf: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])
owner: public(address)

# Security settings
MAX_SUPPLY: constant(uint256) = 1_000_000_000 * 10**18  # 1 billion tokens
MAX_TRANSFER: constant(uint256) = 100_000_000 * 10**18  # 100 million tokens per transfer
MIN_TRANSFER: constant(uint256) = 1  # Minimum transfer amount
entered: bool  # Reentrancy guard

@deploy
def __init__():
    """
    @notice Contract constructor with security checks
    """
    self.name = "Test Token"
    self.symbol = "TEST"
    self.decimals = 18
    initial_supply: uint256 = 1_000_000 * 10**18  # 1 million tokens
    assert initial_supply <= MAX_SUPPLY, "Supply exceeds maximum"
    self.totalSupply = initial_supply
    self.balanceOf[msg.sender] = initial_supply
    self.owner = msg.sender
    self.entered = False
    log Transfer(empty(address), msg.sender, initial_supply)

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
def _validate_address(addr: address):
    """
    @notice Validate address is not empty or token contract
    @param addr Address to validate
    """
    assert addr != empty(address), "Invalid address"
    assert addr != self, "Cannot use token contract address"

@internal
def _validate_amount(amount: uint256):
    """
    @notice Validate transfer amount is within bounds
    @param amount Amount to validate
    """
    assert amount >= MIN_TRANSFER, "Amount too small"
    assert amount <= MAX_TRANSFER, "Amount too large"

@external
def transfer(_to: address, _value: uint256) -> bool:
    """
    @notice Transfer tokens with security checks
    @param _to The address to transfer to
    @param _value The amount to be transferred
    @return bool success
    """
    self._ensure_not_entered()
    self._validate_address(_to)
    self._validate_amount(_value)
    
    # Balance checks
    assert self.balanceOf[msg.sender] >= _value, "Insufficient balance"
    new_sender_balance: uint256 = self.balanceOf[msg.sender] - _value
    new_recipient_balance: uint256 = self.balanceOf[_to] + _value
    assert new_recipient_balance >= self.balanceOf[_to], "Overflow check"
    
    # Update balances
    self.balanceOf[msg.sender] = new_sender_balance
    self.balanceOf[_to] = new_recipient_balance
    
    log Transfer(msg.sender, _to, _value)
    self._exit_reentrancy_guard()
    return True

@external
def transferFrom(_from: address, _to: address, _value: uint256) -> bool:
    """
    @notice Transfer tokens from one address to another with security checks
    @param _from address The address to transfer from
    @param _to address The address to transfer to
    @param _value uint256 the amount of tokens to be transferred
    @return bool success
    """
    self._ensure_not_entered()
    self._validate_address(_from)
    self._validate_address(_to)
    self._validate_amount(_value)
    
    # Allowance and balance checks
    assert self.allowance[_from][msg.sender] >= _value, "Insufficient allowance"
    assert self.balanceOf[_from] >= _value, "Insufficient balance"
    
    # Calculate new balances and allowance
    new_from_balance: uint256 = self.balanceOf[_from] - _value
    new_to_balance: uint256 = self.balanceOf[_to] + _value
    new_allowance: uint256 = self.allowance[_from][msg.sender] - _value
    
    # Overflow checks
    assert new_to_balance >= self.balanceOf[_to], "Balance overflow"
    
    # Update state
    self.balanceOf[_from] = new_from_balance
    self.balanceOf[_to] = new_to_balance
    self.allowance[_from][msg.sender] = new_allowance
    
    log Transfer(_from, _to, _value)
    self._exit_reentrancy_guard()
    return True

@external
def approve(_spender: address, _value: uint256) -> bool:
    """
    @notice Approve with security checks and two-step approval process
    @param _spender The address which will spend the funds
    @param _value The amount of tokens to be spent
    @return bool success
    """
    self._ensure_not_entered()
    self._validate_address(_spender)
    assert _value <= MAX_TRANSFER, "Amount too large"
    
    # Require allowance to be 0 before setting new value
    assert self.allowance[msg.sender][_spender] == 0 or _value == 0, "Reset allowance to 0 first"
    
    self.allowance[msg.sender][_spender] = _value
    log Approval(msg.sender, _spender, _value)
    self._exit_reentrancy_guard()
    return True

@external
def mint(_to: address, _value: uint256) -> bool:
    """
    @notice Mint new tokens with security checks
    @param _to The address that will receive the minted tokens
    @param _value The amount of tokens to mint
    @return bool success
    """
    self._ensure_not_entered()
    assert msg.sender == self.owner, "Only owner can mint"
    self._validate_address(_to)
    assert _value <= MAX_TRANSFER, "Amount too large"
    
    # Supply checks
    new_total_supply: uint256 = self.totalSupply + _value
    assert new_total_supply <= MAX_SUPPLY, "Exceeds maximum supply"
    assert new_total_supply >= self.totalSupply, "Supply overflow"
    
    # Balance checks
    new_balance: uint256 = self.balanceOf[_to] + _value
    assert new_balance >= self.balanceOf[_to], "Balance overflow"
    
    # Update state
    self.totalSupply = new_total_supply
    self.balanceOf[_to] = new_balance
    
    log Transfer(empty(address), _to, _value)
    self._exit_reentrancy_guard()
    return True 