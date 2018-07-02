pragma solidity ^0.4.18;
import './Utils.sol';
import './SmartToken.sol';
import './Owned.sol';

/*
    PrivateSale v0.1
*/
contract PrivateSaleProd is Utils, Owned {

    // control arguments before deploy contract
    uint256 public constant DURATION = 38 days;                 // private sale duration
    uint256 public constant TOKEN_PRICE_N = 1;                  // initial price in wei (numerator)
    uint256 public constant TOKEN_PRICE_D = 300;                // initial price in wei (denominator)
    uint256 public constant MAX_GAS_PRICE = 50000000000 wei;    // maximum gas price for contribution transactions
    uint256 public constant MAX_BUY_AMOUNT = 593 ether;         // maximum buy amount
    uint256 public constant MIN_BUY_AMOUNT = 3 ether;           // minimum buy amount
    uint256 public constant FROZEN_TIME = 300 days;             // frozen time
    uint256 public constant TOTAL_ETHER_CAP = 5934 ether;       // total ether cap

    uint256 public MAX_TOKEN_PER_ACCOUNT;                       // max token that one can buy

    uint16 public period = 0;

    // initial data
    uint256 public startTime = 0;                   // private sale start time (in seconds)
    uint256 public endTime = 0;                     // private sale end time (in seconds)
    uint256 public totalEtherContributed = 0;       // ether contributed so far
    address public beneficiary = address(0);        // address to receive all ether contributions

    SmartToken public token;

    // storage data
    mapping (address => uint256) public frozenBalance;     // before frozen time, all data will be storage here
    mapping (address => bool) public approved;             //the person that be approved to buy token

    // state of contract
    enum State {Initialized, Sale, Closed, Frozen}
    State public state;

    // triggered on each contribution
    event Contribution(address indexed _contributor, uint256 _amount, uint256 _return);
    event StateChange(uint _timestamp, State _state);
    event Reviewed(address indexed _approved);

    /**
        @dev constructor

        @param _token          smart token address
        @param _startTime      private sale start time
        @param _beneficiary    address to receive all ether contributions
    */
    function PrivateSaleProd(uint16 _period, SmartToken _token, uint256 _startTime, address _beneficiary)
        public
        validAddress(_beneficiary)
        earlierThan(_startTime)
    {
        period = _period;
        token = SmartToken(_token);
        startTime = _startTime;
        endTime = startTime + DURATION;
        beneficiary = _beneficiary;
        state = State.Initialized;
        MAX_TOKEN_PER_ACCOUNT = safeMul(MAX_BUY_AMOUNT, TOKEN_PRICE_D)/TOKEN_PRICE_N;
    }

    // verifies that the gas price is lower than 50 gwei
    modifier validGasPrice() {
        assert(tx.gasprice <= MAX_GAS_PRICE);
        _;
    }

    // ensures that it's earlier than the given time
    modifier earlierThan(uint256 _time) {
        assert(now < _time);
        _;
    }

    // ensures that the current time is between _startTime (inclusive) and _endTime (exclusive)
    modifier between(uint256 _startTime, uint256 _endTime) {
        assert(now >= _startTime && now < _endTime);
        _;
    }

    // ensures that we didn't reach the ether cap
    modifier etherCapNotReached(uint256 _contribution) {
        assert(safeAdd(totalEtherContributed, _contribution) <= TOTAL_ETHER_CAP);
        _;
    }

    //Valid if the state is right
    modifier validState(State _state) {
        assert(state == _state);
        _;
    }

    //Valid address has qualification to buy token
    modifier validQualification() {
        assert(approved[msg.sender] == true);
        _;
    }

    /**
        @dev internal function to change state

        @param _state the next state to turn to
    */
    function changeState(State _state) private{
        state = _state;
        emit StateChange(now, state);
    }

    /**
        @dev start sale
    */
    function startSale() public
        validState(State.Initialized)
        ownerOnly
        returns(bool)
    {
        changeState(State.Sale);
        return true;
    }

    /**
        @dev close sale then start review
    */
    function closeSale() public
        validState(State.Sale)
        ownerOnly
        returns(bool)
    {
        changeState(State.Closed);
        return true;
    }

    /**
        @dev review
    */
    function review(address[] _approvedAddr) public
        validState(State.Closed)
        ownerOnly
        returns(bool)
    {
        uint8 i;
        for(i = 0; i < _approvedAddr.length; i++)
        {
            approved[_approvedAddr[i]] = true;
            emit Reviewed(_approvedAddr[i]);
        }
        return true;
    }

    /**
        @dev handles contribution logic

        @return total frozen token
    */
    function processContribution() private
        between(startTime, endTime)
        validState(State.Sale)
        etherCapNotReached(msg.value)
        greaterThan(msg.value, MIN_BUY_AMOUNT)
        validGasPrice
        returns (uint256 amount)
    {
        uint256 tokenAmount = safeMul(msg.value, TOKEN_PRICE_D) / TOKEN_PRICE_N;
        uint256 newTokenAmount = safeAdd(tokenAmount, frozenBalance[msg.sender]);
        assert(newTokenAmount <= MAX_TOKEN_PER_ACCOUNT );
        beneficiary.transfer(msg.value); // transfer the ether to the beneficiary account
        totalEtherContributed = safeAdd(totalEtherContributed, msg.value); // update the total contribution amount
        frozenBalance[msg.sender] = newTokenAmount;
        emit Contribution(msg.sender, msg.value, tokenAmount);
        return newTokenAmount;
    }

    /**
        @dev send frozen token to it's owner after frozen time

        @return bool if succeed
    */
    function getToken() public
        greaterThan(now, endTime + FROZEN_TIME)
        validState(State.Closed)
        validQualification
        validGasPrice
        returns (bool)
    {
        require(frozenBalance[msg.sender] > 0);
        token.transfer(msg.sender, frozenBalance[msg.sender]);
        frozenBalance[msg.sender] = 0;
        return true;
    }

    // fallback
    function() payable public {
        processContribution();
    }
}
