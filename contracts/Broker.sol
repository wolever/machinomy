pragma solidity ^0.4.4;

contract Owned {
    address owner;

    function Owned () {
        owner = msg.sender;        
    }
}

contract Mortal is Owned {
    function kill() {
        if (msg.sender == owner) selfdestruct(owner);
    }
}

contract Broker is Mortal {
    enum ChannelState { Open, Settling, Settled }

    struct PaymentChannel {
        address sender;
        address receiver;
        uint256 value;

        uint settlementPeriod;

        ChannelState state;
        /* until state is invalid */
        uint until;

        uint256 payment;
    }

    mapping(bytes32 => PaymentChannel) channels;
    uint32 chainId;
    uint32 id;

    event DidCreateChannel(address indexed sender, address indexed receiver, bytes32 channelId);
    event DidDeposit(bytes32 indexed channelId, uint256 value);
    event DidStartSettle(bytes32 indexed channelId, uint256 payment);
    event DidSettle(bytes32 indexed channelId, uint256 payment, uint256 oddValue);

    function Broker(uint32 _chainId) {
        chainId = _chainId;
        id = 0;
    }

    /******** ACTIONS ********/

    /* Create payment channel */
    function createChannel(address receiver, uint duration, uint settlementPeriod) public payable returns(bytes32) {
        var channelId = sha3(id++);
        var sender = msg.sender;
        var value = msg.value;
        channels[channelId] =
          PaymentChannel(sender, receiver, value, settlementPeriod, ChannelState.Open, block.timestamp + duration, 0);

        DidCreateChannel(sender, receiver, channelId);

        return channelId;
    }

    /* Add funds to the channel */
    function deposit(bytes32 channelId) public payable {
        if (!canDeposit(msg.sender, channelId)) throw;

        var channel = channels[channelId];
        channel.value += msg.value;

        DidDeposit(channelId, msg.value);
    }

    /* Receiver settles channel */
    function claim(bytes32 channelId, uint256 payment, uint8 sigV, bytes32 sigR, bytes32 sigS) public {
        if (!canClaim(msg.sender, channelId, payment, sigV, sigR, sigS))
            return;

        settle(channelId, payment);
    }

    /* Sender starts settling */
    function startSettle(bytes32 channelId, uint256 payment) public {
        if (!canStartSettle(msg.sender, channelId)) throw;
        var channel = channels[channelId];
        channel.state = ChannelState.Settling;
        channel.until = now + channel.settlementPeriod;
        channel.payment = payment;
        DidStartSettle(channelId, payment);
    }

    /* Sender settles the channel, if receiver have not done that */
    function finishSettle(bytes32 channelId) public {
      if (!canFinishSettle(msg.sender, channelId)) throw;
      settle(channelId, channels[channelId].payment);
    }

    function close(bytes32 channelId) {
        var channel = channels[channelId];
        if (channel.state == ChannelState.Settled && (msg.sender == owner || msg.sender == channel.sender || msg.sender == channel.receiver)) {
            if (channel.value > 0) {
                if (!channel.sender.send(channel.value)) throw;
            }
            delete channels[channelId];
        }
    }

    /******** BEHIND THE SCENES ********/

    function settle(bytes32 channelId, uint256 payment) {
      var channel = channels[channelId];
      uint256 paid = payment;
      uint256 oddMoney = 0;

      if (payment > channel.value) {
        paid = channel.value;
        if (!channel.receiver.send(paid)) throw;
      } else {
        if (!channel.receiver.send(paid)) throw;
        oddMoney = channel.value - paid;
        if (!channel.sender.send(oddMoney)) throw;
        channel.value = 0;
      }

      channels[channelId].state = ChannelState.Settled;
      DidSettle(channelId, payment, oddMoney);
    }

    /******** CAN CHECKS ********/

    function canDeposit(address sender, bytes32 channelId) constant returns(bool) {
        var channel = channels[channelId]; 
        // DW: Do we really need to check that only the sender is allowed to
        //     deposit?
        return channel.state == ChannelState.Open &&
            channel.sender == sender;
    }

    function canClaim(address sender, bytes32 channelId, uint256 payment, uint8 sigV, bytes32 sigR, bytes32 sigS) private constant returns(bool) {
        var channel = channels[channelId];
        if (!(channel.state == ChannelState.Open || channel.state == ChannelState.Settling))
            return false;

        // Only the channel's recipient can make an immediate claim
        if (sender != channel.receiver)
            return false;

        return isStateUpdateSigValid(
            sender,
            chainId, address(this), channelId,
            payment,
            sigV, sigR, sigS
        );
    }

    function isStateUpdateSigValid(
        address sender,
        uint32 chainId, address contractId, bytes32 channelId,
        uint256 payment,
        uint8 sigV, bytes32 sigR, bytes32 sigS
    ) public returns(bool) {
        var actualHash = sha256(
            chainId, contractId, channelId,
            payment
        );

        return (sender == ecrecover(actualHash, sigV, sigR, sigS));
    }

    function canStartSettle(address sender, bytes32 channelId) constant returns(bool) {
        var channel = channels[channelId];
        return channel.state == ChannelState.Open &&
            channel.sender == sender;
    }

    function canFinishSettle(address sender, bytes32 channelId) constant returns(bool) {
        var channel = channels[channelId];
        return channel.state == ChannelState.Settling &&
            (sender == channel.sender || sender == owner) &&
            channel.until >= now;
    }

    /******** READERS ********/

    function getState(bytes32 channelId) constant returns(ChannelState) {
        return channels[channelId].state;
    }

    function getUntil(bytes32 channelId) constant returns(uint) {
        return channels[channelId].until;
    }

    function getPayment(bytes32 channelId) constant returns(uint) {
        return channels[channelId].payment;        
    }

    function isOpenChannel(bytes32 channelId) constant returns(bool) {
        var channel = channels[channelId];
        return channel.state == ChannelState.Open && channel.until >= now;
    }
}
