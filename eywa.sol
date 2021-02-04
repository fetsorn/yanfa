pragma solidity 0.5.12;

// contract BPool is BBronze, BToken, BMath {

    struct Record {
        bool bound;   // is token bound to pool
        uint index;   // private
        uint denorm;  // denormalized weight
        uint balance;
        Types.RStatus RStatus;
        uint taretTokenAmount;
        uint balanceLimit;
    }

    event LOG_SWAP(
        address indexed caller,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256         tokenAmountIn,
        uint256         tokenAmountOut
    );

    event LOG_JOIN(
        address indexed caller,
        address indexed tokenIn,
        uint256         tokenAmountIn
    );

    event LOG_EXIT(
        address indexed caller,
        address indexed tokenOut,
        uint256         tokenAmountOut
    );

    event LOG_CALL(
        bytes4  indexed sig,
        address indexed caller,
        bytes           data
    ) anonymous;

    modifier _logs_() {
        emit LOG_CALL(msg.sig, msg.sender, msg.data);
        _;
    }

    modifier _lock_() {
        require(!_mutex, "ERR_REENTRY");
        _mutex = true;
        _;
        _mutex = false;
    }

    modifier _viewlock_() {
        require(!_mutex, "ERR_REENTRY");
        _;
    }

    bool private _mutex;

    address private _factory;    // BFactory address to push token exitFee to
    address private _controller; // has CONTROL role
    bool private _publicSwap; // true if PUBLIC can call SWAP functions

    // `setSwapFee` and `finalize` require CONTROL
    // `finalize` sets `PUBLIC can SWAP`, `PUBLIC can JOIN`
    uint private _swapFee;
    bool private _finalized;

    address[] private _tokens;

    mapping(address=>Record) private  _records;

    uint private _totalWeight;

    constructor() public {
        _controller = msg.sender;
        _factory = msg.sender;
        _swapFee = MIN_FEE;
        _publicSwap = false;
        _finalized = false;
    }

    function isPublicSwap()
        external view
        returns (bool)
    {
        return _publicSwap;
    }

    function isFinalized()
        external view
        returns (bool)
    {
        return _finalized;
    }

    function isBound(address t)
        external view
        returns (bool)
    {
        return _records[t].bound;
    }

    function getNumTokens()
        external view
        returns (uint)
    {
        return _tokens.length;
    }

    function getCurrentTokens()
        external view _viewlock_
        returns (address[] memory tokens)
    {
        return _tokens;
    }

    function getFinalTokens()
        external view
        _viewlock_
        returns (address[] memory tokens)
    {
        require(_finalized, "ERR_NOT_FINALIZED");
        return _tokens;
    }

    function getDenormalizedWeight(address token)
        external view
        _viewlock_
        returns (uint)
    {

        require(_records[token].bound, "ERR_NOT_BOUND");
        return _records[token].denorm;
    }

    function getTotalDenormalizedWeight()
        external view
        _viewlock_
        returns (uint)
    {
        return _totalWeight;
    }

    function getNormalizedWeight(address token)
        external view
        _viewlock_
        returns (uint)
    {

        require(_records[token].bound, "ERR_NOT_BOUND");
        uint denorm = _records[token].denorm;
        return bdiv(denorm, _totalWeight);
    }

    function getBalance(address token)
        external view
        _viewlock_
        returns (uint)
    {

        require(_records[token].bound, "ERR_NOT_BOUND");
        return _records[token].balance;
    }

    function getSwapFee()
        external view
        _viewlock_
        returns (uint)
    {
        return _swapFee;
    }

    function getController()
        external view
        _viewlock_
        returns (address)
    {
        return _controller;
    }

    function setSwapFee(uint swapFee)
        external
        _logs_
        _lock_
    {
        require(!_finalized, "ERR_IS_FINALIZED");
        require(msg.sender == _controller, "ERR_NOT_CONTROLLER");
        require(swapFee >= MIN_FEE, "ERR_MIN_FEE");
        require(swapFee <= MAX_FEE, "ERR_MAX_FEE");
        _swapFee = swapFee;
    }

    function setController(address manager)
        external
        _logs_
        _lock_
    {
        require(msg.sender == _controller, "ERR_NOT_CONTROLLER");
        _controller = manager;
    }

    function setPublicSwap(bool public_)
        external
        _logs_
        _lock_
    {
        require(!_finalized, "ERR_IS_FINALIZED");
        require(msg.sender == _controller, "ERR_NOT_CONTROLLER");
        _publicSwap = public_;
    }

    function finalize()
        external
        _logs_
        _lock_
    {
        require(msg.sender == _controller, "ERR_NOT_CONTROLLER");
        require(!_finalized, "ERR_IS_FINALIZED");
        require(_tokens.length >= MIN_BOUND_TOKENS, "ERR_MIN_TOKENS");

        _finalized = true;
        _publicSwap = true;

        _mintPoolShare(INIT_POOL_SUPPLY);
        _pushPoolShare(msg.sender, INIT_POOL_SUPPLY);
    }


    function bind(address token, uint balance, uint denorm)
        external
        _logs_
        // _lock_  Bind does not lock because it jumps to `rebind`, which does
    {
        require(msg.sender == _controller, "ERR_NOT_CONTROLLER");
        require(!_records[token].bound, "ERR_IS_BOUND");
        require(!_finalized, "ERR_IS_FINALIZED");

        require(_tokens.length < MAX_BOUND_TOKENS, "ERR_MAX_TOKENS");

        _records[token] = Record({
            bound: true,
            index: _tokens.length,
            denorm: 0,    // balance and denorm will be validated
            balance: 0   // and set by `rebind`
        });
        _tokens.push(token);
        rebind(token, balance, denorm);
    }

    function rebind(address token, uint balance, uint denorm)
        public
        _logs_
        _lock_
    {

        require(msg.sender == _controller, "ERR_NOT_CONTROLLER");
        require(_records[token].bound, "ERR_NOT_BOUND");
        require(!_finalized, "ERR_IS_FINALIZED");

        require(denorm >= MIN_WEIGHT, "ERR_MIN_WEIGHT");
        require(denorm <= MAX_WEIGHT, "ERR_MAX_WEIGHT");
        require(balance >= MIN_BALANCE, "ERR_MIN_BALANCE");

        // Adjust the denorm and totalWeight
        uint oldWeight = _records[token].denorm;
        if (denorm > oldWeight) {
            _totalWeight = badd(_totalWeight, bsub(denorm, oldWeight));
            require(_totalWeight <= MAX_TOTAL_WEIGHT, "ERR_MAX_TOTAL_WEIGHT");
        } else if (denorm < oldWeight) {
            _totalWeight = bsub(_totalWeight, bsub(oldWeight, denorm));
        }
        _records[token].denorm = denorm;

        // Adjust the balance record and actual token balance
        uint oldBalance = _records[token].balance;
        _records[token].balance = balance;
        if (balance > oldBalance) {
            _pullUnderlying(token, msg.sender, bsub(balance, oldBalance));
        } else if (balance < oldBalance) {
            // In this case liquidity is being withdrawn, so charge EXIT_FEE
            uint tokenBalanceWithdrawn = bsub(oldBalance, balance);
            uint tokenExitFee = bmul(tokenBalanceWithdrawn, EXIT_FEE);
            _pushUnderlying(token, msg.sender, bsub(tokenBalanceWithdrawn, tokenExitFee));
            _pushUnderlying(token, _factory, tokenExitFee);
        }
    }

    function unbind(address token)
        external
        _logs_
        _lock_
    {

        require(msg.sender == _controller, "ERR_NOT_CONTROLLER");
        require(_records[token].bound, "ERR_NOT_BOUND");
        require(!_finalized, "ERR_IS_FINALIZED");

        uint tokenBalance = _records[token].balance;
        uint tokenExitFee = bmul(tokenBalance, EXIT_FEE);

        _totalWeight = bsub(_totalWeight, _records[token].denorm);

        // Swap the token-to-unbind with the last token,
        // then delete the last token
        uint index = _records[token].index;
        uint last = _tokens.length - 1;
        _tokens[index] = _tokens[last];
        _records[_tokens[index]].index = index;
        _tokens.pop();
        _records[token] = Record({
            bound: false,
            index: 0,
            denorm: 0,
            balance: 0
        });

        _pushUnderlying(token, msg.sender, bsub(tokenBalance, tokenExitFee));
        _pushUnderlying(token, _factory, tokenExitFee);
    }

    // Absorb any tokens that have been sent to this contract into the pool
    function gulp(address token)
        external
        _logs_
        _lock_
    {
        require(_records[token].bound, "ERR_NOT_BOUND");
        _records[token].balance = IERC20(token).balanceOf(address(this));
    }

    function getSpotPrice(address tokenIn, address tokenOut)
        external view
        _viewlock_
        returns (uint spotPrice)
    {
        require(_records[tokenIn].bound, "ERR_NOT_BOUND");
        require(_records[tokenOut].bound, "ERR_NOT_BOUND");
        Record storage inRecord = _records[tokenIn];
        Record storage outRecord = _records[tokenOut];
        return calcSpotPrice(inRecord.balance, inRecord.denorm, outRecord.balance, outRecord.denorm, _swapFee);
    }

    function getSpotPriceSansFee(address tokenIn, address tokenOut)
        external view
        _viewlock_
        returns (uint spotPrice)
    {
        require(_records[tokenIn].bound, "ERR_NOT_BOUND");
        require(_records[tokenOut].bound, "ERR_NOT_BOUND");
        Record storage inRecord = _records[tokenIn];
        Record storage outRecord = _records[tokenOut];
        return calcSpotPrice(inRecord.balance, inRecord.denorm, outRecord.balance, outRecord.denorm, 0);
    }

    function joinPool(uint poolAmountOut, uint[] calldata maxAmountsIn)
        external
        _logs_
        _lock_
    {
        require(_finalized, "ERR_NOT_FINALIZED");

        uint poolTotal = totalSupply();
        uint ratio = bdiv(poolAmountOut, poolTotal);
        require(ratio != 0, "ERR_MATH_APPROX");

        for (uint i = 0; i < _tokens.length; i++) {
            address t = _tokens[i];
            uint bal = _records[t].balance;
            uint tokenAmountIn = bmul(ratio, bal);
            require(tokenAmountIn != 0, "ERR_MATH_APPROX");
            require(tokenAmountIn <= maxAmountsIn[i], "ERR_LIMIT_IN");
            _records[t].balance = badd(_records[t].balance, tokenAmountIn);
            emit LOG_JOIN(msg.sender, t, tokenAmountIn);
            _pullUnderlying(t, msg.sender, tokenAmountIn);
        }
        _mintPoolShare(poolAmountOut);
        _pushPoolShare(msg.sender, poolAmountOut);
    }

    function exitPool(uint poolAmountIn, uint[] calldata minAmountsOut)
        external
        _logs_
        _lock_
    {
        require(_finalized, "ERR_NOT_FINALIZED");

        uint poolTotal = totalSupply();
        uint exitFee = bmul(poolAmountIn, EXIT_FEE);
        uint pAiAfterExitFee = bsub(poolAmountIn, exitFee);
        uint ratio = bdiv(pAiAfterExitFee, poolTotal);
        require(ratio != 0, "ERR_MATH_APPROX");

        _pullPoolShare(msg.sender, poolAmountIn);
        _pushPoolShare(_factory, exitFee);
        _burnPoolShare(pAiAfterExitFee);

        for (uint i = 0; i < _tokens.length; i++) {
            address t = _tokens[i];
            uint bal = _records[t].balance;
            uint tokenAmountOut = bmul(ratio, bal);
            require(tokenAmountOut != 0, "ERR_MATH_APPROX");
            require(tokenAmountOut >= minAmountsOut[i], "ERR_LIMIT_OUT");
            _records[t].balance = bsub(_records[t].balance, tokenAmountOut);
            emit LOG_EXIT(msg.sender, t, tokenAmountOut);
            _pushUnderlying(t, msg.sender, tokenAmountOut);
        }

    }


    function swapExactAmountIn(
        address tokenIn,
        uint tokenAmountIn,
        address tokenOut,
        uint minAmountOut,
        uint maxPrice
    )
        external
        _logs_
        _lock_
        returns (uint tokenAmountOut, uint spotPriceAfter)
    {

        require(_records[tokenIn].bound, "ERR_NOT_BOUND");
        require(_records[tokenOut].bound, "ERR_NOT_BOUND");
        require(_publicSwap, "ERR_SWAP_NOT_PUBLIC");

        Record storage inRecord = _records[address(tokenIn)];
        Record storage outRecord = _records[address(tokenOut)];

        require(tokenAmountIn <= bmul(inRecord.balance, MAX_IN_RATIO), "ERR_MAX_IN_RATIO");

        uint spotPriceBefore = calcSpotPrice(
                                    inRecord.balance,
                                    inRecord.denorm,
                                    outRecord.balance,
                                    outRecord.denorm,
                                    _swapFee
                                );
        require(spotPriceBefore <= maxPrice, "ERR_BAD_LIMIT_PRICE");

        tokenAmountOut = calcOutGivenIn(
                            inRecord.balance,
                            inRecord.denorm,
                            outRecord.balance,
                            outRecord.denorm,
                            tokenAmountIn,
                            _swapFee
                        );
        require(tokenAmountOut >= minAmountOut, "ERR_LIMIT_OUT");

        inRecord.balance = badd(inRecord.balance, tokenAmountIn);
        outRecord.balance = bsub(outRecord.balance, tokenAmountOut);

        spotPriceAfter = calcSpotPrice(
                                inRecord.balance,
                                inRecord.denorm,
                                outRecord.balance,
                                outRecord.denorm,
                                _swapFee
                            );
        require(spotPriceAfter >= spotPriceBefore, "ERR_MATH_APPROX");
        require(spotPriceAfter <= maxPrice, "ERR_LIMIT_PRICE");
        require(spotPriceBefore <= bdiv(tokenAmountIn, tokenAmountOut), "ERR_MATH_APPROX");

        emit LOG_SWAP(msg.sender, tokenIn, tokenOut, tokenAmountIn, tokenAmountOut);

        _pullUnderlying(tokenIn, msg.sender, tokenAmountIn);
        _pushUnderlying(tokenOut, msg.sender, tokenAmountOut);

        return (tokenAmountOut, spotPriceAfter);
    }

    function swapExactAmountOut(
        address tokenIn,
        uint maxAmountIn,
        address tokenOut,
        uint tokenAmountOut,
        uint maxPrice
    )
        external
        _logs_
        _lock_
        returns (uint tokenAmountIn, uint spotPriceAfter)
    {
        require(_records[tokenIn].bound, "ERR_NOT_BOUND");
        require(_records[tokenOut].bound, "ERR_NOT_BOUND");
        require(_publicSwap, "ERR_SWAP_NOT_PUBLIC");

        Record storage inRecord = _records[address(tokenIn)];
        Record storage outRecord = _records[address(tokenOut)];

        require(tokenAmountOut <= bmul(outRecord.balance, MAX_OUT_RATIO), "ERR_MAX_OUT_RATIO");

        uint spotPriceBefore = calcSpotPrice(
                                    inRecord.balance,
                                    inRecord.denorm,
                                    outRecord.balance,
                                    outRecord.denorm,
                                    _swapFee
                                );
        require(spotPriceBefore <= maxPrice, "ERR_BAD_LIMIT_PRICE");

        tokenAmountIn = calcInGivenOut(
                            inRecord.balance,
                            inRecord.denorm,
                            outRecord.balance,
                            outRecord.denorm,
                            tokenAmountOut,
                            _swapFee
                        );
        require(tokenAmountIn <= maxAmountIn, "ERR_LIMIT_IN");

        inRecord.balance = badd(inRecord.balance, tokenAmountIn);
        outRecord.balance = bsub(outRecord.balance, tokenAmountOut);

        spotPriceAfter = calcSpotPrice(
                                inRecord.balance,
                                inRecord.denorm,
                                outRecord.balance,
                                outRecord.denorm,
                                _swapFee
                            );
        require(spotPriceAfter >= spotPriceBefore, "ERR_MATH_APPROX");
        require(spotPriceAfter <= maxPrice, "ERR_LIMIT_PRICE");
        require(spotPriceBefore <= bdiv(tokenAmountIn, tokenAmountOut), "ERR_MATH_APPROX");

        emit LOG_SWAP(msg.sender, tokenIn, tokenOut, tokenAmountIn, tokenAmountOut);

        _pullUnderlying(tokenIn, msg.sender, tokenAmountIn);
        _pushUnderlying(tokenOut, msg.sender, tokenAmountOut);

        return (tokenAmountIn, spotPriceAfter);
    }

    // ============ Trade Functions ============

    function sellBaseToken(
        address base,
        address quote,
        uint256 amount,
        uint256 minReceiveQuote,
        bytes calldata data
    ) external tradeAllowed sellingAllowed gasPriceLimit preventReentrant returns (uint256) {

        Record baseToken = _records[base]; 
        Record quoteToken = _records[quote]; 
        // query price
        (
            uint256 receiveQuote,
            uint256 lpFeeQuote,
            uint256 mtFeeQuote,
            Types.RStatus newRStatus,
            uint256 newQuoteTarget,
            uint256 newBaseTarget
        ) = _querySellBaseToken(baseToken, quoteToken, amount);
        require(receiveQuote >= minReceiveQuote, "SELL_BASE_RECEIVE_NOT_ENOUGH");

        // settle assets
        _quoteTokenTransferOut(quoteToken, quote, msg.sender, receiveQuote);
        // if (data.length > 0) {
        //     IDODOCallee(msg.sender).dodoCall(false, amount, receiveQuote, data);
        // }
        _baseTokenTransferIn(baseToken, base, msg.sender, amount);
        // if (mtFeeQuote != 0) {
        //     _quoteTokenTransferOut(_MAINTAINER_, mtFeeQuote);
        //     emit ChargeMaintainerFee(_MAINTAINER_, false, mtFeeQuote);
        }

        // update TARGET
        if (quoteToken.taretTokenAmount != newQuoteTarget) {
            quoteToken.taretTokenAmount = newQuoteTarget;
        }
        if (baseToken.taretTokenAmount != newBaseTarget) {
            baseToken.taretTokenAmount = newBaseTarget;
        }
        if (baseToken.RStatus != newRStatus) {
            baseToken.RStatus = newRStatus;
        }

        // _donateQuoteToken(lpFeeQuote);
        emit SellBaseToken(msg.sender, baseToken, quoteToken, amount, receiveQuote);

        return receiveQuote;
    }

    function buyBaseToken(
        uint256 amount,
        uint256 maxPayQuote,
        bytes calldata data
    ) external tradeAllowed buyingAllowed gasPriceLimit preventReentrant returns (uint256) {
        // query price
        (
            uint256 payQuote,
            uint256 lpFeeBase,
            uint256 mtFeeBase,
            Types.RStatus newRStatus,
            uint256 newQuoteTarget,
            uint256 newBaseTarget
        ) = _queryBuyBaseToken(amount);
        require(payQuote <= maxPayQuote, "BUY_BASE_COST_TOO_MUCH");

        // settle assets
        _baseTokenTransferOut(msg.sender, amount);
        if (data.length > 0) {
            IDODOCallee(msg.sender).dodoCall(true, amount, payQuote, data);
        }
        _quoteTokenTransferIn(msg.sender, payQuote);
        if (mtFeeBase != 0) {
            _baseTokenTransferOut(_MAINTAINER_, mtFeeBase);
            emit ChargeMaintainerFee(_MAINTAINER_, true, mtFeeBase);
        }

        // update TARGET
        if (_TARGET_QUOTE_TOKEN_AMOUNT_ != newQuoteTarget) {
            _TARGET_QUOTE_TOKEN_AMOUNT_ = newQuoteTarget;
        }
        if (_TARGET_BASE_TOKEN_AMOUNT_ != newBaseTarget) {
            _TARGET_BASE_TOKEN_AMOUNT_ = newBaseTarget;
        }
        if (_R_STATUS_ != newRStatus) {
            _R_STATUS_ = newRStatus;
        }

        _donateBaseToken(lpFeeBase);
        emit BuyBaseToken(msg.sender, amount, payQuote);

        return payQuote;
    }

    // ============ Query Functions ============

    function querySellBaseToken(Record baseToken, Record quoteToken, uint256 amount) external view returns (uint256 receiveQuote) {
        (receiveQuote, , , , , ) = _querySellBaseToken(Record baseToken, Record quoteToken, amount);
        return receiveQuote;
    }

    function queryBuyBaseToken(uint256 amount) external view returns (uint256 payQuote) {
        (payQuote, , , , , ) = _queryBuyBaseToken(amount);
        return payQuote;
    }

    function _querySellBaseToken(Record baseToken, Record quoteToken, uint256 amount)
        internal
        view
        returns (
            uint256 receiveQuote,
            uint256 lpFeeQuote,
            uint256 mtFeeQuote,
            Types.RStatus newRStatus,
            uint256 newQuoteTarget,
            uint256 newBaseTarget
        )
    {
        // TODO: insert in full
        (newBaseTarget, newQuoteTarget) = getExpectedTarget(baseToken, quoteToken);

        uint256 sellBaseAmount = amount;

        if (baseToken.RStatus == Types.RStatus.ONE) {
            // case 1: R=1
            // R falls below one
            receiveQuote = _ROneSellBaseToken(sellBaseAmount, newQuoteTarget);
            newRStatus = Types.RStatus.BELOW_ONE;
        } else if (baseToken.RStatus == Types.RStatus.ABOVE_ONE) {
            uint256 backToOnePayBase = newBaseTarget.sub(baseToken.balance);
            uint256 backToOneReceiveQuote = quoteToken.balance.sub(newQuoteTarget);
            // case 2: R>1
            // complex case, R status depends on trading amount
            if (sellBaseAmount < backToOnePayBase) {
                // case 2.1: R status do not change
                receiveQuote = _RAboveSellBaseToken(sellBaseAmount, baseToken.balance, newBaseTarget);
                newRStatus = Types.RStatus.ABOVE_ONE;
                if (receiveQuote > backToOneReceiveQuote) {
                    // [Important corner case!] may enter this branch when some precision problem happens. And consequently contribute to negative spare quote amount
                    // to make sure spare quote>=0, mannually set receiveQuote=backToOneReceiveQuote
                    receiveQuote = backToOneReceiveQuote;
                }
            } else if (sellBaseAmount == backToOnePayBase) {
                // case 2.2: R status changes to ONE
                receiveQuote = backToOneReceiveQuote;
                newRStatus = Types.RStatus.ONE;
            } else {
                // case 2.3: R status changes to BELOW_ONE
                receiveQuote = backToOneReceiveQuote.add(
                    _ROneSellBaseToken(sellBaseAmount.sub(backToOnePayBase), newQuoteTarget)
                );
                newRStatus = Types.RStatus.BELOW_ONE;
            }
        } else {
            // _R_STATUS_ == Types.RStatus.BELOW_ONE
            // case 3: R<1
            receiveQuote = _RBelowSellBaseToken(sellBaseAmount, quoteToken.balance, newQuoteTarget);
            newRStatus = Types.RStatus.BELOW_ONE;
        }

        // count fees
        // lpFeeQuote = DecimalMath.mul(receiveQuote, _LP_FEE_RATE_);
        // mtFeeQuote = DecimalMath.mul(receiveQuote, _MT_FEE_RATE_);
        // receiveQuote = receiveQuote.sub(lpFeeQuote).sub(mtFeeQuote);
        receiveQuote = receiveQuote;

        // return (receiveQuote, lpFeeQuote, mtFeeQuote, newRStatus, newQuoteTarget, newBaseTarget);
        return (receiveQuote, newRStatus, newQuoteTarget, newBaseTarget);
    }

    function _queryBuyBaseToken(uint256 amount)
        internal
        view
        returns (
            uint256 payQuote,
            uint256 lpFeeBase,
            uint256 mtFeeBase,
            Types.RStatus newRStatus,
            uint256 newQuoteTarget,
            uint256 newBaseTarget
        )
    {
        (newBaseTarget, newQuoteTarget) = getExpectedTarget();

        // charge fee from user receive amount
        // lpFeeBase = DecimalMath.mul(amount, 0.3);
        // mtFeeBase = DecimalMath.mul(amount, _MT_FEE_RATE_);
        // uint256 buyBaseAmount = amount.add(lpFeeBase).add(mtFeeBase);
        uint256 buyBaseAmount = amount;

        if (baseToken == Types.RStatus.ONE) {
            // case 1: R=1
            payQuote = _ROneBuyBaseToken(buyBaseAmount, newBaseTarget);
            newRStatus = Types.RStatus.ABOVE_ONE;
        } else if (_R_STATUS_ == Types.RStatus.ABOVE_ONE) {
            // case 2: R>1
            payQuote = _RAboveBuyBaseToken(buyBaseAmount, _BASE_BALANCE_, newBaseTarget);
            newRStatus = Types.RStatus.ABOVE_ONE;
        } else if (_R_STATUS_ == Types.RStatus.BELOW_ONE) {
            uint256 backToOnePayQuote = newQuoteTarget.sub(_QUOTE_BALANCE_);
            uint256 backToOneReceiveBase = _BASE_BALANCE_.sub(newBaseTarget);
            // case 3: R<1
            // complex case, R status may change
            if (buyBaseAmount < backToOneReceiveBase) {
                // case 3.1: R status do not change
                // no need to check payQuote because spare base token must be greater than zero
                payQuote = _RBelowBuyBaseToken(buyBaseAmount, _QUOTE_BALANCE_, newQuoteTarget);
                newRStatus = Types.RStatus.BELOW_ONE;
            } else if (buyBaseAmount == backToOneReceiveBase) {
                // case 3.2: R status changes to ONE
                payQuote = backToOnePayQuote;
                newRStatus = Types.RStatus.ONE;
            } else {
                // case 3.3: R status changes to ABOVE_ONE
                payQuote = backToOnePayQuote.add(
                    _ROneBuyBaseToken(buyBaseAmount.sub(backToOneReceiveBase), newBaseTarget)
                );
                newRStatus = Types.RStatus.ABOVE_ONE;
            }
        }

        return (payQuote, lpFeeBase, mtFeeBase, newRStatus, newQuoteTarget, newBaseTarget);
    }


    function joinswapExternAmountIn(address tokenIn, uint tokenAmountIn, uint minPoolAmountOut)
        external
        _logs_
        _lock_
        returns (uint poolAmountOut)

    {
        require(_finalized, "ERR_NOT_FINALIZED");
        require(_records[tokenIn].bound, "ERR_NOT_BOUND");
        require(tokenAmountIn <= bmul(_records[tokenIn].balance, MAX_IN_RATIO), "ERR_MAX_IN_RATIO");

        Record storage inRecord = _records[tokenIn];

        poolAmountOut = calcPoolOutGivenSingleIn(
                            inRecord.balance,
                            inRecord.denorm,
                            _totalSupply,
                            _totalWeight,
                            tokenAmountIn,
                            _swapFee
                        );

        require(poolAmountOut >= minPoolAmountOut, "ERR_LIMIT_OUT");

        inRecord.balance = badd(inRecord.balance, tokenAmountIn);

        emit LOG_JOIN(msg.sender, tokenIn, tokenAmountIn);

        _mintPoolShare(poolAmountOut);
        _pushPoolShare(msg.sender, poolAmountOut);
        _pullUnderlying(tokenIn, msg.sender, tokenAmountIn);

        return poolAmountOut;
    }

    function joinswapPoolAmountOut(address tokenIn, uint poolAmountOut, uint maxAmountIn)
        external
        _logs_
        _lock_
        returns (uint tokenAmountIn)
    {
        require(_finalized, "ERR_NOT_FINALIZED");
        require(_records[tokenIn].bound, "ERR_NOT_BOUND");

        Record storage inRecord = _records[tokenIn];

        tokenAmountIn = calcSingleInGivenPoolOut(
                            inRecord.balance,
                            inRecord.denorm,
                            _totalSupply,
                            _totalWeight,
                            poolAmountOut,
                            _swapFee
                        );

        require(tokenAmountIn != 0, "ERR_MATH_APPROX");
        require(tokenAmountIn <= maxAmountIn, "ERR_LIMIT_IN");

        require(tokenAmountIn <= bmul(_records[tokenIn].balance, MAX_IN_RATIO), "ERR_MAX_IN_RATIO");

        inRecord.balance = badd(inRecord.balance, tokenAmountIn);

        emit LOG_JOIN(msg.sender, tokenIn, tokenAmountIn);

        _mintPoolShare(poolAmountOut);
        _pushPoolShare(msg.sender, poolAmountOut);
        _pullUnderlying(tokenIn, msg.sender, tokenAmountIn);

        return tokenAmountIn;
    }

    function exitswapPoolAmountIn(address tokenOut, uint poolAmountIn, uint minAmountOut)
        external
        _logs_
        _lock_
        returns (uint tokenAmountOut)
    {
        require(_finalized, "ERR_NOT_FINALIZED");
        require(_records[tokenOut].bound, "ERR_NOT_BOUND");

        Record storage outRecord = _records[tokenOut];

        tokenAmountOut = calcSingleOutGivenPoolIn(
                            outRecord.balance,
                            outRecord.denorm,
                            _totalSupply,
                            _totalWeight,
                            poolAmountIn,
                            _swapFee
                        );

        require(tokenAmountOut >= minAmountOut, "ERR_LIMIT_OUT");

        require(tokenAmountOut <= bmul(_records[tokenOut].balance, MAX_OUT_RATIO), "ERR_MAX_OUT_RATIO");

        outRecord.balance = bsub(outRecord.balance, tokenAmountOut);

        uint exitFee = bmul(poolAmountIn, EXIT_FEE);

        emit LOG_EXIT(msg.sender, tokenOut, tokenAmountOut);

        _pullPoolShare(msg.sender, poolAmountIn);
        _burnPoolShare(bsub(poolAmountIn, exitFee));
        _pushPoolShare(_factory, exitFee);
        _pushUnderlying(tokenOut, msg.sender, tokenAmountOut);

        return tokenAmountOut;
    }

    function exitswapExternAmountOut(address tokenOut, uint tokenAmountOut, uint maxPoolAmountIn)
        external
        _logs_
        _lock_
        returns (uint poolAmountIn)
    {
        require(_finalized, "ERR_NOT_FINALIZED");
        require(_records[tokenOut].bound, "ERR_NOT_BOUND");
        require(tokenAmountOut <= bmul(_records[tokenOut].balance, MAX_OUT_RATIO), "ERR_MAX_OUT_RATIO");

        Record storage outRecord = _records[tokenOut];

        poolAmountIn = calcPoolInGivenSingleOut(
                            outRecord.balance,
                            outRecord.denorm,
                            _totalSupply,
                            _totalWeight,
                            tokenAmountOut,
                            _swapFee
                        );

        require(poolAmountIn != 0, "ERR_MATH_APPROX");
        require(poolAmountIn <= maxPoolAmountIn, "ERR_LIMIT_IN");

        outRecord.balance = bsub(outRecord.balance, tokenAmountOut);

        uint exitFee = bmul(poolAmountIn, EXIT_FEE);

        emit LOG_EXIT(msg.sender, tokenOut, tokenAmountOut);

        _pullPoolShare(msg.sender, poolAmountIn);
        _burnPoolShare(bsub(poolAmountIn, exitFee));
        _pushPoolShare(_factory, exitFee);
        _pushUnderlying(tokenOut, msg.sender, tokenAmountOut);

        return poolAmountIn;
    }


    // ==
    // 'Underlying' token-manipulation functions make external calls but are NOT locked
    // You must `_lock_` or otherwise ensure reentry-safety

    function _pullUnderlying(address erc20, address from, uint amount)
        internal
    {
        bool xfer = IERC20(erc20).transferFrom(from, address(this), amount);
        require(xfer, "ERR_ERC20_FALSE");
    }

    function _pushUnderlying(address erc20, address to, uint amount)
        internal
    {
        bool xfer = IERC20(erc20).transfer(to, amount);
        require(xfer, "ERR_ERC20_FALSE");
    }

    function _pullPoolShare(address from, uint amount)
        internal
    {
        _pull(from, amount);
    }

    function _pushPoolShare(address to, uint amount)
        internal
    {
        _push(to, amount);
    }

    function _mintPoolShare(uint amount)
        internal
    {
        _mint(amount);
    }

    function _burnPoolShare(uint amount)
        internal
    {
        _burn(amount);
    }

}

