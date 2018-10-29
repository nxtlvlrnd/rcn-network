pragma solidity ^0.4.24;

import "./../interfaces/Token.sol";
import "./../interfaces/Cosigner.sol";
import "./interfaces/Model.sol";
import "./../utils/IsContract.sol";
import "./../utils/ERC721Base.sol";

interface IOracle {
    function getRate(bytes32 symbol, bytes data) external returns (uint256 rate, uint256 decimals);
}

contract DebtEngine is ERC721Base {
    using IsContract for address;

    event Created(
        bytes32 indexed _id,
        uint256 _nonce,
        bytes _data
    );

    event Created2(
        bytes32 indexed _id,
        uint256 _nonce,
        bytes _data
    );

    event Paid(
        bytes32 indexed _id,
        address _sender,
        address _origin,
        uint256 _requested,
        uint256 _requestedTokens,
        uint256 _paid,
        uint256 _tokens
    );

    event PaidBatch(
        bytes32 indexed _id,
        address _sender,
        uint256 _requested,
        uint256 _requestedTokens,
        uint256 _paid,
        uint256 _tokens
    );

    event RadedOracleBatch(
        uint256 _count,
        uint256 _amount,
        uint256 _decimals
    );

    event ReadedOracle(
        bytes32 indexed _id,
        uint256 _amount,
        uint256 _decimals
    );

    event Withdrawn(
        bytes32 indexed _id,
        address _sender,
        address _to,
        uint256 _amount
    );

    event Error(
        bytes32 indexed _id,
        address _sender,
        uint256 _value,
        uint256 _gasLeft,
        uint256 _gasLimit,
        bytes _callData
    );

    event ErrorRecover(
        bytes32 indexed _id,
        address _sender,
        uint256 _value,
        uint256 _gasLeft,
        uint256 _gasLimit,
        bytes32 _result,
        bytes _callData
    );

    Token public token;

    mapping(bytes32 => Debt) public debts;
    mapping(address => uint256) public nonces;

    struct Debt {
        bool error;
        bytes8 currency;
        uint128 balance;
        Model model;
        address creator;
        address oracle;
    }

    constructor (
        Token _token
    ) public ERC721Base("RCN Debt Record", "RDR") {
        token = _token;

        // Sanity checks
        require(address(_token).isContract(), "Token should be a contract");
    }

    function create(
        Model _model,
        address _owner,
        address _oracle,
        bytes8 _currency,
        bytes _data
    ) external returns (bytes32 id) {
        uint256 nonce = nonces[msg.sender]++;
        id = _buildId(msg.sender, nonce, false);

        debts[id] = Debt({
            error: false,
            currency: _currency,
            balance: 0,
            creator: msg.sender,
            model: _model,
            oracle: _oracle
        });

        _generate(uint256(id), _owner);
        require(_model.create(id, _data), "Error creating debt in model");

        emit Created({
            _id: id,
            _nonce: nonce,
            _data: _data
        });
    }

    function create2(
        Model _model,
        address _owner,
        address _oracle,
        bytes8 _currency,
        uint256 _nonce,
        bytes _data
    ) external returns (bytes32 id) {
        id = _buildId(msg.sender, _nonce, true);

        debts[id] = Debt({
            error: false,
            currency: _currency,
            balance: 0,
            creator: msg.sender,
            model: _model,
            oracle: _oracle
        });

        _generate(uint256(id), _owner);
        require(_model.create(id, _data), "Error creating debt in model");

        emit Created2({
            _id: id,
            _nonce: _nonce,
            _data: _data
        });
    }

    function buildId(
        address _creator,
        uint256 _nonce,
        bool _method2
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(_creator, _nonce, _method2));
    }

    function _buildId(
        address _creator,
        uint256 _nonce,
        bool _method2
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_creator, _nonce, _method2));
    }

    function pay(
        bytes32 _id,
        uint256 _amount,
        address _origin,
        bytes _oracleData
    ) external returns (uint256 paid, uint256 paidToken) {
        Debt storage debt = debts[_id];

        // Paid only required amount
        paid = _safePay(_id, debt.model, _amount);
        require(paid <= _amount, "Paid can't be more than requested");

        IOracle oracle = IOracle(debt.oracle);
        if (oracle != address(0)) {
            // Convert
            (uint256 rate, uint256 decimals) = oracle.getRate(debt.currency, _oracleData);
            emit ReadedOracle(_id, rate, decimals);
            paidToken = _toToken(paid, rate, decimals);
        } else {
            paidToken = paid;
        }

        // Pull tokens from payer
        require(token.transferFrom(msg.sender, address(this), paidToken), "Error pulling payment tokens");

        // Add balance to the debt
        uint256 newBalance = paidToken.add(debt.balance);
        require(newBalance < 340282366920938463463374607431768211456, "uint128 Overflow");
        debt.balance = uint128(newBalance);

        // Emit pay event
        emit Paid({
            _id: _id,
            _sender: msg.sender,
            _origin: _origin,
            _requested: _amount,
            _requestedTokens: 0,
            _paid: paid,
            _tokens: paidToken
        });
    }

    function payBatch(
        bytes32[] _ids,
        uint256[] _amounts,
        address _oracle,
        bytes8 _currency,
        bytes _oracleData
    ) external returns (uint256[], uint256[]) {
        uint count = _ids.length;
        require(count == _amounts.length, "The loans and the amounts do not correspond.");
        require(count > 0, "There are not loans to pay.");

        uint256[] memory data = new uint256[](3);
        if (_oracle != address(0)) {
            (data[1], data[2]) = IOracle(_oracle).getRate(_currency, _oracleData);
            emit RadedOracleBatch(count, data[1], data[2]);
        }

        uint256[] memory pays = new uint256[](count);
        uint256[] memory paidTokens = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            data[0] = _amounts[i];
            (pays[i], paidTokens[i]) = _pay(_ids[i], _oracle, _currency, data);

            emit PaidBatch({
                _id: _ids[i],
                _sender: msg.sender,
                _requested: _amounts[i],
                _requestedTokens: 0,
                _paid: pays[i],
                _tokens: paidTokens[i]
            });
        }

        return (pays, paidTokens);
    }

    function payToken(
        bytes32 id,
        uint256 amount,
        address origin,
        bytes oracleData
    ) external returns (uint256 paid, uint256 paidToken) {
        Debt storage debt = debts[id];

        // Read storage
        IOracle oracle = IOracle(debt.oracle);

        uint256 rate;
        uint256 decimals;
        uint256 available;

        // Get available <currency> amount
        if (oracle != address(0)) {
            (rate, decimals) = oracle.getRate(debt.currency, oracleData);
            emit ReadedOracle(id, rate, decimals);
            available = _fromToken(amount, rate, decimals);
        } else {
            available = amount;
        }

        // Call addPaid on model
        paid = _safePay(id, debt.model, available);
        require(paid <= available, "Paid can't exceed available");

        // Convert back to required pull amount
        if (oracle != address(0)) {
            paidToken = _toToken(paid, rate, decimals);
            require(paidToken <= amount, "Paid can't exceed requested");
        } else {
            paidToken = paid;
        }

        // Pull tokens from payer
        require(token.transferFrom(msg.sender, address(this), paidToken), "Error pulling tokens");

        // Add balance to the debt
        // WARNING: Reusing variable **available**
        available = paidToken.add(debt.balance);
        require(available < 340282366920938463463374607431768211456, "uint128 Overflow");
        debt.balance = uint128(available);

        // Emit pay event
        emit Paid({
            _id: id,
            _sender: msg.sender,
            _origin: origin,
            _requested: 0,
            _requestedTokens: amount,
            _paid: paid,
            _tokens: paidToken
        });
    }

    function payTokenBatch(
        bytes32[] _ids,
        uint256[] _amounts,
        address _oracle,
        bytes8 _currency,
        bytes _oracleData
    ) external returns (uint256[]) {
        uint count = _ids.length;
        require(count == _amounts.length, "The loans and the amounts do not correspond.");
        require(count > 0, "There are not loans to pay.");

        uint256[] memory data = new uint256[](3);
        if (_oracle != address(0)) {
            (data[1], data[2]) = IOracle(_oracle).getRate(_currency, _oracleData);
            emit RadedOracleBatch(count, data[1], data[2]);
        }

        uint256 available;
        uint256[] memory pays = new uint256[](count);
        uint256[] memory paidTokens = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {

            data[0] = _amounts[i];
            if (_oracle != address(0)) {
                available = _fromToken(_amounts[i], data[1], data[2]);
            }

            (pays[i], paidTokens[i]) = _pay(_ids[i], _oracle, _currency, data);

        }

        return paidTokens;

    }

    /*
    *
    * Method internal that help to pay.
    *
    * @param _id Pay identifier
    * @param _oracle Address of the Oracle contract, if the loan does not use any oracle, this field should be 0x0.
    * @param _currency The currency to use with the oracle.
    * @param _data Array of data for pay
    *        0 -> Amount - Amount to convert in rate currency.
    *        1 -> Rate -  Rate to use in the convertion.
    *        2 -> Decimals - Base difference between rate and tokens.
    *
    * @return paid
    * @return paidToken
    *
    */
    function _pay(
        bytes32 _id,
        address _oracle,
        bytes8 _currency,
        uint256[] _data
    ) internal returns (uint256 paid, uint256 paidToken){
        Debt storage debt = debts[_id];
        require(_currency == debt.currency, "The currencies addres is invalid.");
        require(_oracle == debt.oracle, "The oracle is invalid.");

        // Paid only required amount
        paid = _safePay(_id, debt.model, _data[0]);
        require(paid <= _data[0], "Paid can't be more than requested");

        paidToken = _getPaidToken(paid, _oracle, _data[1], _data[2]);
        require(paidToken <= _data[0], "Paid can't exceed requested");

        // Pull tokens from payer
        require(token.transferFrom(msg.sender, address(this), paidToken), "Error pulling payment tokens");

        // Add balance to debt
        debt.balance = _addBalanceToDebt(paidToken, debt.balance);
    }

    function _addBalanceToDebt(
        uint256 paidToken,
        uint256 balance
    ) internal returns (uint128) {
        uint256 newBalance = paidToken.add(balance);
        require(newBalance < 340282366920938463463374607431768211456, "uint128 Overflow");
        return uint128(newBalance);
    }

    function _getPaidToken(
        uint256 _paid,
        address _oracle,
        uint256 _rate,
        uint256 _decimals)
    internal returns (uint256) {
        if (_oracle != address(0)) {
            return _toToken(_paid, _rate, _decimals);
        }
        return _paid;
    }

    function _safePay(
        bytes32 _id,
        Model _model,
        uint256 _available
    ) internal returns (uint256) {
        (uint256 success, bytes32 paid) = _safeGasCall(
            _model,
            abi.encodeWithSelector(
                _model.addPaid.selector,
                _id,
                _available
            )
        );

        if (success == 1) {
            if (debts[_id].error) {
                emit ErrorRecover({
                    _id: _id,
                    _sender: msg.sender,
                    _value: 0,
                    _gasLeft: gasleft(),
                    _gasLimit: block.gaslimit,
                    _result: paid,
                    _callData: msg.data
                });

                delete debts[_id].error;
            }

            return uint256(paid);
        } else {
            emit Error({
                _id: _id,
                _sender: msg.sender,
                _value: msg.value,
                _gasLeft: gasleft(),
                _gasLimit: block.gaslimit,
                _callData: msg.data
            });
            debts[_id].error = true;
        }
    }

    /**
        Converts an amount in the rate currency to an amount in token

        @param _amount Amount to convert in rate currency
        @param _rate Rate to use in the convertion
        @param _decimals Base difference between rate and tokens

        @return Amount in tokens
    */
    function _toToken(
        uint256 _amount,
        uint256 _rate,
        uint256 _decimals
    ) internal pure returns (uint256) {
        require(_decimals <= 18, "Decimals limit reached");
        return _rate.mult(_amount).mult((10 ** (18 - _decimals))) / 1000000000000000000;
    }

    /**
        Converts an amount in token to the rate currency

        @param _amount Amount to convert in token
        @param _rate Rate to use in the convertion
        @param _decimals Base difference between rate and tokens

        @return Amount in rate currency
    */
    function _fromToken(
        uint256 _amount,
        uint256 _rate,
        uint256 _decimals
    ) internal pure returns (uint256) {
        require(_decimals <= 18, "Decimals limit reached");
        return (_amount.mult(1000000000000000000) / _rate) / 10 ** (18 - _decimals);
    }

    function run(bytes32 _id) external returns (bool) {
        Debt storage debt = debts[_id];

        (uint256 success, bytes32 result) = _safeGasCall(
            debt.model,
            abi.encodeWithSelector(
                debt.model.run.selector,
                _id
            )
        );

        if (success == 1) {
            if (debt.error) {
                emit ErrorRecover({
                    _id: _id,
                    _sender: msg.sender,
                    _value: 0,
                    _gasLeft: gasleft(),
                    _gasLimit: block.gaslimit,
                    _result: result,
                    _callData: msg.data
                });

                delete debt.error;
            }

            return result == bytes32(1);
        } else {
            emit Error({
                _id: _id,
                _sender: msg.sender,
                _value: 0,
                _gasLeft: gasleft(),
                _gasLimit: block.gaslimit,
                _callData: msg.data
            });
            debt.error = true;
        }
    }

    function withdrawal(bytes32 _id, address _to) external returns (uint256 amount) {
        require(_isAuthorized(msg.sender, uint256(_id)), "Sender not authorized");
        Debt storage debt = debts[_id];
        amount = debt.balance;
        debt.balance = 0;
        require(token.transfer(_to, amount), "Error sending tokens");
        emit Withdrawn({
            _id: _id,
            _sender: msg.sender,
            _to: _to,
            _amount: amount
        });
    }

    function withdrawalList(bytes32[] _ids, address _to) external returns (uint256 amount) {
        bytes32 target;
        uint256 balance;
        for (uint256 i = 0; i < _ids.length; i++) {
            target = _ids[i];
            if(_isAuthorized(msg.sender, uint256(target))) {
                balance = debts[target].balance;
                debts[target].balance = 0;
                amount += balance;
                emit Withdrawn({
                    _id: target,
                    _sender: msg.sender,
                    _to: _to,
                    _amount: balance
                });
            }
        }
        require(token.transfer(_to, amount), "Error sending tokens");
    }

    function getStatus(bytes32 _id) external view returns (uint256) {
        Debt storage debt = debts[_id];
        if (debt.error) {
            return 4;
        } else {
            (uint256 success, bytes32 result) = _safeGasStaticCall(
                debt.model,
                abi.encodeWithSelector(
                    debt.model.getStatus.selector,
                    _id
                )
            );
            return success == 1 ? uint256(result) : 4;
        }
    }

    function _safeGasStaticCall(
        address _contract,
        bytes _data
    ) internal view returns (uint256 success, bytes32 result) {
        uint256 _gas = (block.gaslimit * 80) / 100;
        _gas = gasleft() < _gas ? gasleft() : _gas;
        assembly {
            let x := mload(0x40)
            success := staticcall(
                            _gas,                 // Send almost all gas
                            _contract,            // To addr
                            add(0x20, _data),     // Input is data past the first 32 bytes
                            mload(_data),         // Input size is the lenght of data
                            x,                    // Store the ouput on x
                            0x20                  // Output is a single bytes32, has 32 bytes
                        )

            result := mload(x)
        }
    }

    function _safeGasCall(
        address _contract,
        bytes _data
    ) internal returns (uint256 success, bytes32 result) {
        uint256 _gas = (block.gaslimit * 80) / 100;
        _gas = gasleft() < _gas ? gasleft() : _gas;
        assembly {
            let x := mload(0x40)
            success := call(
                            _gas,                 // Send almost all gas
                            _contract,            // To addr
                            0,                    // Send ETH
                            add(0x20, _data),     // Input is data past the first 32 bytes
                            mload(_data),         // Input size is the lenght of data
                            x,                    // Store the ouput on x
                            0x20                  // Output is a single bytes32, has 32 bytes
                        )

            result := mload(x)
        }
    }
}
