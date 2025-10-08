// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// CozySwap - Factory & Pair (UniswapV2-like) - Final version for Remix
// - Refactored to avoid "stack too deep" in swap() without requiring viaIR
// - Fee = 0.3% (uses factor 3)
// - _update uses two params only
// - Safety checks for LP transfers/allowances
// - Small ERC20-like LP helpers (totalSupply, balanceOf)

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

interface ICozySwapPair {
    function initialize(address, address) external;
}

contract CozySwapPair {
    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    // ERC20-like LP variables
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

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _update(uint256 balance0, uint256 balance1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "CozySwap: OVERFLOW");
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = uint32(block.timestamp);
        emit Sync(reserve0, reserve1);
    }

    function _calculateLiquidityAmount(
        uint256 _amount0,
        uint256 _amount1,
        uint112 _reserveA,
        uint112 _reserveB
    ) internal view returns (uint256 liquidity) {
        if (_reserveA == 0 && _reserveB == 0) {
            // guard against multiplication overflow before sqrt
            require(_amount0 == 0 || _amount1 <= type(uint256).max / _amount0, "CozySwap: MUL_OVERFLOW");
            liquidity = _sqrt(_amount0 * _amount1);
        } else {
            uint256 liquidity0 = (_amount0 * totalLPSupply) / _reserveA;
            uint256 liquidity1 = (_amount1 * totalLPSupply) / _reserveB;
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        }
    }

    function mint(address to) external onlyFactory returns (uint256 liquidity) {
        (uint112 currentReserve0, uint112 currentReserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - currentReserve0;
        uint256 amount1 = balance1 - currentReserve1;

        liquidity = _calculateLiquidityAmount(amount0, amount1, currentReserve0, currentReserve1);
        require(liquidity > 0, "CozySwap: INSUFFICIENT_LIQUIDITY_MINTED");

        _mintLP(to, liquidity);
        _update(balance0, balance1);
        emit Mint(msg.sender, amount0, amount1);
    }

    function burn(address to) external onlyFactory returns (uint256 amount0, uint256 amount1) {
        (uint112 currentReserve0, uint112 currentReserve1,) = getReserves();
        address _token0 = token0;
        address _token1 = token1;
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        uint256 liquidity = lpBalanceOf[address(this)];

        require(totalLPSupply > 0, "CozySwap: NO_LIQUIDITY");

        amount0 = (liquidity * balance0) / totalLPSupply;
        amount1 = (liquidity * balance1) / totalLPSupply;
        require(amount0 > 0 && amount1 > 0, "CozySwap: INSUFFICIENT_LIQUIDITY_BURNED");

        _burnLP(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);

        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // Refactored swap to reduce stack usage: keep local variables minimal and reuse
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external onlyFactory {
        require(amount0Out > 0 || amount1Out > 0, "CozySwap: INSUFFICIENT_OUTPUT_AMOUNT");

        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "CozySwap: INSUFFICIENT_LIQUIDITY");

        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, "CozySwap: INVALID_TO");

        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out);
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out);
        if (data.length > 0) ICozySwapCallee(to).cozySwapCall(msg.sender, amount0Out, amount1Out, data);

        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));

        // compute amount in
        uint256 amount0In = 0;
        uint256 amount1In = 0;
        if (balance0 > _reserve0 - amount0Out) amount0In = balance0 - (_reserve0 - amount0Out);
        if (balance1 > _reserve1 - amount1Out) amount1In = balance1 - (_reserve1 - amount1Out);

        require(amount0In > 0 || amount1In > 0, "CozySwap: INSUFFICIENT_INPUT_AMOUNT");

        // fee 0.3% -> multiply by 1000 and subtract 3 * amountIn. Use unchecked to avoid extra stack slots.
        unchecked {
            uint256 balance0Adjusted = balance0 * 1000 - (amount0In * 3);
            uint256 balance1Adjusted = balance1 * 1000 - (amount1In * 3);
            require(
                balance0Adjusted * balance1Adjusted >= uint256(_reserve0) * _reserve1 * 1000**2,
                "CozySwap: K"
            );
        }

        _update(balance0, balance1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

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
        require(lpBalanceOf[from] >= value, "CozySwap: INSUFFICIENT_LP_BALANCE");
        lpBalanceOf[from] -= value;
        totalLPSupply -= value;
        emit Transfer(from, address(0), value);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        lpAllowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(lpBalanceOf[msg.sender] >= value, "CozySwap: INSUFFICIENT_LP_BALANCE");
        lpBalanceOf[msg.sender] -= value;
        lpBalanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(lpBalanceOf[from] >= value, "CozySwap: INSUFFICIENT_LP_BALANCE");
        uint256 currentAllowance = lpAllowance[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= value, "CozySwap: INSUFFICIENT_ALLOWANCE");
            lpAllowance[from][msg.sender] = currentAllowance - value;
        }
        lpBalanceOf[from] -= value;
        lpBalanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }

    // Small ERC20-like helpers
    function totalSupply() external view returns (uint256) {
        return totalLPSupply;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return lpBalanceOf[owner];
    }
}

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

interface ICozySwapCallee {
    function cozySwapCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}