contract Pricing is Storage {
    using SafeMath for uint256;

    // ============ R = 1 cases ============

    function _ROneSellBaseToken(uint256 amount, uint256 targetQuoteTokenAmount)
        internal
        view
        returns (uint256 receiveQuoteToken)
    {
        uint256 i = getOraclePrice();
        uint256 Q2 = DODOMath._SolveQuadraticFunctionForTrade(
            targetQuoteTokenAmount,
            targetQuoteTokenAmount,
            DecimalMath.mul(i, amount),
            false,
            _K_
        );
        // in theory Q2 <= targetQuoteTokenAmount
        // however when amount is close to 0, precision problems may cause Q2 > targetQuoteTokenAmount
        return targetQuoteTokenAmount.sub(Q2);
    }

    function _ROneBuyBaseToken(uint256 amount, uint256 targetBaseTokenAmount)
        internal
        view
        returns (uint256 payQuoteToken)
    {
        require(amount < targetBaseTokenAmount, "DODO_BASE_BALANCE_NOT_ENOUGH");
        uint256 B2 = targetBaseTokenAmount.sub(amount);
        payQuoteToken = _RAboveIntegrate(targetBaseTokenAmount, targetBaseTokenAmount, B2);
        return payQuoteToken;
    }

    // ============ R < 1 cases ============

    function _RBelowSellBaseToken(
        uint256 amount,
        uint256 quoteBalance,
        uint256 targetQuoteAmount
    ) internal view returns (uint256 receieQuoteToken) {
        uint256 i = getOraclePrice();
        uint256 Q2 = DODOMath._SolveQuadraticFunctionForTrade(
            targetQuoteAmount,
            quoteBalance,
            DecimalMath.mul(i, amount),
            false,
            _K_
        );
        return quoteBalance.sub(Q2);
    }

    function _RBelowBuyBaseToken(
        uint256 amount,
        uint256 quoteBalance,
        uint256 targetQuoteAmount
    ) internal view returns (uint256 payQuoteToken) {
        // Here we don't require amount less than some value
        // Because it is limited at upper function
        // See Trader.queryBuyBaseToken
        uint256 i = getOraclePrice();
        uint256 Q2 = DODOMath._SolveQuadraticFunctionForTrade(
            targetQuoteAmount,
            quoteBalance,
            DecimalMath.mulCeil(i, amount),
            true,
            _K_
        );
        return Q2.sub(quoteBalance);
    }

    function _RBelowBackToOne(Record baseToken, Record quoteToken) internal view returns (uint256 payQuoteToken) {
        // important: carefully design the system to make sure spareBase always greater than or equal to 0
        uint256 spareBase = baseToken.balance.sub(baseToken.taretTokenAmount);
        uint256 price = getOraclePrice();
        uint256 fairAmount = DecimalMath.mul(spareBase, price);
        uint256 newTargetQuote = DODOMath._SolveQuadraticFunctionForTarget(
            baseToken.balance,
            _K_
            fairAmount
        );
        return newTargetQuote.sub(_QUOTE_BALANCE_);
    }

    // ============ R > 1 cases ============

    function _RAboveBuyBaseToken(
        uint256 amount,
        uint256 baseBalance,
        uint256 targetBaseAmount
    ) internal view returns (uint256 payQuoteToken) {
        require(amount < baseBalance, "DODO_BASE_BALANCE_NOT_ENOUGH");
        uint256 B2 = baseBalance.sub(amount);
        return _RAboveIntegrate(targetBaseAmount, baseBalance, B2);
    }

    function _RAboveSellBaseToken(
        uint256 amount,
        uint256 baseBalance,
        uint256 targetBaseAmount
    ) internal view returns (uint256 receiveQuoteToken) {
        // here we don't require B1 <= targetBaseAmount
        // Because it is limited at upper function
        // See Trader.querySellBaseToken
        uint256 B1 = baseBalance.add(amount);
        return _RAboveIntegrate(targetBaseAmount, B1, baseBalance);
    }

    function _RAboveBackToOne(Record baseToken, Record quoteToken) internal view returns (uint256 payBaseToken) {
        // important: carefully design the system to make sure spareBase always greater than or equal to 0
        uint256 spareQuote = quoteToken.balance.sub(quoteToken.taretTokenAmount);
        uint256 price = getOraclePrice();
        uint256 fairAmount = DecimalMath.divFloor(spareQuote, price);
        uint256 newTargetBase = DODOMath._SolveQuadraticFunctionForTarget(
            baseToken.balance,
            _K_
            fairAmount
        );
        return newTargetBase.sub(_BASE_BALANCE_);
    }

    // ============ Helper functions ============

    function getExpectedTarget(Record baseToken, Record quoteToken) public view returns (uint256 baseTarget, uint256 quoteTarget) {
        uint256 Q = quoteToken.balance;
        uint256 B = baseToken.balance;
        if (B.RStatus == Types.RStatus.ONE) {
            return (baseToken.taretTokenAmount, quoteToken.taretTokenAmount);
        } else if (baseToken.RStatus == Types.RStatus.BELOW_ONE) {
            uint256 payQuoteToken = _RBelowBackToOne(baseToken, quoteToken);
            return (baseToken.taretTokenAmount, Q.add(payQuoteToken));
        } else if (baseToken.RStatus == Types.RStatus.ABOVE_ONE) {
            uint256 payBaseToken = _RAboveBackToOne(baseToken, quoteToken);
            return (B.add(payBaseToken), quoteToken.taretTokenAmount);
        }
    }

    function getMidPrice() public view returns (uint256 midPrice) {
        (uint256 baseTarget, uint256 quoteTarget) = getExpectedTarget();
        if (_R_STATUS_ == Types.RStatus.BELOW_ONE) {
            uint256 R = DecimalMath.divFloor(
                quoteTarget.mul(quoteTarget).div(_QUOTE_BALANCE_),
                _QUOTE_BALANCE_
            );
            R = DecimalMath.ONE.sub(_K_).add(DecimalMath.mul(_K_, R));
            return DecimalMath.divFloor(getOraclePrice(), R);
        } else {
            uint256 R = DecimalMath.divFloor(
                baseTarget.mul(baseTarget).div(_BASE_BALANCE_),
                _BASE_BALANCE_
            );
            R = DecimalMath.ONE.sub(_K_).add(DecimalMath.mul(_K_, R));
            return DecimalMath.mul(getOraclePrice(), R);
        }
    }

    function _RAboveIntegrate(
        uint256 B0,
        uint256 B1,
        uint256 B2
    ) internal view returns (uint256) {
        uint256 i = getOraclePrice();
        return DODOMath._GeneralIntegrate(B0, B1, B2, i, _K_;
    }

    // function _RBelowIntegrate(
    //     uint256 Q0,
    //     uint256 Q1,
    //     uint256 Q2
    // ) internal view returns (uint256) {
    //     uint256 i = getOraclePrice();
    //     i = DecimalMath.divFloor(DecimalMath.ONE, i); // 1/i
    //     return DODOMath._GeneralIntegrate(Q0, Q1, Q2, i, _K_);
    // }
}

contract Settlement is Storage {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // ============ Events ============

    event Donate(uint256 amount, bool isBaseToken);

    event ClaimAssets(address indexed user, uint256 baseTokenAmount, uint256 quoteTokenAmount);

    // ============ Assets IN/OUT Functions ============

    function _baseTokenTransferIn(Record baseToken, address base, address from, uint256 amount) internal {
        require(baseToken.balance.add(amount) <= baseToken.balanceLimit, "BASE_BALANCE_LIMIT_EXCEEDED");
        IERC20(base).safeTransferFrom(from, address(this), amount);
        baseToken.balance = baseToken.balance.add(amount);
    }

    function _quoteTokenTransferIn(Record quoteToken, address quote, address from, uint256 amount) internal {
        require(
            quoteToken.balance.add(amount) <= quoteToken.balanceLimit,
            "QUOTE_BALANCE_LIMIT_EXCEEDED"
        );
        IERC20(quote).safeTransferFrom(from, address(this), amount);
        quoteToken.balance = quoteToken.balance.add(amount);
    }

    function _baseTokenTransferOut(Record baseToken, address base, address to, uint256 amount) internal {
        IERC20(base).safeTransfer(to, amount);
        baseToken.balance = baseToken.balance.sub(amount);
    }

    function _quoteTokenTransferOut(Record quoteToken, address quote, address to, uint256 amount) internal {
        IERC20(quote).safeTransfer(to, amount);
        quoteToken.balance = quoteToken.balance.sub(amount);
    }

    // ============ Donate to Liquidity Pool Functions ============

    function _donateBaseToken(uint256 amount) internal {
        _TARGET_BASE_TOKEN_AMOUNT_ = _TARGET_BASE_TOKEN_AMOUNT_.add(amount);
        emit Donate(amount, true);
    }

    function _donateQuoteToken(uint256 amount) internal {
        _TARGET_QUOTE_TOKEN_AMOUNT_ = _TARGET_QUOTE_TOKEN_AMOUNT_.add(amount);
        emit Donate(amount, false);
    }

    function donateBaseToken(uint256 amount) external preventReentrant {
        _baseTokenTransferIn(msg.sender, amount);
        _donateBaseToken(amount);
    }

    function donateQuoteToken(uint256 amount) external preventReentrant {
        _quoteTokenTransferIn(msg.sender, amount);
        _donateQuoteToken(amount);
    }

    // ============ Final Settlement Functions ============

    // last step to shut down dodo
    function finalSettlement() external onlyOwner notClosed {
        _CLOSED_ = true;
        _DEPOSIT_QUOTE_ALLOWED_ = false;
        _DEPOSIT_BASE_ALLOWED_ = false;
        _TRADE_ALLOWED_ = false;
        uint256 totalBaseCapital = getTotalBaseCapital();
        uint256 totalQuoteCapital = getTotalQuoteCapital();

        if (_QUOTE_BALANCE_ > _TARGET_QUOTE_TOKEN_AMOUNT_) {
            uint256 spareQuote = _QUOTE_BALANCE_.sub(_TARGET_QUOTE_TOKEN_AMOUNT_);
            _BASE_CAPITAL_RECEIVE_QUOTE_ = DecimalMath.divFloor(spareQuote, totalBaseCapital);
        } else {
            _TARGET_QUOTE_TOKEN_AMOUNT_ = _QUOTE_BALANCE_;
        }

        if (_BASE_BALANCE_ > _TARGET_BASE_TOKEN_AMOUNT_) {
            uint256 spareBase = _BASE_BALANCE_.sub(_TARGET_BASE_TOKEN_AMOUNT_);
            _QUOTE_CAPITAL_RECEIVE_BASE_ = DecimalMath.divFloor(spareBase, totalQuoteCapital);
        } else {
            _TARGET_BASE_TOKEN_AMOUNT_ = _BASE_BALANCE_;
        }

        _R_STATUS_ = Types.RStatus.ONE;
    }

    // claim remaining assets after final settlement
    function claimAssets() external preventReentrant {
        require(_CLOSED_, "DODO_NOT_CLOSED");
        require(!_CLAIMED_[msg.sender], "ALREADY_CLAIMED");
        _CLAIMED_[msg.sender] = true;

        uint256 quoteCapital = getQuoteCapitalBalanceOf(msg.sender);
        uint256 baseCapital = getBaseCapitalBalanceOf(msg.sender);

        uint256 quoteAmount = 0;
        if (quoteCapital > 0) {
            quoteAmount = _TARGET_QUOTE_TOKEN_AMOUNT_.mul(quoteCapital).div(getTotalQuoteCapital());
        }
        uint256 baseAmount = 0;
        if (baseCapital > 0) {
            baseAmount = _TARGET_BASE_TOKEN_AMOUNT_.mul(baseCapital).div(getTotalBaseCapital());
        }

        _TARGET_QUOTE_TOKEN_AMOUNT_ = _TARGET_QUOTE_TOKEN_AMOUNT_.sub(quoteAmount);
        _TARGET_BASE_TOKEN_AMOUNT_ = _TARGET_BASE_TOKEN_AMOUNT_.sub(baseAmount);

        quoteAmount = quoteAmount.add(DecimalMath.mul(baseCapital, _BASE_CAPITAL_RECEIVE_QUOTE_));
        baseAmount = baseAmount.add(DecimalMath.mul(quoteCapital, _QUOTE_CAPITAL_RECEIVE_BASE_));

        _baseTokenTransferOut(msg.sender, baseAmount);
        _quoteTokenTransferOut(msg.sender, quoteAmount);

        IDODOLpToken(_BASE_CAPITAL_TOKEN_).burn(msg.sender, baseCapital);
        IDODOLpToken(_QUOTE_CAPITAL_TOKEN_).burn(msg.sender, quoteCapital);

        emit ClaimAssets(msg.sender, baseAmount, quoteAmount);
        return;
    }

    // in case someone transfer to contract directly
    function retrieve(address token, uint256 amount) external onlyOwner {
        if (token == _BASE_TOKEN_) {
            require(
                IERC20(_BASE_TOKEN_).balanceOf(address(this)) >= _BASE_BALANCE_.add(amount),
                "DODO_BASE_BALANCE_NOT_ENOUGH"
            );
        }
        if (token == _QUOTE_TOKEN_) {
            require(
                IERC20(_QUOTE_TOKEN_).balanceOf(address(this)) >= _QUOTE_BALANCE_.add(amount),
                "DODO_QUOTE_BALANCE_NOT_ENOUGH"
            );
        }
        IERC20(token).safeTransfer(msg.sender, amount);
    }
}
