# Banking — Glossary

> Customers hold accounts, accounts move money, and every movement is a transfer that can fail halfway. The domain that has to get it right twice — once in the rules, once in the recovery.

The ubiquitous language: every term Banking declares, alphabetized, in the domain's own words. Generated from `Banking`'s bluebook — a term missing here is a term the bluebook does not yet declare, and a definition missing here is a sentence nobody has written yet.

| Term | Kind | Definition |
|---|---|---|
| **Abandon** *(ScheduledPayment)* | Command | Give up on a payment that could not be collected after every retry |
| **Account** | Aggregate | A balance belonging to one customer, and the ledger that explains how it got there. |
| **Account** | Lifecycle | Starts at `open`. States: `open`, `frozen`, `closed`. |
| **AccountClosed** | Event | Raised by `CloseAccount`. Triggers policy `NotifyOnClosure` → `Notifications.Send` in Notifications. |
| **AccountCredited** | Event | Raised by `Credit`. |
| **AccountDebited** | Event | Raised by `Debit`. |
| **AccountFrozen** | Event | Raised by `FreezeAccount`. Triggers policy `ReviewOnFreeze` → `AccountFreezeReview.Open` in Compliance. |
| **AccountKind** *(Account)* | Value Object | One of `current`, `savings`, `reserve`. |
| **AccountNumber** *(Account)* | Value Object | { value: String } |
| **AccountNumber** *(OnboardingCase)* | Value Object | { value: String } |
| **AccountOpened** | Event | Raised by `Open`. |
| **AccountsByKind** | Read Model | Every account the bank holds, sorted into what kind it is, then by its own number. |
| **AccountUnfrozen** | Event | Raised by `Unfreeze`. |
| **AccrueInterest** *(Account)* | Command | Credit the account with interest earned |
| **Activate** *(ATMCard)* | Command | Start using a card |
| **Active** *(ATMCard)* | Query | Live cards in nickname order, unnamed ones last — real nicknames sort among themselves first. |
| **Amend** *(LedgerEntry)* | Command | Correct a movement posted for the wrong amount |
| **Annotate** *(Visit)* | Command | Note something unusual about a visit after the fact |
| **ApplyFee** *(Account)* | Command | Charge the account a fee |
| **ATMCard** | Aggregate | A card issued against an account, and the cash taken with it. |
| **ATMCard** | Lifecycle | Starts at `issued`. States: `issued`, `active`, `retired`. |
| **ATMCardActivated** | Event | Raised by `Activate`. |
| **ATMCardIssued** | Event | Raised by `Issue`. |
| **ATMCardRenamed** | Event | Raised by `Rename`. |
| **ATMCardRetired** | Event | Raised by `Retire`. |
| **AtMost** *(Account)* | Query | Accounts holding no more than a cap the caller supplies — the small-balance closure candidates. |
| **AuthorisationCode** *(CardPayment)* | Value Object | { value: String } |
| **Authorize** *(CardPayment)* | Command | Put a hold on funds for a purchase |
| **Back office** | Role | Issues `CorrectFee`, `CorrectInterest`, `Amend`, `Reverse`, `Retire`, `Abandon`. |
| **Banking** | Domain | Customers hold accounts, accounts move money, and every movement is a transfer that can fail halfway. The domain that has to get it right twice — once in the rules, once in the recovery. |
| **BeneficiaryName** *(ExternalTransfer)* | Value Object | { value: String } |
| **BoxNumber** *(SafeDepositBox)* | Value Object | { value: Integer } |
| **BoxOpened** | Event | Raised by `LogVisit`. |
| **BoxRented** | Event | Raised by `Rent`. |
| **BoxSurrendered** | Event | Raised by `Surrender`. Triggers policy `ReviewOnBoxSurrender` → `BoxSurrenderReview.Open` in Compliance. |
| **Branch clerk** | Role | Issues `Register`, `Close`, `Open`, `CloseAccount`, `Issue`, `Rent`. |
| **BranchCode** *(SafeDepositBox)* | Value Object | { value: String } |
| **ByFee** *(ATMCard)* | Query | Live cards by what they cost to hold, cheapest first — a fee is a Float, so the order is numeric and not alphabetical. |
| **Cancel** *(ScheduledPayment)* | Command | Call off a payment before its due date |
| **Capture** *(CardPayment)* | Command | Turn an authorization into an actual charge |
| **CardAuthorized** | Event | Raised by `Authorize`. |
| **CardCaptured** | Event | Raised by `Capture`. |
| **CardChargedBack** | Event | Raised by `Chargeback`. |
| **CardDisputed** | Event | Raised by `Dispute`. |
| **CardDisputeRejected** | Event | Raised by `RejectDispute`. |
| **CardNickname** *(ATMCard)* | Value Object | { value: String } |
| **CardPayment** | Aggregate | A card authorisation that either settles, is voided before settlement, or becomes a post-settlement dispute. |
| **CardPayment** | Lifecycle | Starts at `authorized`. States: `authorized`, `captured`, `voided`, `refunded`, `reversed`, `disputed`, `charged_back`. |
| **CardRefunded** | Event | Raised by `Refund`. |
| **CardReversed** | Event | Raised by `Reverse`. |
| **CardSerial** *(ATMCard)* | Value Object | { value: String } |
| **CardVoided** | Event | Raised by `Void`. |
| **CashWithdrawn** | Event | Raised by `Withdraw`. |
| **Chargeback** *(CardPayment)* | Command | Uphold a customer's dispute and claw the charge back |
| **Clear** *(OnboardingCase)* | Command | Pass a customer's identity and screening checks |
| **Close** *(Customer)* | Command | End the relationship |
| **CloseAccount** *(Account)* | Command | Close an account that has been emptied |
| **Compliance officer** | Role | Issues `Suspend`, `Reinstate`, `FreezeAccount`, `Unfreeze`, `Clear`, `Decline`, `Chargeback`, `RejectDispute`. |
| **ComplianceDashboard** | Read Model | One account, its own status, and any card charges disputed against it — the working set for a compliance review. |
| **CorrectFee** *(Account)* | Command | Reverse a fee that was applied in error |
| **CorrectInterest** *(Account)* | Command | Reverse interest that was accrued in error |
| **Credit** *(Account)* | Command | Put money in |
| **Credited** *(Transfer)* | Command | Record that the destination credit committed |
| **Customer** | Aggregate | A person the bank holds a relationship with. Suspended rather than deleted — a bank forgets nothing. |
| **Customer** | Lifecycle | Starts at `active`. States: `active`, `suspended`, `closed`. |
| **Customer** | Role | Issues `Rename`, `Withdraw`, `Activate`, `Dispute`, `Surrender`, `Request`, `Recall`, `Schedule`, `Cancel`. |
| **CustomerClosed** | Event | Raised by `Close`. |
| **CustomerNumber** *(Customer)* | Value Object | { value: String } |
| **CustomerPortfolio** | Read Model | A customer's cross-account position, rebuilt from aggregate heads. |
| **CustomerRegistered** | Event | Raised by `Register`. |
| **CustomerReinstated** | Event | Raised by `Reinstate`. |
| **CustomerStanding** *(Customer)* | Value Object | { value: String } |
| **CustomerSuspended** | Event | Raised by `Suspend`. Triggers policy `FreezeAccountsOnSuspension` → `Account.FreezeAccount`. |
| **DailyFee** *(ATMCard)* | Value Object | { amount: Float } |
| **DailyLimit** *(Account)* | Value Object | { cents: Integer } |
| **Debit** *(Account)* | Command | Take money out, if it is there to take |
| **Debited** *(Transfer)* | Command | Record that the source account has given up the money |
| **Decline** *(OnboardingCase)* | Command | Refuse a customer who does not clear screening — no account was ever opened, so nothing is undone |
| **Dispute** *(CardPayment)* | Command | Challenge a payment that already settled |
| **Dispute** *(Withdrawal)* | Command | Challenge a withdrawal that was not mine |
| **Disputed** *(CardPayment)* | Query | Charges currently under a customer's dispute, awaiting a compliance decision. |
| **DisputedPaymentCount** | Read Model | How many of an account's own card charges are under dispute — a single number, not the rows themselves. |
| **DisputedPaymentMedian** | Read Model | The median amount of an account's own disputed card charges. |
| **Due** *(ScheduledPayment)* | Query | Payments still scheduled, ordered by when they're due. |
| **EmailAddress** *(Customer)* | Value Object | { address: String } |
| **EndToEndReference** *(ExternalTransfer)* | Value Object | { value: String } |
| **Execute** *(ScheduledPayment)* | Command | Collect a payment on its due date |
| **ExternalAmount** *(ExternalTransfer)* | Value Object | { cents: Integer } |
| **ExternalSettlement** | Saga | Starts on `ExternalTransferRequested`, ends on `ExternalTransferSent`. States: `requested` → `returned`. |
| **ExternalTransfer** | Aggregate | A transfer sent beyond the bank, where a recall is an instruction and a return is the external network's outcome. |
| **ExternalTransfer** | Lifecycle | Starts at `requested`. States: `requested`, `sent`, `recalled`, `returned`. |
| **ExternalTransferRecalled** | Event | Raised by `Recall`. |
| **ExternalTransferRequested** | Event | Raised by `Request`. |
| **ExternalTransferReturned** | Event | Raised by `Return`. |
| **ExternalTransferSent** | Event | Raised by `SendTransfer`. |
| **Fail** *(ScheduledPayment)* | Command | Record that today's presentment could not be collected |
| **FeeApplied** | Event | Raised by `ApplyFee`. |
| **FeeCorrected** | Event | Raised by `CorrectFee`. |
| **Flagged** *(CardPayment)* | Query | Charges carrying a risk tag, for the fraud queue. |
| **FlagKeyReturn** | Policy | On `KeyReturnDue`, dispatches `Notifications.Send` in Notifications. |
| **FreezeAccount** *(Account)* | Command | Stop an account moving while something is investigated |
| **FreezeAccountsOnSuspension** | Policy | On `CustomerSuspended`, dispatches `Account.FreezeAccount`, once per `Account.OpenForCustomer` row. |
| **Generate** *(Statement)* | Command | Close out one period's activity into a permanent record |
| **HighBalance** *(Account)* | Query | Accounts holding at least a floor the caller supplies — the private-banking referral list. |
| **InFlight** *(Transfer)* | Query | Transfers that have left one account and not arrived at the other. The list that must always empty. |
| **InGoodStanding** *(Customer)* | Query | The everyday customer roll — active, and nothing outstanding against them. |
| **InstructionReference** *(ScheduledPayment)* | Value Object | { value: String } |
| **InterestAccrued** | Event | Raised by `AccrueInterest`. |
| **InterestCorrected** | Event | Raised by `CorrectInterest`. |
| **Issue** *(ATMCard)* | Command | Put a card in a customer's hand |
| **IssueKey** *(SafeDepositBox)* | Command | Cut a key for the box |
| **KeyIssuance** *(SafeDepositBox)* | Entity | One key cut for the box, held by whoever last signed for it. |
| **KeyIssuance** | Lifecycle | Starts at `issued`. States: `issued`, `returned`. |
| **KeyIssued** | Event | Raised by `IssueKey`. |
| **KeyReturnDue** | Event | Raised by `Surrender`. Triggers policy `FlagKeyReturn` → `Notifications.Send` in Notifications. |
| **KeyReturned** | Event | Raised by `Return`. |
| **KeySerial** *(SafeDepositBox)* | Value Object | { value: String } |
| **LedgerDirection** *(Account)* | Value Object | One of `credit`, `debit`. |
| **LedgerEntry** *(Account)* | Entity | One movement across the account, in the order it was posted. |
| **LedgerEntry** | Lifecycle | Starts at `posted`. States: `posted`, `reversed`. |
| **LedgerEntryAmended** | Event | Raised by `Amend`. |
| **LedgerEntryReversed** | Event | Raised by `Reverse`. |
| **LedgerSequence** *(Account)* | Value Object | { value: Integer } |
| **LogVisit** *(SafeDepositBox)* | Command | Record that the box was opened |
| **MerchantName** *(CardPayment)* | Value Object | { value: String } |
| **Money** *(Account)* | Value Object | { cents: Integer, currency: String } |
| **MovementDirection** *(ExternalTransfer)* | Value Object | { value: String } |
| **Narrative** *(Account)* | Value Object | { text: String } |
| **Narrative** *(ATMCard)* | Value Object | { text: String } |
| **Narrative** *(Transfer)* | Value Object | { text: String } |
| **NotGoodStanding** *(Customer)* | Query | Everyone who is not in the everyday roll — suspended, under review, or anything else that is not simply "good". |
| **NotifyOnClosure** | Policy | On `AccountClosed`, dispatches `Notifications.Send` in Notifications. |
| **Onboarding** | Saga | Starts on `OnboardingOpened`, ends on `AccountOpened`. States: `screening` → `cleared` → `declined`. |
| **OnboardingCase** | Aggregate | The KYC check a newly registered customer clears before an account exists for them — screened once, and if it does not clear there is nothing to undo, because nothing was ever opened. |
| **OnboardingCase** | Lifecycle | Starts at `screening`. States: `screening`, `cleared`, `declined`. |
| **OnboardingCleared** | Event | Raised by `Clear`. |
| **OnboardingDeclined** | Event | Raised by `Decline`. |
| **OnboardingOpened** | Event | Raised by `Open`. |
| **OnboardingReference** *(OnboardingCase)* | Value Object | { value: String } |
| **Open** *(Account)* | Command | Give a customer somewhere to keep money |
| **Open** *(OnboardingCase)* | Command | Open a KYC case for a newly registered customer, naming the account it will become |
| **Open** *(Account)* | Query | Accounts that can transact today. |
| **OpenForCustomer** *(Account)* | Query | One customer's own open accounts — the for_each target that freezes every one of them on suspension, not just whichever the event payload happened to carry. |
| **OpenForSuspendedCustomers** *(Account)* | Query | Open accounts whose customer has since been suspended — live money movement nobody should be approving right now. |
| **Overdrawn** *(Account)* | Query | Accounts below a floor the caller supplies — the morning risk report. |
| **PaymentAmount** *(CardPayment)* | Value Object | { cents: Integer } |
| **PaymentDueDate** *(ScheduledPayment)* | Value Object | { value: String } |
| **PaymentRecipient** *(ScheduledPayment)* | Value Object | { value: String } |
| **PaymentScheduled** | Event | Raised by `Schedule`. |
| **Pending** *(CardPayment)* | Query | Authorized charges not yet captured, voided, or otherwise resolved. |
| **PersonName** *(Customer)* | Value Object | { given: String, family: String } |
| **PositiveMoney** *(Account)* | Value Object | { cents: Integer, currency: String } |
| **Reachable** *(Account)* | Query | Accounts that still exist as far as a caller is concerned — anything short of closed. |
| **Recall** *(ExternalTransfer)* | Command | Ask the external network to stop a transfer already sent |
| **Recent** *(Withdrawal)* | Query | The first two withdrawals still standing, whatever else was taken. |
| **Recent** *(Visit)* | Query | The last few visits, whatever the box has seen. |
| **Refund** *(CardPayment)* | Command | Give the money back after a charge settled |
| **Register** *(Customer)* | Command | Take on a new customer |
| **Reinstate** *(Customer)* | Command | Let a cleared customer transact again |
| **Reject** *(Transfer)* | Command | Refuse a transfer before any money moved |
| **RejectDispute** *(CardPayment)* | Command | Uphold the charge and close a customer's dispute |
| **Rename** *(ATMCard)* | Command | Name a card so it is recognisable |
| **Rent** *(SafeDepositBox)* | Command | Assign the box to a customer |
| **Rented** *(SafeDepositBox)* | Query | Boxes currently assigned to a customer, for the annual access audit. |
| **Request** *(Transfer)* | Command | Send money to another account |
| **Request** *(ExternalTransfer)* | Command | Send money to an account outside the bank |
| **Retire** *(ATMCard)* | Command | Take a card out of service |
| **Retry** *(ScheduledPayment)* | Command | Re-present a failed payment, up to the limit the schedule names |
| **RetryCount** *(ScheduledPayment)* | Value Object | { value: Integer } |
| **RetryLimit** *(ScheduledPayment)* | Value Object | { value: Integer } |
| **RetryOnPaymentFailure** | Policy | On `ScheduledPaymentFailed`, dispatches `ScheduledPayment.Retry`. |
| **Return** *(ExternalTransfer)* | Command | Record that the external network sent the money back |
| **Return** *(KeyIssuance)* | Command | Take a key back when a holder is done with it |
| **Reverse** *(CardPayment)* | Command | Undo a captured charge with no customer dispute involved |
| **Reverse** *(Transfer)* | Command | Put the money back when the credit could not be made |
| **Reverse** *(LedgerEntry)* | Command | Undo a movement that should not have been posted |
| **Reversed** *(LedgerEntry)* | Query | Entries that were undone — the audit trail nobody wants to need. |
| **ReviewOnBoxSurrender** | Policy | On `BoxSurrendered`, dispatches `BoxSurrenderReview.Open` in Compliance. |
| **ReviewOnFreeze** | Policy | On `AccountFrozen`, dispatches `AccountFreezeReview.Open` in Compliance. |
| **SafeDepositBox** | Aggregate | A steel box in the vault, held under one customer's name and opened only against the branch and number stamped on its face. |
| **SafeDepositBox** | Lifecycle | Starts at `vacant`. States: `vacant`, `rented`. |
| **Schedule** *(ScheduledPayment)* | Command | Set up a payment to collect on a future date |
| **ScheduledAmount** *(ScheduledPayment)* | Value Object | { cents: Integer } |
| **ScheduledPayment** | Aggregate | An instruction held for a future date, which may execute once or be cancelled before it does. |
| **ScheduledPayment** | Lifecycle | Starts at `scheduled`. States: `scheduled`, `executed`, `cancelled`, `failed`, `abandoned`. |
| **ScheduledPaymentAbandoned** | Event | Raised by `Abandon`. |
| **ScheduledPaymentCancelled** | Event | Raised by `Cancel`. |
| **ScheduledPaymentExecuted** | Event | Raised by `Execute`. |
| **ScheduledPaymentFailed** | Event | Raised by `Fail`, `Retry`. Triggers policy `RetryOnPaymentFailure` → `ScheduledPayment.Retry`. |
| **Screening** *(OnboardingCase)* | Query | Cases still waiting on a compliance decision. |
| **SendTransfer** *(ExternalTransfer)* | Command | Release the transfer to the external network |
| **Sent** *(ExternalTransfer)* | Query | Transfers already released to the external network, awaiting its outcome. |
| **Settle** *(Transfer)* | Command | Record that the destination has received it |
| **Settlement** | Saga | Starts on `TransferRequested`, ends on `TransferSettled`. States: `requested` → `awaiting_credit` → `settled` → `reversed`. |
| **Size** *(SafeDepositBox)* | Value Object | One of `small`, `medium`, `large`. |
| **Statement** | Aggregate | A snapshot of one account's activity over one period, generated once and never revised. |
| **StatementAmount** *(Statement)* | Value Object | { cents: Integer } |
| **StatementDate** *(Statement)* | Value Object | { value: String } |
| **StatementFrequency** *(Statement)* | Value Object | One of: { cadence: "monthly", retention_months: 84, paper_fee_cents: 0 }; { cadence: "quarterly", retention_months: 120, paper_fee_cents: 0 }; { cadence: "annual", retention_months: 240, paper_fee_cents: 500 }. |
| **StatementGenerated** | Event | Raised by `Generate`. |
| **StatementPeriod** *(Statement)* | Value Object | { value: String } |
| **StrictlyAbove** *(Account)* | Query | Accounts holding MORE than a floor the caller supplies — the referral list without the accounts sitting exactly on the line. |
| **Surrender** *(SafeDepositBox)* | Command | Give the box back and take the keys off the account |
| **Suspend** *(Customer)* | Command | Stop a customer transacting while something is investigated |
| **Suspended** *(Customer)* | Query | The compliance queue, newest concern first. |
| **System** | Role | Issues `ApplyFee`, `AccrueInterest`, `Capture`, `Void`, `Refund`, `Reverse`, `Generate`, `Debited`, `Settle`, `Credited`, `Reject`, `SendTransfer`, `Return`, `Execute`, `Fail`, `Retry`. |
| **Tag** *(CardPayment)* | Value Object | { value: String } |
| **Teller** | Role | Issues `Credit`, `Debit`. |
| **Transfer** | Aggregate | Money leaving one account for another. Two movements that must both happen, or neither. |
| **Transfer** | Lifecycle | Starts at `requested`. States: `requested`, `debited`, `credited`, `settled`, `reversed`, `rejected`. |
| **TransferCredited** | Event | Raised by `Credited`. |
| **TransferDebited** | Event | Raised by `Debited`. |
| **TransferMoney** *(Transfer)* | Value Object | { cents: Integer } |
| **TransferReference** *(Transfer)* | Value Object | { value: String } |
| **TransferRejected** | Event | Raised by `Reject`. |
| **TransferRequested** | Event | Raised by `Request`. |
| **TransferReversed** | Event | Raised by `Reverse`. |
| **TransferSettled** | Event | Raised by `Settle`. |
| **Unfreeze** *(Account)* | Command | Release a cleared account |
| **Vault officer** | Role | Issues `LogVisit`, `IssueKey`, `Annotate`, `Return`. |
| **Visit** *(SafeDepositBox)* | Entity | One opening of the box, in the order it happened that day. |
| **Visit** | Lifecycle | Starts at `logged`. States: `logged`. |
| **VisitAnnotated** | Event | Raised by `Annotate`. |
| **VisitDate** *(SafeDepositBox)* | Value Object | { value: String } |
| **VisitNote** *(SafeDepositBox)* | Value Object | { text: String } |
| **VisitSequence** *(SafeDepositBox)* | Value Object | { value: Integer } |
| **Void** *(CardPayment)* | Command | Cancel an authorization before it settles |
| **Withdraw** *(ATMCard)* | Command | Take cash out at a machine |
| **Withdrawal** *(ATMCard)* | Entity | One handful of cash, in the order it was taken. |
| **Withdrawal** | Lifecycle | Starts at `taken`. States: `taken`, `disputed`. |
| **WithdrawalAmount** *(ATMCard)* | Value Object | { cents: Integer } |
| **WithdrawalDisputed** | Event | Raised by `Dispute`. |
| **WithdrawalSequence** *(ATMCard)* | Value Object | { value: Integer } |
