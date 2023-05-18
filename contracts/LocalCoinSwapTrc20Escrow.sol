// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ITRC20.sol";

contract LocalCoinSwapTrc20Escrow {

  address public arbitrator;
  address public owner;
  address public withdrawer;
  address payable withdrawTo;
  address public relayer;

  struct Escrow {
    bool exists;
    address token;
  }

  mapping(bytes32 => Escrow) public escrows;
  mapping(address => uint256) public collectedFees;

  /***********************
    +     Instructions     +
    ***********************/

  uint8 private constant RELEASE_ESCROW = 0x01;
  uint8 private constant BUYER_CANCELS = 0x02;
  uint8 private constant RESOLVE_DISPUTE = 0x03;

  /***********************
    +       Events        +
    ***********************/

  event Created(bytes32 indexed tradeHash);
  event Cancelled(bytes32 indexed tradeHash);
  event Released(bytes32 indexed tradeHash);
  event DisputeResolved(bytes32 indexed tradeHash);

  constructor(address initialAddress) payable {
    owner = initialAddress;
    arbitrator = initialAddress;
    relayer = initialAddress;
    withdrawer = initialAddress;
    withdrawTo = payable(initialAddress);
  }

  /***********************
    +     Open Escrow     +
    ***********************/

  function createEscrow(
    bytes32 _tradeHash,
    address _tokenAddress,
    uint256 _value,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) external payable {
    require(!escrows[_tradeHash].exists, "Escrow already exists");
    require(_value > 1000, "Escrow value too small");

    bytes32 _invitationHash = keccak256(abi.encodePacked(_tradeHash));
    require(
      recoverAddress(_invitationHash, _v, _r, _s) == relayer,
      "Signature not from relayer"
    );

    ITRC20(_tokenAddress).transferFrom(msg.sender, address(this), _value);

    escrows[_tradeHash] = Escrow(true, _tokenAddress);
    emit Created(_tradeHash);
  }

  /***********************
    +   Complete Escrow    +
    ***********************/

  function doRelease(
    bytes16 _tradeID,
    address payable _seller,
    address payable _buyer,
    uint256 _value,
    uint256 _txFee,
    uint256 _lcsFee
  ) private {
    Escrow memory _escrow;
    bytes32 _tradeHash;
    (_escrow, _tradeHash) = getEscrowAndHash(
      _tradeID,
      _seller,
      _buyer,
      _value,
      _lcsFee
    );
    require(_escrow.exists, "Escrow does not exist");
    delete escrows[_tradeHash];
    transferMinusFees(_escrow.token, _buyer, _value, _txFee, _lcsFee);
    emit Released(_tradeHash);
  }

  function resolveDispute(
    bytes16 _tradeID,
    address payable _seller,
    address payable _buyer,
    uint256 _value,
    uint256 _txFee,
    uint256 _lcsFee,
    uint8 _v,
    bytes32 _r,
    bytes32 _s,
    uint8 _winner
  ) external onlyArbitrator {
    address _signature = recoverAddress(
      keccak256(abi.encodePacked(_tradeID, RESOLVE_DISPUTE)),
      _v,
      _r,
      _s
    );
    require(
      _signature == _buyer || _signature == _seller,
      "Must be buyer or seller"
    );

    Escrow memory _escrow;
    bytes32 _tradeHash;
    (_escrow, _tradeHash) = getEscrowAndHash(
      _tradeID,
      _seller,
      _buyer,
      _value,
      _lcsFee
    );
    require(_escrow.exists, "Escrow does not exist");
    delete escrows[_tradeHash];

    // _winner: 1 means seller, 2 means buyer
    if (_winner == 2) {
      transferMinusFees(_escrow.token, _buyer, _value, _txFee, _lcsFee);
    }
    if (_winner == 1) {
      transferMinusFees(_escrow.token, _seller, _value, _txFee, 0);
    }
    emit DisputeResolved(_tradeHash);
  }

  function doBuyerCancel(
    bytes16 _tradeID,
    address payable _seller,
    address payable _buyer,
    uint256 _value,
    uint256 _txFee,
    uint256 _lcsFee
  ) private {
    Escrow memory _escrow;
    bytes32 _tradeHash;
    (_escrow, _tradeHash) = getEscrowAndHash(
      _tradeID,
      _seller,
      _buyer,
      _value,
      _lcsFee
    );
    require(_escrow.exists, "Escrow does not exist");
    delete escrows[_tradeHash];
    transferMinusFees(_escrow.token, _seller, _value, _txFee, 0);
    emit Cancelled(_tradeHash);
  }

  /***********************
    +        Relays        +
    ***********************/

  function relay(
    bytes16 _tradeID,
    address payable _seller,
    address payable _buyer,
    uint256 _value,
    uint256 _txFee,
    uint256 _lcsFee,
    uint8 _v,
    bytes32 _r,
    bytes32 _s,
    uint8 _instructionByte
  ) public {
    address _relayedSender = getRelayedSender(
      _tradeID,
      _instructionByte,
      _v,
      _r,
      _s
    );
    if (_relayedSender == _buyer) {
      if (_instructionByte == BUYER_CANCELS) {
        doBuyerCancel(_tradeID, _seller, _buyer, _value, _txFee, _lcsFee);
      }
    } else if (_relayedSender == _seller) {
      if (_instructionByte == RELEASE_ESCROW) {
        doRelease(_tradeID, _seller, _buyer, _value, _txFee, _lcsFee);
      }
    } else {
      require(msg.sender == _seller, "Unrecognised party");
    }
  }

  function transferMinusFees(
    address _tokenAddress,
    address payable _to,
    uint256 _value,
    uint256 _txFee,
    uint256 _lcsFee
  ) private {
    uint256 _fee = _txFee + _lcsFee;
    require(_value > _fee, "Fee more than value");
    uint256 _takerAmount = _value - _fee;
    collectedFees[_tokenAddress] += _fee;
    ITRC20(_tokenAddress).transfer(_to, _takerAmount);
  }

  function getRelayedSender(
    bytes16 _tradeID,
    uint8 _instructionByte,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) private pure returns (address) {
    bytes32 _hash = keccak256(
      abi.encodePacked(_tradeID, _instructionByte)
    );
    return recoverAddress(_hash, _v, _r, _s);
  }

  function getEscrowAndHash(
    bytes16 _tradeID,
    address _seller,
    address _buyer,
    uint256 _value,
    uint256 _lcsFee
  ) private view returns (Escrow storage, bytes32) {
    bytes32 _tradeHash = keccak256(
      abi.encodePacked(_tradeID, _seller, _buyer, _value, _lcsFee)
    );
    return (escrows[_tradeHash], _tradeHash);
  }

  function recoverAddress(
    bytes32 _h,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) private pure returns (address) {
    bytes memory _prefix = "\x19Ethereum Signed Message:\n32";
    bytes32 _prefixedHash = keccak256(abi.encodePacked(_prefix, _h));
    return ecrecover(_prefixedHash, _v, _r, _s);
  }

  /// @notice Withdraw fees collected by the contract. Only the owner can call this.
  /// @param _to Address to withdraw fees in to
  /// @param _amount Amount to withdraw
  function withdrawFees(address payable _to, address _tokenAddress, uint256 _amount)
    external
    onlyOwner
  {
    // This check also prevents underflow
    require(_amount <= collectedFees[_tokenAddress], "Amount is higher than amount available");
    collectedFees[_tokenAddress] -= _amount;
    ITRC20(_tokenAddress).transfer(_to, _amount);
  }

  function sweepFees(address _tokenAddress, uint256 _amount)
    external
    onlyWithdrawer
  {
    require(_amount <= collectedFees[_tokenAddress], "Amount is higher than amount available");
    collectedFees[_tokenAddress] -= _amount;
    ITRC20(_tokenAddress).transfer(withdrawTo, _amount);
  }

  /***********************
    + Staff and Management +
    ***********************/

  modifier onlyOwner() {
    require(msg.sender == owner, "Only the owner can do this");
    _;
  }

  modifier onlyArbitrator() {
    require(msg.sender == arbitrator, "Only the arbitrator can do this");
    _;
  }

  modifier onlyWithdrawer() {
    require(msg.sender == withdrawer, "Only the withdrawer can do this");
    _;
  }

  function setArbitrator(address _newArbitrator) external onlyOwner {
    arbitrator = _newArbitrator;
  }

  function setOwner(address _newOwner) external onlyOwner {
    owner = _newOwner;
  }

  function setRelayer(address _newRelayer) external onlyOwner {
    relayer = _newRelayer;
  }

  function setWithdrawer(address _newWithdrawer) external onlyOwner {
    withdrawer = _newWithdrawer;
  }

  function setWithdrawalAddress(address _newAddress) external onlyOwner {
    withdrawTo = payable(_newAddress);
  }
}
