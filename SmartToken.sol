pragma solidity ^0.4.18;

import './ERC20Token.sol';
import './TokenHolder.sol';
import './Owned.sol';
import './interfaces/ISmartToken.sol';

/*
    Smart Token v0.3

    'Owned' is specified here for readability reasons
*/
contract SmartToken is ISmartToken, Owned, ERC20Token, TokenHolder {
    string public version = '0.3';
    bool public transfersEnabled = true;    // true if transfer/transferFrom are enabled, false if not

    mapping (address => bool) isFrozen;
    uint256 public constant MAX_SUPPLY = 10000000000000000000000000000; // ten billion

    // triggered when a smart token is deployed - the _token address is defined for forward compatibility, in case we want to trigger the event from a factory
    event NewSmartToken(address _token);
    // triggered when the total supply is increased
    event Issuance(uint256 _amount);
    // triggered when the total supply is decreased
    event Destruction(uint256 _amount);

    /**
        @dev constructor

        @param _name       token namez
        @param _symbol     token short symbol, minimum 1 character
    */
    function SmartToken(string _name, string _symbol)
        public
        ERC20Token(_name, _symbol, 18)
    {
        emit NewSmartToken(address(this));
    }

    // allows execution only when transfers aren't disabled
    modifier transfersAllowed {
        assert(transfersEnabled);
        _;
    }

    // check if the address is frozen
    modifier notFrozen(address _address) {
        assert(isFrozen[_address] == false);
        _;
    }

    // check if the address is frozen
    modifier notReachCap(uint256 _amount) {
        assert(safeAdd(totalSupply, _amount) <= MAX_SUPPLY);
        _;
    }

    /**
        @dev disables/enables transfers
        can only be called by the contract owner

        @param _disable    true to disable transfers, false to enable them
    */
    function disableTransfers(bool _disable) public ownerOnly {
        transfersEnabled = !_disable;
    }

    /**
        @dev freeze/unfreeze account
        can only be called by the contract owner

        @param _address    user address to freeze
        @param _freezeOrNot true means freeze, false means unfreeze
    */
    function freeze(address _address, bool _freezeOrNot) public ownerOnly {
        isFrozen[_address] = _freezeOrNot;
    }

    /**
        @dev increases the token supply and sends the new tokens to an account
        can only be called by the contract owner

        @param _to         account to receive the new amount
        @param _amount     amount to increase the supply by
    */
    function issue(address _to, uint256 _amount)
        public
        ownerOnly
        validAddress(_to)
        notThis(_to)
        notReachCap(_amount)
    {
        totalSupply = safeAdd(totalSupply, _amount);
        balanceOf[_to] = safeAdd(balanceOf[_to], _amount);

        emit Issuance(_amount);
        emit Transfer(this, _to, _amount);
    }

    /**
        @dev removes tokens from an account and decreases the token supply
        can be called by the contract owner to destroy tokens from any account or by any holder to destroy tokens from his/her own account

        @param _from       account to remove the amount from
        @param _amount     amount to decrease the supply by
    */
    function destroy(address _from, uint256 _amount) public {
        require(msg.sender == _from || msg.sender == owner);
        // validate input

        balanceOf[_from] = safeSub(balanceOf[_from], _amount);
        totalSupply = safeSub(totalSupply, _amount);

        emit Transfer(_from, this, _amount);
        emit Destruction(_amount);
    }

    // ERC20 standard method overrides with some extra functionality

    /**
        @dev send coins
        throws on any error rather then return a false flag to minimize user errors
        in addition to the standard checks, the function throws if transfers are disabled

        @param _to      target address
        @param _value   transfer amount

        @return true if the transfer was successful, false if it wasn't
    */
    function transfer(address _to, uint256 _value)
        public
        transfersAllowed
        notFrozen(msg.sender)
        returns (bool success)
    {
        assert(super.transfer(_to, _value));
        return true;
    }

    /**
        @dev an account/contract attempts to get the coins
        throws on any error rather then return a false flag to minimize user errors
        in addition to the standard checks, the function throws if transfers are disabled

        @param _from    source address
        @param _to      target address
        @param _value   transfer amount

        @return true if the transfer was successful, false if it wasn't
    */
    function transferFrom(address _from, address _to, uint256 _value)
        public
        transfersAllowed
        notFrozen(_from)
        returns (bool success)
    {
        assert(super.transferFrom(_from, _to, _value));
        return true;
    }
}
