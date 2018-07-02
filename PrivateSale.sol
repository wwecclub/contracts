pragma solidity ^0.4.18;
import './Utils.sol';
import './SmartToken.sol';
import './Owned.sol';

/*
    PrivateSale v0.1
*/
contract PrivateSale is Utils, Owned {

    // infomation about this sale
    bytes public constant infomation = "WWEC, 1st Crowdsale";
    uint16 public period = 1;

    uint256 public constant MAX_GAS_PRICE = 50000000000 wei;   // maximum gas price for contribution transactions
    uint256 public constant TOTAL_TOKEN_CAP = 1000000000 ether;       // total token cap

    /**
        true means private sale, false means crowd sale
        if both this and 'should freeze' equals true, user can receive the token only after the audit is passed
    */
    bool public constant SHOULD_REVIEW = false;

    // initial data
    uint256 public startTime = 0;                   // private sale start time (unix timestamp). Don't set this argument manually, It will be set in constructor function
    uint256 public endTime = 0;                     // private sale end time (unix timestamp). Don't set this argument manually, It will be set in constructor function

    uint256 public lastCircle = 2;                  // last circle of sale ,must greater than 1
    uint256 public circleSecs = 7 days;                // seconds per circle. If you wish 1 week per circle, set this to 7 * 86400
    uint256 public frozenTime = 0;                // frozen time after sale(uint seconds). Usually set '180 days'.

    uint256 public tokenPriceN = 1;                 // initial price  (numerator)
    uint256 public tokenPriceD = 35000;                // initial price  (denominator)
    uint256 public attenuationCoefficient0 = 100;     // attenuation Coefficient for the first circle of sale. Usually set 100.
    uint256 public attenuationCoefficient = 80;       // attenuation Coefficient for the last circle of sale. range (0, 100]

    uint256 public maxBuy = 100000000 ether;            // max buy token amount, unit wei
    uint256 public minBuy = 10000 ether;                // min buy token amount, unit wei
    uint256 public giftCoefficient = 0;              // gift coefficient for users
    address public officialAddress = 0xC91087bc864f217FBdf82B1F9958a0068B823932;    // official address for receive ETH
    address public partnerAddress = 0xa44A784C17152dbf099D46558Ae0CE60b9396fdB;     // partner address for receive ETH
    uint256 public partnerCoefficient = 7;          // partners can get the coefficient of ETH
    uint256 public partnerEthLimit = 0;              // limit eth that partner can receive. 0 means unlimit（unit wei)

    //frozen and release
    bool public shouldFreeze = true;                 // if freeze token.
    uint256 public releaseCircle = 8;                // release circle (unit seconds) 0 means release all after frozen time immediately
    uint256 public secsPerReleaseCircle = 7 days;         // seconds per each release circle, this value should not set to 0 if releaseCircle > 0

    // statistics
    uint256 public totalEtherContributed = 0;       // ether contributed so far
    uint256 public totalSoldToken = 0;              // total sold token number
    uint256 public partnerEthReceived = 0;          // total ether that partner received

    SmartToken public token;

    // storage data
    mapping (address => uint256) public frozenBalance;     // before frozen time, all token will be storage here
    mapping (address => uint256) public totalGetToken;     // record how many token that user got in this period of sale
    mapping (address => bool) public approved;             // the person who is be approved to buy token
    mapping (address => uint256) public boughtNum;         // Number of token that one bought already

    // state of contract
    enum State {Initialized, Sale, Closed, Frozen}
    State public state;

    // triggered on each contribution
    event Contribution(address indexed _contributor, uint256 _amount, uint256 _return);
    event StateChange(uint _timestamp, State _state);
    event Reviewed(address indexed _approved);

    /**
        @dev constructor

        @param _period         period of sale
        @param _token          smart token address
        @param _startTime      private sale start time
        @param _shouldFreeze   if freeze token
    */
    function PrivateSale(uint16 _period, SmartToken _token, uint256 _startTime, bool _shouldFreeze)
        public
        earlierThan(_startTime)
    {
        period = _period;
        token = SmartToken(_token);
        startTime = _startTime;
        endTime = startTime + lastCircle * circleSecs;
        state = State.Initialized;
        shouldFreeze = _shouldFreeze;
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

    //Valid if the state is right
    modifier validState(State _state) {
        assert(state == _state);
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
        validAddress(officialAddress)
        validGasPrice
    {
        // how mayn token user can buy as the default price
        uint256 boughtTokenAmount = safeMul(msg.value, tokenPriceD) / tokenPriceN;

        // how many token user can buy with the attenuation coefficient
        /* boughtTokenAmount = safeMul(boughtTokenAmount, attenuationCoefficient) / attenuationCoefficient0; */
        boughtTokenAmount = calc(boughtTokenAmount);
        assert(boughtTokenAmount >= minBuy);

        // check if reach the max token amount that one can buy
        uint256 newBoughtTokenNum = safeAdd(boughtTokenAmount, boughtNum[msg.sender]);
        assert(newBoughtTokenNum <= maxBuy);
        boughtNum[msg.sender] = newBoughtTokenNum;

        // calculate how many token user can get finally
        uint256 giftTokenNum = safeMul(boughtTokenAmount, giftCoefficient)/100;
        uint256 totalGet = safeAdd(giftTokenNum, boughtTokenAmount);

        // check if reach total token this period offered
        assert(safeAdd(totalSoldToken, totalGet) <= TOTAL_TOKEN_CAP);
        totalSoldToken = safeAdd(totalSoldToken, totalGet);

        // send ether to official and partner
        if (partnerCoefficient == 0){
            officialAddress.transfer(msg.value);
        }else{

            uint256 _partnerEth = safeMul(msg.value, partnerCoefficient) / 100;

            if (partnerEthLimit > 0){
                if (safeAdd(_partnerEth, partnerEthReceived) > partnerEthLimit){
                    _partnerEth = safeSub(partnerEthLimit, partnerEthReceived);
                }
            }

            if (partnerAddress != address(0)){
                partnerAddress.transfer(_partnerEth);
                partnerEthReceived = safeAdd(partnerEthReceived, _partnerEth);
                officialAddress.transfer(safeSub(msg.value, _partnerEth));
            }else{
                officialAddress.transfer(msg.value);
            }
        }

        if (shouldFreeze == true){
            frozenBalance[msg.sender] = safeAdd(totalGet, frozenBalance[msg.sender]);
            totalGetToken[msg.sender] = safeAdd(totalGet, totalGetToken[msg.sender]);
        }else{
            assert(token.transfer(msg.sender, totalGet));
        }

        totalEtherContributed = safeAdd(totalEtherContributed, msg.value); // update the total contribution amount
        emit Contribution(msg.sender, msg.value, boughtTokenAmount);
    }

    /**
        @dev calculate attenuation coefficient of current week

        UserReceivedTokenNum  =  UserSendEthNum  *  StandandTokenNum * α

        StandandTokenNum: the token number that 1 ETH can buy

        α = α0 - (w - 1 ) / (TotalWeekNum - 1) * （α0 - α1）

        α = attenuation coefficient of current week
        w = Weeks after the start of crowdsale
        TotalWeekNum = lastCircle
        α0 = attenuationCoefficient0
        α1 = attenuationCoefficient
    */

    function calc(uint256 _boughtTokenAmount) private returns (uint256) {
        uint256 _circle = safeSub(now, startTime);
        _circle =  safeAdd(_circle / circleSecs, 1);

        if(_circle == 0){
            return _boughtTokenAmount;
        }else{
            uint256 _d = safeMul(100 , safeSub(lastCircle, 1));
            uint256 _n = safeSub(_d, safeMul(safeSub(_circle, 1), safeSub(attenuationCoefficient0 ,attenuationCoefficient)));
            return safeMul(_boughtTokenAmount, _n)/_d;
        }
    }

    /**
        @dev send frozen token to it's owner after frozen time

        @return bool if succeed
    */
    function getToken() public
        greaterThan(now, endTime + frozenTime)
        validState(State.Closed)
        validGasPrice
    {
        require(frozenBalance[msg.sender] > 0);

        if (SHOULD_REVIEW == true){
            if(approved[msg.sender] == false) revert();
        }

        if (releaseCircle == 0){
            assert(token.transfer(msg.sender, frozenBalance[msg.sender]));
            frozenBalance[msg.sender] = 0;
        }else{
            uint256 _circle = safeSub(now, endTime + frozenTime) / secsPerReleaseCircle + 1;

            if (_circle > releaseCircle){
                _circle = releaseCircle;
            }

            uint256 releaseAmount = safeMul(totalGetToken[msg.sender],  _circle)/releaseCircle;
            uint256 releasedAmount = safeSub(totalGetToken[msg.sender], frozenBalance[msg.sender]);

            // if user has get all release token
            if (releasedAmount ==  releaseAmount) revert();
            releaseAmount = safeSub(releaseAmount, releasedAmount);

            assert(token.transfer(msg.sender, releaseAmount));
            frozenBalance[msg.sender] = safeSub(frozenBalance[msg.sender], releaseAmount);
        }
    }

    // modify arguments

    // set gift token coefficient
    function setGiftCoefficient(uint256 _giftCoefficient)
        public
        ownerOnly
    {
        giftCoefficient = _giftCoefficient;
    }

    // set token pricce
    function setPrice(uint256 _tokenPriceN, uint256 _tokenPriceD)
        public
        ownerOnly
    {
        tokenPriceN = _tokenPriceN;
        tokenPriceD = _tokenPriceD;
    }

    // set address for receive ETH, Only call in case of emergency
    function setAddress(address _officialAddress, address _partnerAddress, uint256 _partnerCoefficient)
        public
        ownerOnly
        validAddress(_officialAddress)
        validAddress(_partnerAddress)
    {
        require(_partnerCoefficient < 100);
        officialAddress = _officialAddress;
        partnerAddress = _partnerAddress;
        partnerCoefficient = _partnerCoefficient;
    }

    // set sale last circle
    function setLastCircle(uint256 _lastCircle)
        public
        ownerOnly
    {
        uint256 newEndTime = startTime +  _lastCircle * circleSecs;
        assert(now < newEndTime);
        lastCircle = _lastCircle;
        endTime = newEndTime;
    }

    function setAttenuationCoefficient(uint256 _c)
        public
        ownerOnly
    {
        require(_c < 100);
        attenuationCoefficient = _c;
    }

    // release one's token
    function releaseToken(address _address)
        public
        ownerOnly
    {
        require(frozenBalance[_address] > 0);
        assert(token.transfer(_address, frozenBalance[_address]));
        frozenBalance[_address] = 0;
    }

    // buyToken
    function buyToken() payable public {
        processContribution();
    }

    // fallback
    function() payable public {
        processContribution();
    }

}
