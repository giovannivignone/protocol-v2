// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.6.8;


import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CoreLibrary} from "./CoreLibrary.sol";
import {ReserveLogic} from "./ReserveLogic.sol";
import {UserLogic} from "./UserLogic.sol";
import {GenericLogic} from "./GenericLogic.sol";
import {WadRayMath} from "./WadRayMath.sol";
import {UniversalERC20} from "./UniversalERC20.sol";

import {IPriceOracleGetter} from "../interfaces/IPriceOracleGetter.sol";
import {IFeeProvider} from "../interfaces/IFeeProvider.sol";
import "@nomiclabs/buidler/console.sol";

library ValidationLogic {
    using ReserveLogic for CoreLibrary.ReserveData;
    using UserLogic for CoreLibrary.UserReserveData;
    using SafeMath for uint256;
    using WadRayMath for uint256;
    using UniversalERC20 for IERC20;

    function validateDeposit(CoreLibrary.ReserveData storage _reserve, uint256 _amount)
        external
        view
    {
        validateReserveStateAndAmount(_reserve, _amount);
    }

    function validateRedeem(
        CoreLibrary.ReserveData storage _reserve,
        address _reserveAddress,
        uint256 _amount
    ) external view {
        validateReserveStateAndAmount(_reserve, _amount);

        require(msg.sender == _reserve.aTokenAddress, "31");

        uint256 currentAvailableLiquidity = IERC20(_reserveAddress).universalBalanceOf(
            address(this)
        );
        require(currentAvailableLiquidity >= _amount, "4");
    }

    struct ValidateBorrowLocalVars {
        uint256 principalBorrowBalance;
        uint256 currentLtv;
        uint256 currentLiquidationThreshold;
        uint256 requestedBorrowAmountETH;
        uint256 amountOfCollateralNeededETH;
        uint256 userCollateralBalanceETH;
        uint256 userBorrowBalanceETH;
        uint256 userTotalFeesETH;
        uint256 borrowBalanceIncrease;
        uint256 currentReserveStableRate;
        uint256 availableLiquidity;
        uint256 finalUserBorrowRate;
        CoreLibrary.InterestRateMode rateMode;
        bool healthFactorBelowThreshold;
    }

    function validateBorrow(
        CoreLibrary.ReserveData storage _reserve,
        CoreLibrary.UserReserveData storage _user,
        address _reserveAddress,
        uint256 _amount,
        uint256 _amountInETH,
        uint256 _interestRateMode,
        uint256 _borrowFee,
        uint256 _maxStableLoanPercent,
        mapping(address => CoreLibrary.ReserveData) storage _reservesData,
        mapping(address => mapping(address => CoreLibrary.UserReserveData)) storage _usersData,
        address[] calldata _reserves,
        address _oracle
    ) external view {
        ValidateBorrowLocalVars memory vars;


        validateReserveStateAndAmount(_reserve, _amount);

        require(_reserve.borrowingEnabled, "5");

        //validate interest rate mode
        require(
            uint256(CoreLibrary.InterestRateMode.VARIABLE) == _interestRateMode ||
                uint256(CoreLibrary.InterestRateMode.STABLE) == _interestRateMode,
            "Invalid interest rate mode selected"
        );

        //check that the amount is available in the reserve
        vars.availableLiquidity = IERC20(_reserveAddress).universalBalanceOf(address(this));

        require(vars.availableLiquidity >= _amount, "7");

        (
            vars.userCollateralBalanceETH,
            vars.userBorrowBalanceETH,
            vars.userTotalFeesETH,
            vars.currentLtv,
            vars.currentLiquidationThreshold,
            vars.healthFactorBelowThreshold
        ) = GenericLogic.calculateUserAccountData(
            msg.sender,
            _reservesData,
            _usersData,
            _reserves,
            _oracle
        );

        require(vars.userCollateralBalanceETH > 0, "The collateral balance is 0");

        require(!vars.healthFactorBelowThreshold, "8");

        require(_borrowFee > 0, "The amount to borrow is too small");

        //add the current already borrowed amount to the amount requested to calculate the total collateral needed.
        vars.amountOfCollateralNeededETH = vars
            .userBorrowBalanceETH
            .add(vars.userTotalFeesETH)
            .add(_amountInETH)
            .mul(100)
            .div(vars.currentLtv); //LTV is calculated in percentage

        require(vars.amountOfCollateralNeededETH <= vars.userCollateralBalanceETH, "There is not enough collateral to cover a new borrow");

        /**
        * Following conditions need to be met if the user is borrowing at a stable rate:
        * 1. Reserve must be enabled for stable rate borrowing
        * 2. Users cannot borrow from the reserve if their collateral is (mostly) the same currency
        *    they are borrowing, to prevent abuses.
        * 3. Users will be able to borrow only a relatively small, configurable amount of the total
        *    liquidity
        **/

        if (vars.rateMode == CoreLibrary.InterestRateMode.STABLE) {
            //check if the borrow mode is stable and if stable rate borrowing is enabled on this reserve

            require(_reserve.isStableBorrowRateEnabled, "11");

            require(
                !_user.useAsCollateral ||
                    !_reserve.usageAsCollateralEnabled ||
                    _amount > IERC20(_reserve.aTokenAddress).balanceOf(msg.sender),
                "12"
            );

            //calculate the max available loan size in stable rate mode as a percentage of the
            //available liquidity
            uint256 maxLoanSizeStable = vars.availableLiquidity.mul(_maxStableLoanPercent).div(100);

            require(_amount <= maxLoanSizeStable, "13");
        }
    }

    function validateRepay(
        CoreLibrary.ReserveData storage _reserve,
        address _reserveAddress,
        uint256 _amountSent,
        address _onBehalfOf,
        uint256 _borrowBalance,
        uint256 _actualPaybackAmount,
        uint256 _msgValue
    ) external view {
        require(_reserve.isActive, "Action requires an active reserve");

        require(_amountSent > 0, "Amount must be greater than 0");

        require(_borrowBalance > 0, "16");

        require(_amountSent != uint256(-1) || msg.sender == _onBehalfOf, "To repay on behalf of an user an explicit amount to repay is needed");

        require(!IERC20(_reserveAddress).isETH() || _msgValue >= _actualPaybackAmount, "Invalid msg.value sent for the repayment");
    }

    function validateSwapRateMode(
        CoreLibrary.ReserveData storage _reserve,
        CoreLibrary.UserReserveData storage _user,
        uint256 _borrowBalance,
        CoreLibrary.InterestRateMode _currentRateMode
    ) external view {
        require(_reserve.isActive, "Action requires an active reserve");
        require(!_reserve.isFreezed, "Action requires an unfreezed reserve");
        require(_borrowBalance > 0, "User does not have a borrow in progress on this reserve");

        if (_currentRateMode == CoreLibrary.InterestRateMode.VARIABLE) {
            /**
            * user wants to swap to stable, before swapping we need to ensure that
            * 1. stable borrow rate is enabled on the reserve
            * 2. user is not trying to abuse the reserve by depositing
            * more collateral than he is borrowing, artificially lowering
            * the interest rate, borrowing at variable, and switching to stable
            **/
            require(_reserve.isStableBorrowRateEnabled, "11");

            require(
                !_user.useAsCollateral ||
                    !_reserve.usageAsCollateralEnabled ||
                    _borrowBalance > IERC20(_reserve.aTokenAddress).balanceOf(msg.sender),
                "12"
            );
        }

    }

    function validateSetUseReserveAsCollateral(
        CoreLibrary.ReserveData storage _reserve,
        address _reserveAddress,
        mapping(address => CoreLibrary.ReserveData) storage _reservesData,
        mapping(address => mapping(address => CoreLibrary.UserReserveData)) storage _usersData,
        address[] calldata _reserves,
        address _oracle
    ) external view {

        uint256 underlyingBalance = IERC20(_reserve.aTokenAddress).balanceOf(msg.sender);

        require(underlyingBalance > 0, "22");

        require(
            GenericLogic.balanceDecreaseAllowed(
                _reserveAddress,
                msg.sender,
                underlyingBalance,
                _reservesData,
                _usersData,
                _reserves,
                _oracle
            ),
            "User deposit is already being used as collateral"
        );

    }

    function validateReserveStateAndAmount(CoreLibrary.ReserveData storage _reserve, uint256 _amount)
        internal
        view
    {
        require(_reserve.isActive, "Action requires an active reserve");
        require(!_reserve.isFreezed, "Action requires an unfreezed reserve");
        require(_amount > 0, "Amount must be greater than 0");

    }
}
