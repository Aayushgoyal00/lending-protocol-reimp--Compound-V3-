// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.15;

// import "../storage/CometStorage.sol";
// import "../math/CometAccounting.sol";
// import "../config/CometConfiguration.sol";
import "./TokenActions.sol";

abstract contract CometBaseActions is TokenActions {

    error BorrowTooSmall();
    error NotCollateralized();

    /**
     * @dev The change in principal broken into repay and supply amounts
     * @dev This function is only about repay & supply, not new borrows.
     */
    function repayAndSupplyAmount(int104 oldPrincipal, int104 newPrincipal) internal pure returns (uint104, uint104) {
        // If the new principal is less than the old principal, then no amount has been repaid or supplied
        if (newPrincipal < oldPrincipal) return (0, 0);

        if (newPrincipal <= 0) {
            return (uint104(newPrincipal - oldPrincipal), 0);
        } else if (oldPrincipal >= 0) {
            return (0, uint104(newPrincipal - oldPrincipal));
        } else {
            return (uint104(-oldPrincipal), uint104(newPrincipal));
        }
    }

    /**
     * @dev The change in principal broken into withdraw and borrow amounts
     * @dev This function is only about withdraw & borrow, not repayments.
     */
    function withdrawAndBorrowAmount(int104 oldPrincipal, int104 newPrincipal) internal pure returns (uint104, uint104) {
        // If the new principal is greater than the old principal, then no amount has been withdrawn or borrowed
        if (newPrincipal > oldPrincipal) return (0, 0);

        if (newPrincipal >= 0) {
            return (uint104(oldPrincipal - newPrincipal), 0);
        } else if (oldPrincipal <= 0) {
            return (0, uint104(oldPrincipal - newPrincipal));
        } else {
            return (uint104(oldPrincipal), uint104(-newPrincipal));
        }
    }

    /**
     * @dev Write updated principal to store and tracking participation
    
     */
    function updateBasePrincipal(address account, UserBasic memory basic, int104 principalNew) internal {
        // int104 principal = basic.principal;
        basic.principal = principalNew;

        //  Commenting the rewards logic for future implementation

        // if (principal >= 0) {
        //     uint indexDelta = uint256(trackingSupplyIndex - basic.baseTrackingIndex);
        //     basic.baseTrackingAccrued += safe64(uint104(principal) * indexDelta / trackingIndexScale / accrualDescaleFactor);
        // } else {
        //     uint indexDelta = uint256(trackingBorrowIndex - basic.baseTrackingIndex);
        //     basic.baseTrackingAccrued += safe64(uint104(-principal) * indexDelta / trackingIndexScale / accrualDescaleFactor);
        // }

        // if (principalNew >= 0) {
        //     basic.baseTrackingIndex = trackingSupplyIndex;
        // } else {
        //     basic.baseTrackingIndex = trackingBorrowIndex;
        // }

        userBasic[account] = basic;
    }

    

    /**
     * @dev Supply an amount of base asset from `from` to dst
     */
    function supplyBase(address from, address dst, uint256 amount) internal {

        amount = doTransferIn(baseToken, from, amount);

        accrueInternal();

        UserBasic memory dstUser = userBasic[dst];
        int104 dstPrincipal = dstUser.principal;
        int256 dstBalance = presentValue(dstPrincipal) + signed256(amount);
        int104 dstPrincipalNew = principalValue(dstBalance);

        (uint104 repayAmount, uint104 supplyAmount) = repayAndSupplyAmount(dstPrincipal, dstPrincipalNew);

        totalSupplyBase += supplyAmount;
        totalBorrowBase -= repayAmount;

        updateBasePrincipal(dst, dstUser, dstPrincipalNew);

        emit Supply(from, dst, amount);

        if (supplyAmount > 0) {
            emit Transfer(address(0), dst, presentValueSupply(baseSupplyIndex, supplyAmount));
        }
    }

        /**
     * @dev Withdraw an amount of base asset from src to `to`, borrowing if possible/necessary
     */
    function withdrawBase(address src, address to, uint256 amount) internal {
        accrueInternal();

        UserBasic memory srcUser = userBasic[src];
        int104 srcPrincipal = srcUser.principal;
        int256 srcBalance = presentValue(srcPrincipal) - signed256(amount);
        int104 srcPrincipalNew = principalValue(srcBalance);

        (uint104 withdrawAmount, uint104 borrowAmount) = withdrawAndBorrowAmount(srcPrincipal, srcPrincipalNew);

        totalSupplyBase -= withdrawAmount;
        totalBorrowBase += borrowAmount;

        updateBasePrincipal(src, srcUser, srcPrincipalNew);

        if (srcBalance < 0) {
            if (uint256(-srcBalance) < baseBorrowMin) revert BorrowTooSmall();


            if (!isBorrowCollateralized(src)) revert NotCollateralized();

        }
        doTransferOut(baseToken, to, amount);

        emit Withdraw(src, to, amount);

        if (withdrawAmount > 0) {
            emit Transfer(src, address(0), presentValueSupply(baseSupplyIndex, withdrawAmount));
        }
    }

        /**
     * @dev Transfer an amount of base asset from src to dst, borrowing if possible/necessary
     */
    function transferBase(address src, address dst, uint256 amount) internal {
        accrueInternal();

        UserBasic memory srcUser = userBasic[src];
        UserBasic memory dstUser = userBasic[dst];

        int104 srcPrincipal = srcUser.principal;
        int104 dstPrincipal = dstUser.principal;
        int256 srcBalance = presentValue(srcPrincipal) - signed256(amount);
        int256 dstBalance = presentValue(dstPrincipal) + signed256(amount);
        int104 srcPrincipalNew = principalValue(srcBalance);
        int104 dstPrincipalNew = principalValue(dstBalance);

        (uint104 withdrawAmount, uint104 borrowAmount) = withdrawAndBorrowAmount(srcPrincipal, srcPrincipalNew);
        (uint104 repayAmount, uint104 supplyAmount) = repayAndSupplyAmount(dstPrincipal, dstPrincipalNew);

        // Note: Instead of `total += addAmount - subAmount` to avoid underflow errors.
        totalSupplyBase = totalSupplyBase + supplyAmount - withdrawAmount;
        totalBorrowBase = totalBorrowBase + borrowAmount - repayAmount;

        updateBasePrincipal(src, srcUser, srcPrincipalNew);
        updateBasePrincipal(dst, dstUser, dstPrincipalNew);

        if (srcBalance < 0) {
            if (uint256(-srcBalance) < baseBorrowMin) revert BorrowTooSmall();
            // will do later
            if (!isBorrowCollateralized(src)) revert NotCollateralized();
        }

        if (withdrawAmount > 0) {
            emit Transfer(src, address(0), presentValueSupply(baseSupplyIndex, withdrawAmount));
        }

        if (supplyAmount > 0) {
            emit Transfer(address(0), dst, presentValueSupply(baseSupplyIndex, supplyAmount));
        }
    }

}