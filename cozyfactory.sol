// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

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

// ✅ FIXED: Complete Interface
interface ICozySwapPair {
    function initialize(address, address) external;
    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    
    // ERC20 functions
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
}

contract CozySwapPair {
    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    // ERC20-like LP variables
    string public constant name = "CozySwap Pair";
    string public constant symbol = "COZY-LP";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

    function _calculateLiquidity(
        uint256 _amount0,
        uint256 _amount1,
        uint112 _reserveA,
        uint112 _reserveB
    ) internal view returns (uint256 liquidity) {
        if (_reserveA == 0 && _reserveB == 0) {
            // ✅ FIXED: Better overflow protection
            if (_amount0 == 0 || _amount1 == 0) return 0;
            require(_amount0 <= type(uint256).max / _amount1, "CozySwap: MUL_OVERFLOW");
            liquidity = _sqrt(_amount0 * _amount1);
        } else {
            require(totalSupply > 0, "CozySwap: NO_LIQUIDITY");
            uint256 liquidity0 = (_amount0 * totalSupply) / _reserveA;
            uint256 liquidity1 = (_amount1 * totalSupply) / _reserveB;
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        }
    }

    function mint(address to) external onlyFactory returns (uint256 liquidity) {
        (uint112 currentReserve0, uint112 currentReserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - currentReserve0;
        uint256 amount1 = balance1 - currentReserve1;

        liquidity = _calculateLiquidity(amount0, amount1, currentReserve0, currentReserve1);
        require(liquidity > 0, "CozySwap: INSUFFICIENT_LIQUIDITY_MINTED");

        _mint(to, liquidity);
        _update(balance0, balance1);
        emit Mint(msg.sender, amount0, amount1);
    }

    function burn(address to) external onlyFactory returns (uint256 amount0, uint256 amount1) {
        (uint112 currentReserve0, uint112 currentReserve1,) = getReserves();
        address _token0 = token0;
        address _token1 = token1;
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        uint256 _liquidity = balanceOf[address(this)];

        require(totalSupply > 0, "CozySwap: NO_LIQUIDITY");

        amount0 = (_liquidity * balance0) / totalSupply;
        amount1 = (_liquidity * balance1) / totalSupply;
        require(amount0 > 0 && amount1 > 0, "CozySwap: INSUFFICIENT_LIQUIDITY_BURNED");

        _burn(address(this), _liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);

        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

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

        // Compute amount in
        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;

        require(amount0In > 0 || amount1In > 0, "CozySwap: INSUFFICIENT_INPUT_AMOUNT");

        // ✅ FIXED: Correct 0.3% fee calculation (997/1000)
        unchecked {
            uint256 balance0Adjusted = balance0 * 1000 - (amount0In * 3); // 0.3% fee
            uint256 balance1Adjusted = balance1 * 1000 - (amount1In * 3); // 0.3% fee
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

    // ✅ FIXED: Better sqrt function with safety
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y == 0) return 0;
        if (y <= 3) return 1;
        
        z = y;
        uint256 x = y / 2 + 1;
        while (x < z) {
            z = x;
            x = (y / x + x) / 2;
        }
        return z;
    }

    function _mint(address to, uint256 value) internal {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint256 value) internal {
        require(balanceOf[from] >= value, "CozySwap: INSUFFICIENT_BALANCE");
        balanceOf[from] -= value;
        totalSupply -= value;
        emit Transfer(from, address(0), value);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "CozySwap: INSUFFICIENT_BALANCE");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(balanceOf[from] >= value, "CozySwap: INSUFFICIENT_BALANCE");
        uint256 currentAllowance = allowance[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= value, "CozySwap: INSUFFICIENT_ALLOWANCE");
            allowance[from][msg.sender] = currentAllowance - value;
        }
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
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