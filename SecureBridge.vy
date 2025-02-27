# @version ^0.4.0

"""
@title SecureBridge Contract v1.0
@author Your Assistant
@notice A multi-signature token transfer validation contract
@dev Implements multi-validator approval, timelock, and basic security features
"""

from ethereum.ercs import IERC20

# Security settings
TIMELOCK_PERIOD: constant(uint256) = 3600  # 1 hour
MAX_VALIDATORS: constant(uint256) = 10
MIN_THRESHOLD: constant(uint256) = 2
MIN_TRANSFER_AMOUNT: constant(uint256) = 1000
MAX_TRANSFER_AMOUNT: constant(uint256) = 1000000000000000000000000  # 1M tokens

# Events
event ValidatorAdded:
    validator: indexed(address)

event ValidatorRemoved:
    validator: indexed(address)

event BridgeInitiated:
    token: indexed(address)
    sender: indexed(address)
    recipient: indexed(address)
    amount: uint256
    target_chain: uint256

event TransferValidated:
    hash: indexed(bytes32)
    validator: indexed(address)

event TransferProcessed:
    hash: indexed(bytes32)
    token: indexed(address)
    recipient: indexed(address)
    amount: uint256

# State Variables
owner: public(address)
validators: public(HashMap[address, bool])
validator_count: public(uint256)
validation_threshold: public(uint256)
current_chain_id: public(uint256)  # Used for transfer identification

# Transfer state tracking
validator_signatures: HashMap[bytes32, HashMap[address, bool]]
signature_counts: HashMap[bytes32, uint256]
processed_transfers: HashMap[bytes32, bool]
transfer_timelock: HashMap[bytes32, uint256]

# Basic security state
is_paused: public(bool)
entered: bool  # Reentrancy guard

@deploy
def __init__(_chain_id: uint256, _threshold: uint256):
    """
    @notice Initialize the validation contract
    @param _chain_id Identifier for transfer source
    @param _threshold Required number of validator signatures
    """
    assert _chain_id > 0, "Invalid chain ID"
    assert _threshold >= MIN_THRESHOLD, "Threshold too low"
    assert _threshold <= MAX_VALIDATORS, "Threshold too high"
    
    self.owner = msg.sender
    self.current_chain_id = _chain_id
    self.validation_threshold = _threshold
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

@external
def add_validator(validator: address):
    """
    @notice Add a new validator
    @param validator Validator address to add
    """
    assert msg.sender == self.owner, "Only owner"
    assert validator != empty(address), "Invalid validator"
    assert not self.validators[validator], "Already validator"
    assert self.validator_count < MAX_VALIDATORS, "Too many validators"
    
    self.validators[validator] = True
    self.validator_count += 1
    log ValidatorAdded(validator)

@external
def remove_validator(validator: address):
    """
    @notice Remove a validator
    @param validator Validator address to remove
    """
    assert msg.sender == self.owner, "Only owner"
    assert self.validators[validator], "Not validator"
    assert self.validator_count > self.validation_threshold, "Too few validators"
    
    self.validators[validator] = False
    self.validator_count -= 1
    log ValidatorRemoved(validator)

@external
def bridge_tokens(token: address, amount: uint256, recipient: address, target_chain: uint256):
    """
    @notice Initiate a validated token transfer
    @param token Token address to transfer
    @param amount Amount of tokens to transfer
    @param recipient Recipient of the transfer
    @param target_chain Identifier for transfer tracking
    """
    self._ensure_not_entered()
    assert not self.is_paused, "Contract is paused"
    assert amount >= MIN_TRANSFER_AMOUNT, "Amount too small"
    assert amount <= MAX_TRANSFER_AMOUNT, "Amount too large"
    assert recipient != empty(address), "Invalid recipient"
    assert token.is_contract, "Token must be a contract"
    
    # Generate transfer hash
    transfer_hash: bytes32 = keccak256(
        concat(
            convert(token, bytes32),
            convert(msg.sender, bytes32),
            convert(recipient, bytes32),
            convert(amount, bytes32),
            convert(target_chain, bytes32)
        )
    )
    
    # Set timelock and lock tokens
    self.transfer_timelock[transfer_hash] = block.timestamp
    
    # Transfer tokens after state changes
    success: bool = extcall IERC20(token).transferFrom(msg.sender, self, amount)
    assert success, "Transfer failed"
    
    log BridgeInitiated(token, msg.sender, recipient, amount, target_chain)
    self._exit_reentrancy_guard()

@external
def validate_transfer(hash: bytes32):
    """
    @notice Validate a transfer
    @param hash Transfer hash
    """
    assert not self.is_paused, "Contract is paused"
    assert self.validators[msg.sender], "Not validator"
    assert not self.validator_signatures[hash][msg.sender], "Already validated"
    assert not self.processed_transfers[hash], "Already processed"
    
    self.validator_signatures[hash][msg.sender] = True
    self.signature_counts[hash] += 1
    
    log TransferValidated(hash, msg.sender)

@external
def process_transfer(hash: bytes32, token: address, recipient: address, amount: uint256):
    """
    @notice Process a validated transfer
    @param hash Transfer hash
    @param token Token address
    @param recipient Recipient address
    @param amount Amount to transfer
    """
    self._ensure_not_entered()
    assert not self.is_paused, "Contract is paused"
    assert not self.processed_transfers[hash], "Already processed"
    assert self.signature_counts[hash] >= self.validation_threshold, "Insufficient signatures"
    assert block.timestamp >= self.transfer_timelock[hash] + TIMELOCK_PERIOD, "Timelock active"
    assert token.is_contract, "Token must be a contract"
    
    # Mark as processed before transfer
    self.processed_transfers[hash] = True
    
    # Transfer tokens after state changes
    success: bool = extcall IERC20(token).transfer(recipient, amount)
    assert success, "Transfer failed"
    
    log TransferProcessed(hash, token, recipient, amount)
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