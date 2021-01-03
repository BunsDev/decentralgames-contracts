// SPDX-License-Identifier: -- 🎲 --

pragma solidity ^0.7.5;

// Roulette Logic Contract ///////////////////////////////////////////////////////////
// Author: Decentral Games (hello@decentral.games) ///////////////////////////////////////
// Roulette - MultiPlayer - TokenIndex 2.0

import "./common-contracts/SafeMath.sol";
import "./common-contracts/AccessController.sol";
import "./common-contracts/TreasuryInstance.sol";
import "./common-contracts/PointerInstance.sol";

contract dgRoulette is AccessController {

    using SafeMath for uint128;
    using SafeMath for uint256;

    uint256 private store;

    enum BetType { Single, EvenOdd, RedBlack, HighLow, Column, Dozen }

    mapping (address => uint) public totalBets;
    mapping (address => uint) public totalPayout;

    mapping (uint => uint) public maxSquareBets;
    mapping (uint => mapping (uint => mapping (uint => uint))) public currentBets;

    Bet[] public bets;
    uint256[] winAmounts;

    struct Bet {
        address player;
        uint8 betType;
        uint8 number;
        uint8 tokenIndex;
        uint128 value;
    }

    event GameResult(
        address[] _players,
        uint8[] _tokenIndex,
        uint256 indexed _landID,
        uint256 indexed _number,
        uint256 indexed _machineID,
        uint256[] _winAmounts
    );

    TreasuryInstance public treasury;
    PointerInstance public pointerContract;

    constructor(
        address _treasuryAddress,
        uint128 _maxSquareBetDefault,
        uint8 _maxNumberBets,
        address _pointerAddress
    ) {
        treasury = TreasuryInstance(_treasuryAddress);
        store |= _maxNumberBets<<0;
        store |= _maxSquareBetDefault<<8;
        store |= block.timestamp<<136;
        pointerContract = PointerInstance(_pointerAddress);
    }

    function addPoints(
        address _player,
        uint256 _points,
        address _token,
        uint256 _numPlayers,
        uint256 _wearableBonus
    )
        private
    {
        pointerContract.addPoints(
            _player,
            _points,
            _token,
            _numPlayers,
            _wearableBonus
        );
    }

    function bet(
        address _player,
        uint8 _betType,
        uint8 _number,
        uint8 _tokenIndex,
        uint128 _value
    )
        internal
    {
        currentBets[_tokenIndex][_betType][_number] += _value;

        uint256 _maxSquareBet = maxSquareBets[_tokenIndex] == 0
            ? uint128(store>>8)
            : maxSquareBets[_tokenIndex];

        require(
            currentBets[_tokenIndex][_betType][_number] <= _maxSquareBet,
            'Roulette: exceeding maximum bet limit'
        );

        bets.push(Bet({
            player: _player,
            betType: _betType,
            number: _number,
            tokenIndex: _tokenIndex,
            value: _value
        }));
    }

    function _launch(
        bytes32 _localhash,
        address[] memory _players,
        uint8[] memory _tokenIndex,
        uint256 _landID,
        uint256 _machineID
    )
        private
        returns(
            uint256[] memory,
            uint256 number
        )
    {
        require(block.timestamp > store>>136, 'Roulette: expired round');
        require(bets.length > 0, 'Roulette: must have bets');

        delete winAmounts;

        store ^= (store>>136)<<136;
        store |= block.timestamp<<136;

        number = uint(
            keccak256(
                abi.encodePacked(_localhash)
            )
        ) % 37;

        for (uint i = 0; i < bets.length; i++) {
            bool won = false;
            Bet memory b = bets[i];
            if (b.betType == uint(BetType.Single) && b.number == number) {
                won = true;
            } else if (b.betType == uint(BetType.EvenOdd) && number <= 36) {
                if (number > 0 && number % 2 == b.number) {
                    won = true;
                }
            } else if (b.betType == uint(BetType.RedBlack) && b.number == 0) {
                if ((number > 0 && number <= 10) || (number >= 19 && number <= 28)) {
                    won = (number % 2 == 1);
                } else {
                    if (number > 0 && number <= 36) {
                        won = (number % 2 == 0);
                    }
                }
            } else if (b.betType == uint(BetType.RedBlack) && b.number == 1) {
                if ((number > 0 && number <= 10) || (number >= 19 && number <= 28)) {
                    won = (number % 2 == 0);
                } else {
                    if (number > 0 && number <= 36) {
                        won = (number % 2 == 1);
                    }
                }
            } else if (b.betType == uint(BetType.HighLow) && number <= 36) {
                if (number >= 19 && b.number == 0) {
                    won = true;
                }
                if (number > 0 && number <= 18 && b.number == 1) {
                    won = true;
                }
            } else if (b.betType == uint(BetType.Column) && number <= 36) {
                if (b.number == 0 && number > 0) won = (number % 3 == 1);
                if (b.number == 1 && number > 0) won = (number % 3 == 2);
                if (b.number == 2 && number > 0) won = (number % 3 == 0);
            } else if (b.betType == uint(BetType.Dozen) && number <= 36) {
                if (b.number == 0) won = (number > 0 && number <= 12);
                if (b.number == 1) won = (number > 12 && number <= 24);
                if (b.number == 2) won = (number > 24 && number <= 36);
            }

            if (won) {
                uint256 betWin = b.value.mul(
                    getPayoutForType(b.betType, b.number)
                );
                winAmounts.push(betWin);
            } else {
                winAmounts.push(0);
            }
            currentBets[b.tokenIndex][b.betType][b.number] = 0;
        }

        delete bets;

        emit GameResult(
            _players,
            _tokenIndex,
            _landID,
            number,
            _machineID,
            winAmounts
        );

        return(
            winAmounts,
            number
        );
    }

    function play(
        address[] memory _players,
        uint256 _landID,
        uint256 _machineID,
        uint8[] memory _betIDs,
        uint8[] memory _betValues,
        uint128[] memory _betAmount,
        bytes32 _localhash,
        uint8[] memory _tokenIndex,
        uint8 _playerCount,
        uint8[] memory _wearableBonus
    )
        public
        whenNotPaused
        onlyWorker
    {
        require(
            _betIDs.length == _betValues.length,
            'Roulette: inconsistent amount of betsValues'
        );

        require(
            _tokenIndex.length == _betAmount.length,
            'Roulette: inconsistent amount of betAmount'
        );

        require(
            _betValues.length == _tokenIndex.length,
            'Roulette: inconsistent amount of tokenIndex'
        );

        require(
            _betIDs.length <= uint8(store>>0),
            'Roulette: maximum amount of bets reached'
        );

        /* treasury.consumeHash(
            _localhash
        );*/

        bool[5] memory checkedTokens;
        uint8 i;

        for (i = 0; i < _betIDs.length; i++) {

            require(
                treasury.getMaximumBet(_tokenIndex[i]) >= _betAmount[i],
                'Roulette: bet amount is more than maximum'
            );

            treasury.tokenInboundTransfer(
                _tokenIndex[i],
                _players[i],
                _betAmount[i]
            );

            bet(
                _players[i],
                _betIDs[i],
                _betValues[i],
                _tokenIndex[i],
                _betAmount[i]
            );

            if (!checkedTokens[_tokenIndex[i]]) {
                uint256 tokenFunds = treasury.checkAllocatedTokens(_tokenIndex[i]);
                require(
                    getNecessaryBalance(_tokenIndex[i]) <= tokenFunds,
                    'Roulette: not enough tokens for payout'
                );
                checkedTokens[_tokenIndex[i]] = true;
            }
        }

        uint256 _spinResult;
        (winAmounts, _spinResult) = _launch(
            _localhash,
            _players,
            _tokenIndex,
            _landID,
            _machineID
        );

        // payout && points preparation
        for (i = 0; i < winAmounts.length; i++) {
            if (winAmounts[i] > 0) {
                treasury.tokenOutboundTransfer(
                    _tokenIndex[i],
                    _players[i],
                    winAmounts[i]
                );
                // collecting totalPayout
                totalPayout[_players[i]] =
                totalPayout[_players[i]] + winAmounts[i];
            }
            totalBets[_players[i]] =
            totalBets[_players[i]] + _betAmount[i];
        }

        // point calculation && bonus
        for (i = 0; i < _players.length; i++) {
            _issuePointsAmount(
                _players[i],
                _tokenIndex[i],
                _playerCount,
                _wearableBonus[i]
            );
        }
    }

    function _issuePointsAmount(
        address _player,
        uint8 _tokenIndex,
        uint256 _playerCount,
        uint256 _wearableBonus
    ) private {
        if (totalPayout[_player] > totalBets[_player]) {
            addPoints(
                _player,
                totalPayout[_player].sub(totalBets[_player]),
                treasury.getTokenAddress(_tokenIndex),
                _playerCount,
                _wearableBonus
            );
            totalBets[_player] = 0;
            totalPayout[_player] = 0;
        }
        else if (totalPayout[_player] < totalBets[_player]) {
            addPoints(
                _player,
                totalBets[_player].sub(totalPayout[_player]),
                treasury.getTokenAddress(_tokenIndex),
                _playerCount,
                _wearableBonus
            );
            totalBets[_player] = 0;
            totalPayout[_player] = 0;
        }
    }

    function getPayoutForType(
        uint256 _betType,
        uint256 _betNumber
    )
        public
        pure
        returns(uint256)
    {
        if (_betType == uint8(BetType.Single))
            return _betNumber > 36 ? 0 : 36;
        if (_betType == uint8(BetType.EvenOdd))
            return _betNumber > 1 ? 0 : 2;
        if (_betType == uint8(BetType.RedBlack))
            return _betNumber > 1 ? 0 : 2;
        if (_betType == uint8(BetType.HighLow))
            return _betNumber > 1 ? 0 : 2;
        if (_betType == uint8(BetType.Column))
            return _betNumber > 2 ? 0 : 3;
        if (_betType == uint8(BetType.Dozen))
            return _betNumber > 2 ? 0 : 3;

        return 0;
    }

    function getNecessaryBalance(
        uint256 _tokenIndex
    )
        public
        view
        returns (uint256 _necessaryBalance)
    {
        uint256 _necessaryForBetType;
        uint256[6] memory betTypesMax;

        for (uint8 _i = 0; _i < bets.length; _i++) {
            Bet memory b = bets[_i];
            if (b.tokenIndex == _tokenIndex) {

                uint256 _payout = getPayoutForType(b.betType, b.number);
                uint256 _square = currentBets[b.tokenIndex][b.betType][b.number];

                require(
                    _payout > 0,
                    'Roulette: incorrect bet type/value'
                );

                _necessaryForBetType = _square.mul(_payout);

                if (_necessaryForBetType > betTypesMax[b.betType]) {
                    betTypesMax[b.betType] = _necessaryForBetType;
                }
            }
        }

        for (uint8 _i = 0; _i < betTypesMax.length; _i++) {
            _necessaryBalance = _necessaryBalance.add(
                betTypesMax[_i]
            );
        }
    }

    function getBetsCountAndValue()
        external
        view
        returns(uint value, uint)
    {
        for (uint i = 0; i < bets.length; i++) {
            value += bets[i].value;
        }

        return (bets.length, value);
    }

    function getBetsCount()
        external
        view
        returns (uint256)
    {
        return bets.length;
    }

    function changeMaxSquareBet(
        uint256 _tokenIndex,
        uint256 _newMaxSquareBet
    )
        external
        onlyCEO
    {
        maxSquareBets[_tokenIndex] = _newMaxSquareBet;
    }

    function changeMaxSquareBetDefault(
        uint128 _newMaxSquareBetDefault
    )
        external
        onlyCEO
    {
        store ^= uint128((store>>8))<<8;
        store |= _newMaxSquareBetDefault<<8;
    }

    function changeMaximumBetAmount(
        uint8 _newMaximumBetAmount
    )
        external
        onlyCEO
    {
        store ^= uint8(store)<<0;
        store |= _newMaximumBetAmount<<0;
    }

    function changeTreasury(
        address _newTreasuryAddress
    )
        external
        onlyCEO
    {
        treasury = TreasuryInstance(
            _newTreasuryAddress
        );
    }

    function getNextRoundTimestamp()
        external
        view
        returns(uint)
    {
        return store>>136;
    }

    function checkMaximumBetAmount()
        external
        view
        returns (uint8)
    {
        return uint8(store>>0);
    }

    function checkMaxSquareBetDefault()
        external
        view
        returns (uint128)
    {
        return uint128(store>>8);
    }

    function updatePointer(
        address _newPointerAddress
    )
        external
        onlyCEO
    {
        pointerContract = PointerInstance(
            _newPointerAddress
        );
    }
}