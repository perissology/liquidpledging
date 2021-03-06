pragma solidity ^0.4.11;

import "./LiquidPledgingBase.sol";


contract LiquidPledging is LiquidPledgingBase {


//////
// Constructor
//////

    // This constructor  also calls the constructor for `LiquidPledgingBase`
    function LiquidPledging(address _vault) LiquidPledgingBase(_vault) {
    }

    /// @notice This is how value enters into the system which creates pledges;
    ///  the token of value goes into the vault and the amount in the pledge
    ///  relevant to this Giver without delegates is increased, and a normal
    ///  transfer is done to the idReceiver
    /// @param idGiver Identifier of the giver thats donating.
    /// @param idReceiver To whom it's transfered. Can be the same giver, another
    ///  giver, a delegate or a campaign

function donate(uint64 idGiver, uint64 idReceiver) payable {
        if (idGiver == 0) {
            idGiver = addGiver('', 259200, ILiquidPledgingPlugin(0x0)); // default to 3 day commitTime
        }

        PledgeManager storage sender = findManager(idGiver);

        checkManagerOwner(sender);

        require(sender.managerType == PledgeManagerType.Giver);

        uint amount = msg.value;

        require(amount > 0);

        vault.transfer(amount); // transfers the baseToken to the Vault
        uint64 idPledge = findPledge(
            idGiver,
            new uint64[](0), //what is new?
            0,
            0,
            0,
            PaymentState.NotPaid);


        Pledge storage nTo = findPledge(idPledge);
        nTo.amount += amount;

        Transfer(0, idPledge, amount);

        transfer(idGiver, idPledge, amount, idReceiver);
    }


    /// @notice Moves value between pledges
    /// @param idSender ID of the giver, delegate or campaign manager that is transferring
    ///  the funds from Pledge to Pledge. This manager must have permissions to move the value
    /// @param idPledge Id of the pledge that's moving the value
    /// @param amount Quantity of value that's being moved
    /// @param idReceiver Destination of the value, can be a giver sending to a giver or
    ///  a delegate, a delegate to another delegate or a campaign to precommit it to that campaign
    function transfer(uint64 idSender, uint64 idPledge, uint amount, uint64 idReceiver) {

        idPledge = normalizePledge(idPledge);

        Pledge storage n = findPledge(idPledge);
        PledgeManager storage receiver = findManager(idReceiver);
        PledgeManager storage sender = findManager(idSender);

        checkManagerOwner(sender);
        require(n.paymentState == PaymentState.NotPaid);

        // If the sender is the owner
        if (n.owner == idSender) {
            if (receiver.managerType == PledgeManagerType.Giver) {
                transferOwnershipToGiver(idPledge, amount, idReceiver);
            } else if (receiver.managerType == PledgeManagerType.Campaign) {
                transferOwnershipToCampaign(idPledge, amount, idReceiver);
            } else if (receiver.managerType == PledgeManagerType.Delegate) {
                appendDelegate(idPledge, amount, idReceiver);
            } else {
                assert(false);
            }
            return;
        }

        // If the sender is a delegate
        uint senderDIdx = getDelegateIdx(n, idSender);
        if (senderDIdx != NOTFOUND) {

            // If the receiver is another giver
            if (receiver.managerType == PledgeManagerType.Giver) {
                // Only accept to change to the original giver to remove all delegates
                assert(n.owner == idReceiver);
                undelegate(idPledge, amount, n.delegationChain.length);
                return;
            }

            // If the receiver is another delegate
            if (receiver.managerType == PledgeManagerType.Delegate) {
                uint receiverDIdx = getDelegateIdx(n, idReceiver);

                // If the receiver is not in the delegate list
                if (receiverDIdx == NOTFOUND) {
                    undelegate(idPledge, amount, n.delegationChain.length - senderDIdx - 1);
                    appendDelegate(idPledge, amount, idReceiver);

                // If the receiver is already part of the delegate chain and is
                // after the sender, then all of the other delegates after the sender are
                // removed and the receiver is appended at the end of the delegation chain
                } else if (receiverDIdx > senderDIdx) {
                    undelegate(idPledge, amount, n.delegationChain.length - senderDIdx - 1);
                    appendDelegate(idPledge, amount, idReceiver);

                // If the receiver is already part of the delegate chain and is
                // before the sender, then the sender and all of the other
                // delegates after the RECEIVER are revomved from the chain,
                // this is interesting because the delegate undelegates from the
                // delegates that delegated to this delegate... game theory issues? should this be allowed
                } else if (receiverDIdx <= senderDIdx) {
                    undelegate(idPledge, amount, n.delegationChain.length - receiverDIdx -1);
                }
                return;
            }

            // If the delegate wants to support a campaign, they undelegate all
            // the delegates after them in the chain and choose a campaign
            if (receiver.managerType == PledgeManagerType.Campaign) {
                undelegate(idPledge, amount, n.delegationChain.length - senderDIdx - 1);
                proposeAssignCampaign(idPledge, amount, idReceiver);
                return;
            }
        }
        assert(false);  // It is not the owner nor any delegate.
    }


    /// @notice This method is used to withdraw value from the system. This can be used
    ///  by the givers to avoid committing the donation or by campaign manager to use
    ///  the Ether.
    /// @param idPledge Id of the pledge that wants to be withdrawn.
    /// @param amount Quantity of Ether that wants to be withdrawn.
    function withdraw(uint64 idPledge, uint amount) {

        idPledge = normalizePledge(idPledge);

        Pledge storage n = findPledge(idPledge);

        require(n.paymentState == PaymentState.NotPaid);

        PledgeManager storage owner = findManager(n.owner);

        checkManagerOwner(owner);

        uint64 idNewPledge = findPledge(
            n.owner,
            n.delegationChain,
            0,
            0,
            n.oldPledge,
            PaymentState.Paying
        );

        doTransfer(idPledge, idNewPledge, amount);

        vault.authorizePayment(bytes32(idNewPledge), owner.addr, amount);
    }

    /// @notice Method called by the vault to confirm a payment.
    /// @param idPledge Id of the pledge that wants to be withdrawn.
    /// @param amount Quantity of Ether that wants to be withdrawn.
    function confirmPayment(uint64 idPledge, uint amount) onlyVault {
        Pledge storage n = findPledge(idPledge);

        require(n.paymentState == PaymentState.Paying);

        // Check the campaign is not canceled in the while.
        require(getOldestPledgeNotCanceled(idPledge) == idPledge);

        uint64 idNewPledge = findPledge(
            n.owner,
            n.delegationChain,
            0,
            0,
            n.oldPledge,
            PaymentState.Paid
        );

        doTransfer(idPledge, idNewPledge, amount);
    }

    /// @notice Method called by the vault to cancel a payment.
    /// @param idPledge Id of the pledge that wants to be canceled for withdraw.
    /// @param amount Quantity of Ether that wants to be rolled back.
    function cancelPayment(uint64 idPledge, uint amount) onlyVault {
        Pledge storage n = findPledge(idPledge);

        require(n.paymentState == PaymentState.Paying); //TODO change to revert

        // When a payment is canceled, never is assigned to a campaign.
        uint64 oldPledge = findPledge(
            n.owner,
            n.delegationChain,
            0,
            0,
            n.oldPledge,
            PaymentState.NotPaid
        );

        oldPledge = normalizePledge(oldPledge);

        doTransfer(idPledge, oldPledge, amount);
    }

    /// @notice Method called to cancel this campaign.
    /// @param idCampaign Id of the projct that wants to be canceled.
    function cancelCampaign(uint64 idCampaign) {
        PledgeManager storage campaign = findManager(idCampaign);
        checkManagerOwner(campaign);
        campaign.canceled = true;

        CancelCampaign(idCampaign);
    }


    function cancelPledge(uint64 idPledge, uint amount) {
        idPledge = normalizePledge(idPledge);

        Pledge storage n = findPledge(idPledge);

        PledgeManager storage m = findManager(n.owner);
        checkManagerOwner(m);

        doTransfer(idPledge, n.oldPledge, amount);
    }


////////
// Multi pledge methods
////////

    // This set of functions makes moving a lot of pledges around much more
    // efficient (saves gas) than calling these functions in series
    uint constant D64 = 0x10000000000000000;
    function mTransfer(uint64 idSender, uint[] pledgesAmounts, uint64 idReceiver) {
        for (uint i = 0; i < pledgesAmounts.length; i++ ) {
            uint64 idPledge = uint64( pledgesAmounts[i] & (D64-1) );
            uint amount = pledgesAmounts[i] / D64;

            transfer(idSender, idPledge, amount, idReceiver);
        }
    }

    function mWithdraw(uint[] pledgesAmounts) {
        for (uint i = 0; i < pledgesAmounts.length; i++ ) {
            uint64 idPledge = uint64( pledgesAmounts[i] & (D64-1) );
            uint amount = pledgesAmounts[i] / D64;

            withdraw(idPledge, amount);
        }
    }

    function mConfirmPayment(uint[] pledgesAmounts) {
        for (uint i = 0; i < pledgesAmounts.length; i++ ) {
            uint64 idPledge = uint64( pledgesAmounts[i] & (D64-1) );
            uint amount = pledgesAmounts[i] / D64;

            confirmPayment(idPledge, amount);
        }
    }

    function mCancelPayment(uint[] pledgesAmounts) {
        for (uint i = 0; i < pledgesAmounts.length; i++ ) {
            uint64 idPledge = uint64( pledgesAmounts[i] & (D64-1) );
            uint amount = pledgesAmounts[i] / D64;

            cancelPayment(idPledge, amount);
        }
    }

    function mNormalizePledge(uint[] pledges) returns(uint64) {
        for (uint i = 0; i < pledges.length; i++ ) {
            uint64 idPledge = uint64( pledges[i] & (D64-1) );

            normalizePledge(idPledge);
        }
    }

////////
// Private methods
///////

    // this function is obvious, but it can also be called to undelegate everyone
    // by setting yourself as the idReceiver
    function transferOwnershipToCampaign(uint64 idPledge, uint amount, uint64 idReceiver) internal  {
        Pledge storage n = findPledge(idPledge);

        require(getPledgeLevel(n) < MAX_INTERCAMPAIGN_LEVEL);
        uint64 oldPledge = findPledge(
            n.owner,
            n.delegationChain,
            0,
            0,
            n.oldPledge,
            PaymentState.NotPaid);
        uint64 toPledge = findPledge(
            idReceiver,
            new uint64[](0),
            0,
            0,
            oldPledge,
            PaymentState.NotPaid);
        doTransfer(idPledge, toPledge, amount);
    }

    function transferOwnershipToGiver(uint64 idPledge, uint amount, uint64 idReceiver) internal  {
        uint64 toPledge = findPledge(
                idReceiver,
                new uint64[](0),
                0,
                0,
                0,
                PaymentState.NotPaid);
        doTransfer(idPledge, toPledge, amount);
    }

    function appendDelegate(uint64 idPledge, uint amount, uint64 idReceiver) internal  {
        Pledge storage n= findPledge(idPledge);

        require(n.delegationChain.length < MAX_DELEGATES); //TODO change to revert and say the error
        uint64[] memory newDelegationChain = new uint64[](n.delegationChain.length + 1);
        for (uint i=0; i<n.delegationChain.length; i++) {
            newDelegationChain[i] = n.delegationChain[i];
        }

        // Make the last item in the array the idReceiver
        newDelegationChain[n.delegationChain.length] = idReceiver;

        uint64 toPledge = findPledge(
                n.owner,
                newDelegationChain,
                0,
                0,
                n.oldPledge,
                PaymentState.NotPaid);
        doTransfer(idPledge, toPledge, amount);
    }

    /// @param q Number of undelegations
    function undelegate(uint64 idPledge, uint amount, uint q) internal {
        Pledge storage n = findPledge(idPledge);
        uint64[] memory newDelegationChain = new uint64[](n.delegationChain.length - q);
        for (uint i=0; i<n.delegationChain.length - q; i++) {
            newDelegationChain[i] = n.delegationChain[i];
        }
        uint64 toPledge = findPledge(
                n.owner,
                newDelegationChain,
                0,
                0,
                n.oldPledge,
                PaymentState.NotPaid);
        doTransfer(idPledge, toPledge, amount);
    }


    function proposeAssignCampaign(uint64 idPledge, uint amount, uint64 idReceiver) internal {// Todo rename
        Pledge storage n = findPledge(idPledge);

        require(getPledgeLevel(n) < MAX_SUBCAMPAIGN_LEVEL);

        uint64 toPledge = findPledge(
                n.owner,
                n.delegationChain,
                idReceiver,
                uint64(getTime() + maxCommitTime(n)),
                n.oldPledge,
                PaymentState.NotPaid);
        doTransfer(idPledge, toPledge, amount);
    }

    function doTransfer(uint64 from, uint64 to, uint _amount) internal {
        uint amount = callPlugins(true, from, to, _amount);
        if (from == to) return;
        if (amount == 0) return;
        Pledge storage nFrom = findPledge(from);
        Pledge storage nTo = findPledge(to);
        require(nFrom.amount >= amount);
        nFrom.amount -= amount;
        nTo.amount += amount;

        Transfer(from, to, amount);
        callPlugins(false, from, to, amount);
    }

    // This function does 2 things, #1: it checks to make sure that the pledges are correct
    // if the a pledged campaign has already been committed then it changes the owner
    // to be the proposed campaign (Pledge that the UI will have to read the commit time and manually
    // do what this function does to the pledge for the end user at the expiration of the commitTime)
    // #2: It checks to make sure that if there has been a cancellation in the chain of campaigns,
    // then it adjusts the pledge's owner appropriately.
    // This call can be called from any body at any time on any pledge. In general it can be called
    // to force the calls of the affected plugins, which also need to be predicted by the UI
    function normalizePledge(uint64 idPledge) returns(uint64) {
        Pledge storage n = findPledge(idPledge);

        // Check to make sure this pledge hasnt already been used or is in the process of being used
        if (n.paymentState != PaymentState.NotPaid) return idPledge;

        // First send to a campaign if it's proposed and commited
        if ((n.proposedCampaign > 0) && ( getTime() > n.commitTime)) {
            uint64 oldPledge = findPledge(
                n.owner,
                n.delegationChain,
                0,
                0,
                n.oldPledge,
                PaymentState.NotPaid);
            uint64 toPledge = findPledge(
                n.proposedCampaign,
                new uint64[](0),
                0,
                0,
                oldPledge,
                PaymentState.NotPaid);
            doTransfer(idPledge, toPledge, n.amount);
            idPledge = toPledge;
            n = findPledge(idPledge);
        }

        toPledge = getOldestPledgeNotCanceled(idPledge);// TODO toPledge is pledge defined
        if (toPledge != idPledge) {
            doTransfer(idPledge, toPledge, n.amount);
        }

        return toPledge;
    }

/////////////
// Plugins
/////////////

    function callPlugin(bool before, uint64 managerId, uint64 fromPledge, uint64 toPledge, uint64 context, uint amount) internal returns (uint allowedAmount) {
        uint newAmount;
        allowedAmount = amount;
        PledgeManager storage manager = findManager(managerId);
        if ((address(manager.plugin) != 0) && (allowedAmount > 0)) {
            if (before) {
                newAmount = manager.plugin.beforeTransfer(managerId, fromPledge, toPledge, context, amount);
                require(newAmount <= allowedAmount);
                allowedAmount = newAmount;
            } else {
                manager.plugin.afterTransfer(managerId, fromPledge, toPledge, context, amount);
            }
        }
    }

    function callPluginsPledge(bool before, uint64 idPledge, uint64 fromPledge, uint64 toPledge, uint amount) internal returns (uint allowedAmount) {
        uint64 offset = idPledge == fromPledge ? 0 : 256;
        allowedAmount = amount;
        Pledge storage n = findPledge(idPledge);

        allowedAmount = callPlugin(before, n.owner, fromPledge, toPledge, offset, allowedAmount);

        for (uint64 i=0; i<n.delegationChain.length; i++) {
            allowedAmount = callPlugin(before, n.delegationChain[i], fromPledge, toPledge, offset + i+1, allowedAmount);
        }

        if (n.proposedCampaign > 0) {
            allowedAmount = callPlugin(before, n.proposedCampaign, fromPledge, toPledge, offset + 255, allowedAmount);
        }
    }

    function callPlugins(bool before, uint64 fromPledge, uint64 toPledge, uint amount) internal returns (uint allowedAmount) {
        allowedAmount = amount;

        allowedAmount = callPluginsPledge(before, fromPledge, fromPledge, toPledge, allowedAmount);
        allowedAmount = callPluginsPledge(before, toPledge, fromPledge, toPledge, allowedAmount);
    }

/////////////
// Test functions
/////////////

    function getTime() internal returns (uint) {
        return now;
    }

    event Transfer(uint64 indexed from, uint64 indexed to, uint amount);
    event CancelCampaign(uint64 indexed idCampaign);

}
