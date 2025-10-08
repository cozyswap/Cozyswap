// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/*-------------------------------------------------------
 🏭 CozySwapFactory — Pabrik pasangan token (pair)
-------------------------------------------------------*/
contract CozySwapFactory {
    address public feeTo;
    address public feeToSetter;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 allPairsLength);
    event FeeToUpdated(address indexed newFeeTo);
    event FeeToSetterUpdated(address indexed newFeeToSetter);

    bytes32 public constant INIT_CODE_HASH = keccak256(abi.encodePacked(type(CozySwapPair).creationCode));

    constructor(address _feeToSetter) {
        require(_feeToSetter != address(0), "CozySwap: ZERO_ADDRESS");
        feeToSetter = _feeToSetter;
        emit FeeToSetterUpdated(_feeToSetter);
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "CozySwap: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "CozySwap: ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "CozySwap: PAIR_EXISTS");

        bytes memory bytecode = type(CozySwapPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));

        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        ICozySwapPair(pair).initialize(token0, token1);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, "CozySwap: FORBIDDEN");
        require(_feeTo != address(0), "CozySwap: ZERO_ADDRESS");
        feeTo = _feeTo;
        emit FeeToUpdated(_feeTo);
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, "CozySwap: FORBIDDEN");
        require(_feeToSetter != address(0), "CozySwap: ZERO_ADDRESS");
        feeToSetter = _feeToSetter;
        emit FeeToSetterUpdated(_feeToSetter);
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function calculatePairAddress(address tokenA, address tokenB) public view returns (address predicted) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            keccak256(abi.encodePacked(token0, token1)),
            INIT_CODE_HASH
        )))));
    }
}

/*-------------------------------------------------------
 💧 CozySwapPair — Liquidity Pool (token0-token1)
-------------------------------------------------------*/
contract CozySwapPair {
    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    // LP Token info
    string public constant pairName = "CozySwap Pair";
    string public constant pairSymbol = "COZY-LP";
    uint8 public constant pairDecimals = 18;

    uint256 public totalLPSupply;
    mapping(address => uint256) public lpBalanceOf;
    mapping(address => mapping(address => uint256)) public lpAllowance;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    modifier onlyFactory() {
        require(msg.sender == factory, "CozySwap: FORBIDDEN");
        _;
    }

    function initialize(address _token0, address _token1) external {
        require(factory == address(0), "CozySwap: ALREADY_INITIALIZED");
        factory = msg.sender;
        token0 = _token0;
        token1 = _token1;
    }

    function getReserves() public view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function _update(uint256 balance0, uint256 balance1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "CozySwap: OVERFLOW");
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = uint32(block.timestamp);
        emit Sync(reserve0, reserve1);
    }

    function _calculateLiquidityAmount(
        uint256 amount0,
        uint256 amount1,
        uint112 _reserve0,
        uint112 _reserve1
    ) internal view returns (uint256 liquidity) {
        if (_reserve0 == 0 && _reserve1 == 0) {
            liquidity = _sqrt(amount0 * amount1);
        } else {
            uint256 liquidity0 = (amount0 * totalLPSupply) / _reserve0;
            uint256 liquidity1 = (amount1 * totalLPSupply) / _reserve1;
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        }
    }

    function mint(address to) external onlyFactory returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        liquidity = _calculateLiquidityAmount(amount0, amount1, _reserve0, _reserve1);
        require(liquidity > 0, "CozySwap: INSUFFICIENT_LIQUIDITY_MINTED");

        _mintLP(to, liquidity);
        _update(balance0, balance1);
        emit Mint(msg.sender, amount0, amount1);
    }

    function burn(address to) external onlyFactory returns (uint256 amount0, uint256 amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 liquidity = lpBalanceOf[address(this)];

        amount0 = (liquidity * balance0) / totalLPSupply;
        amount1 = (liquidity * balance1) / totalLPSupply;
        require(amount0 > 0 && amount1 > 0, "CozySwap: INSUFFICIENT_LIQUIDITY_BURNED");

        _burnLP(address(this), liquidity);
        _safeTransfer(token0, to, amount0);
        _safeTransfer(token1, to, amount1);

        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));
        _update(balance0, balance1);

        emit Burn(msg.sender, amount0, amount1, to);
    }

    /*-------------------------------------------------------
     ✅ FIXED swap() — no stack too deep, clean version
    -------------------------------------------------------*/
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external onlyFactory {
        require(amount0Out > 0 || amount1Out > 0, "CozySwap: INSUFFICIENT_OUTPUT_AMOUNT");

        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "CozySwap: INSUFFICIENT_LIQUIDITY");

        address token0_ = token0;
        address token1_ = token1;
        require(to != token0_ && to != token1_, "CozySwap: INVALID_TO");

        if (amount0Out > 0) _safeTransfer(token0_, to, amount0Out);
        if (amount1Out > 0) _safeTransfer(token1_, to, amount1Out);

        if (data.length > 0) {
            ICozySwapCallee(to).cozySwapCall(msg.sender, amount0Out, amount1Out, data);
        }

        uint256 balance0 = IERC20(token0_).balanceOf(address(this));
        uint256 balance1 = IERC20(token1_).balanceOf(address(this));

        uint256 amount0In;
        uint256 amount1In;

        unchecked {
            if (balance0 > _reserve0 - amount0Out) {
                amount0In = balance0 - (_reserve0 - amount0Out);
            }
            if (balance1 > _reserve1 - amount1Out) {
                amount1In = balance1 - (_reserve1 - amount1Out);
            }
        }

        require(amount0In > 0 || amount1In > 0, "CozySwap: INSUFFICIENT_INPUT_AMOUNT");

        unchecked {
            uint256 b0 = balance0 * 1000 - amount0In * 3;
            uint256 b1 = balance1 * 1000 - amount1In * 3;
            require(b0 * b1 >= uint256(_reserve0) * _reserve1 * (1000**2), "CozySwap: K");
        }

        _update(balance0, balance1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /*-------------------------------------------------------
     🔧 Internal Helpers
    -------------------------------------------------------*/
    function _safeTransfer(address token, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "CozySwap: TRANSFER_FAILED");
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function _mintLP(address to, uint256 value) internal {
        totalLPSupply += value;
        lpBalanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function _burnLP(address from, uint256 value) internal {
        lpBalanceOf[from] -= value;
        totalLPSupply -= value;
        emit Transfer(from, address(0), value);
    }

    /*-------------------------------------------------------
     🔹 Basic ERC20-like LP Token functions
    -------------------------------------------------------*/
    function approve(address spender, uint256 value) external returns (bool) {
        lpAllowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        lpBalanceOf[msg.sender] -= value;
        lpBalanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        if (lpAllowance[from][msg.sender] != type(uint256).max) {
            lpAllowance[from][msg.sender] -= value;
        }
        lpBalanceOf[from] -= value;
        lpBalanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }
}

/*-------------------------------------------------------
 📜 Interfaces
-------------------------------------------------------*/
interface ICozySwapPair {
    function initialize(address, address) external;
}

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

interface ICozySwapCallee {
    function cozySwapCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}
