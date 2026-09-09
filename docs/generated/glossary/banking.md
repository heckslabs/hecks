# Banking — Glossary

> Customers hold accounts, accounts move money, and every movement is a transfer that can fail halfway. The domain that has to get it right twice — once in the rules, once in the recovery.

The ubiquitous language: every term Banking declares, grouped under the aggregate it belongs to, in the domain's own words. Generated from `Banking`'s bluebook — a term missing here is a term the bluebook does not yet declare, and a definition missing here is a sentence nobody has written yet.

## ATMCard

| Term | Kind | Definition |
|---|---|---|
| **ATMCard** | Aggregate | A card issued against an account, and the cash taken with it. |
| **ATMCard** | Lifecycle | Starts at `issued`. States: `issued`, `active`, `retired`. |
| **Withdrawal** | Lifecycle | Starts at `taken`. States: `taken`, `disputed`. |
| **Withdrawal** *(ATMCard)* | Entity | One handful of cash, in the order it was taken. |
| **CardNickname** *(ATMCard)* | Value Object | { value: String } |
| **CardSerial** *(ATMCard)* | Value Object | { value: String } Must satisfy: a card serial is present. |
| **DailyFee** *(ATMCard)* | Value Object | { amount: Float } Must satisfy: a daily fee is non-negative. |
| **Narrative** *(ATMCard)* | Value Object | { text: String } Must satisfy: a withdrawal explains itself. |
| **WithdrawalAmount** *(ATMCard)* | Value Object | { cents: Integer } Must satisfy: a withdrawal amount is positive. |
| **WithdrawalSequence** *(ATMCard)* | Value Object | { value: Integer } Must satisfy: a withdrawal sequence is positive. |
| **Activate** *(ATMCard)* | Command | Start using a card |
| **Dispute** *(Withdrawal)* | Command | Challenge a withdrawal that was not mine |
| **Issue** *(ATMCard)* | Command | Put a card in a customer's hand |
| **Rename** *(ATMCard)* | Command | Name a card so it is recognisable |
| **Retire** *(ATMCard)* | Command | Take a card out of service |
| **Withdraw** *(ATMCard)* | Command | Take cash out at a machine |
| **Active** *(ATMCard)* | Query | Live cards in nickname order, unnamed ones last — real nicknames sort among themselves first. |
| **ByFee** *(ATMCard)* | Query | Live cards by what they cost to hold, cheapest first — a fee is a Float, so the order is numeric and not alphabetical. |
| **Recent** *(Withdrawal)* | Query | The first two withdrawals still standing, whatever else was taken. |
| **ATMCardActivated** | Event | Raised by `Activate`. |
| **ATMCardIssued** | Event | Raised by `Issue`. |
| **ATMCardRenamed** | Event | Raised by `Rename`. |
| **ATMCardRetired** | Event | Raised by `Retire`. |
| **CashWithdrawn** | Event | Raised by `Withdraw`. |
| **WithdrawalDisputed** | Event | Raised by `Dispute`. |

## Account

| Term | Kind | Definition |
|---|---|---|
| **Account** | Aggregate | A balance belonging to one customer, and the ledger that explains how it got there. |
| **Account** | Lifecycle | Starts at `open`. States: `open`, `frozen`, `closed`. |
| **LedgerEntry** | Lifecycle | Starts at `posted`. States: `posted`, `reversed`. |
| **LedgerEntry** *(Account)* | Entity | One movement across the account, in the order it was posted. |
| **AccountKind** *(Account)* | Value Object | One of `current`, `savings`, `reserve`. |
| **AccountNumber** *(Account)* | Value Object | { value: String } Must satisfy: an account number is present. |
| **DailyLimit** *(Account)* | Value Object | { cents: Integer } Must satisfy: a daily limit is non-negative. |
| **LedgerDirection** *(Account)* | Value Object | One of `credit`, `debit`. |
| **LedgerSequence** *(Account)* | Value Object | { value: Integer } Must satisfy: a ledger sequence is positive. |
| **Money** *(Account)* | Value Object | { cents: Integer, currency: String } Must satisfy: a currency is a three-letter code. |
| **Narrative** *(Account)* | Value Object | { text: String } Must satisfy: a movement explains itself. |
| **PositiveMoney** *(Account)* | Value Object | { cents: Integer, currency: String } Must satisfy: an amount is positive; a currency is a three-letter code. |
| **AccrueInterest** *(Account)* | Command | Credit the account with interest earned |
| **Amend** *(LedgerEntry)* | Command | Correct a movement posted for the wrong amount |
| **ApplyFee** *(Account)* | Command | Charge the account a fee |
| **CloseAccount** *(Account)* | Command | Close an account that has been emptied |
| **CorrectFee** *(Account)* | Command | Reverse a fee that was applied in error |
| **CorrectInterest** *(Account)* | Command | Reverse interest that was accrued in error |
| **Credit** *(Account)* | Command | Put money in |
| **Debit** *(Account)* | Command | Take money out, if it is there to take |
| **FreezeAccount** *(Account)* | Command | Stop an account moving while something is investigated |
| **Open** *(Account)* | Command | Give a customer somewhere to keep money |
| **Reverse** *(LedgerEntry)* | Command | Undo a movement that should not have been posted |
| **Unfreeze** *(Account)* | Command | Release a cleared account |
| **AtMost** *(Account)* | Query | Accounts holding no more than a cap the caller supplies — the small-balance closure candidates. |
| **HighBalance** *(Account)* | Query | Accounts holding at least a floor the caller supplies — the private-banking referral list. |
| **Open** *(Account)* | Query | Accounts that can transact today. |
| **OpenForCustomer** *(Account)* | Query | One customer's own open accounts — the for_each target that freezes every one of them on suspension, not just whichever the event payload happened to carry. |
| **OpenForSuspendedCustomers** *(Account)* | Query | Open accounts whose customer has since been suspended — live money movement nobody should be approving right now. |
| **Overdrawn** *(Account)* | Query | Accounts below a floor the caller supplies — the morning risk report. |
| **Reachable** *(Account)* | Query | Accounts that still exist as far as a caller is concerned — anything short of closed. |
| **Reversed** *(LedgerEntry)* | Query | Entries that were undone — the audit trail nobody wants to need. |
| **StrictlyAbove** *(Account)* | Query | Accounts holding MORE than a floor the caller supplies — the referral list without the accounts sitting exactly on the line. |
| **AccountClosed** | Event | Raised by `CloseAccount`. Triggers policy `NotifyOnClosure` → `Notifications.Send` in Notifications. |
| **AccountCredited** | Event | Raised by `Credit`. |
| **AccountDebited** | Event | Raised by `Debit`. |
| **AccountFrozen** | Event | Raised by `FreezeAccount`. Triggers policy `ReviewOnFreeze` → `AccountFreezeReview.Open` in Compliance. |
| **AccountOpened** | Event | Raised by `Open`. |
| **AccountUnfrozen** | Event | Raised by `Unfreeze`. |
| **FeeApplied** | Event | Raised by `ApplyFee`. |
| **FeeCorrected** | Event | Raised by `CorrectFee`. |
| **InterestAccrued** | Event | Raised by `AccrueInterest`. |
| **InterestCorrected** | Event | Raised by `CorrectInterest`. |
| **LedgerEntryAmended** | Event | Raised by `Amend`. |
| **LedgerEntryReversed** | Event | Raised by `Reverse`. |
| **NotifyOnClosure** | Policy | On `AccountClosed`, dispatches `Notifications.Send` in Notifications. |
| **ReviewOnFreeze** | Policy | On `AccountFrozen`, dispatches `AccountFreezeReview.Open` in Compliance. |

## CardPayment

| Term | Kind | Definition |
|---|---|---|
| **CardPayment** | Aggregate | A card authorisation that either settles, is voided before settlement, or becomes a post-settlement dispute. |
| **CardPayment** | Lifecycle | Starts at `authorized`. States: `authorized`, `captured`, `voided`, `refunded`, `reversed`, `disputed`, `charged_back`. |
| **AuthorisationCode** *(CardPayment)* | Value Object | { value: String } |
| **MerchantName** *(CardPayment)* | Value Object | { value: String } Must satisfy: a merchant name is present. |
| **PaymentAmount** *(CardPayment)* | Value Object | { cents: Integer } Must satisfy: a payment amount is positive. |
| **Tag** *(CardPayment)* | Value Object | { value: String } Must satisfy: a tag is not the empty string. |
| **Authorize** *(CardPayment)* | Command | Put a hold on funds for a purchase |
| **Capture** *(CardPayment)* | Command | Turn an authorization into an actual charge |
| **Chargeback** *(CardPayment)* | Command | Uphold a customer's dispute and claw the charge back |
| **Dispute** *(CardPayment)* | Command | Challenge a payment that already settled |
| **Refund** *(CardPayment)* | Command | Give the money back after a charge settled |
| **RejectDispute** *(CardPayment)* | Command | Uphold the charge and close a customer's dispute |
| **Reverse** *(CardPayment)* | Command | Undo a captured charge with no customer dispute involved |
| **Void** *(CardPayment)* | Command | Cancel an authorization before it settles |
| **Disputed** *(CardPayment)* | Query | Charges currently under a customer's dispute, awaiting a compliance decision. |
| **Flagged** *(CardPayment)* | Query | Charges carrying a risk tag, for the fraud queue. |
| **Pending** *(CardPayment)* | Query | Authorized charges not yet captured, voided, or otherwise resolved. |
| **CardAuthorized** | Event | Raised by `Authorize`. |
| **CardCaptured** | Event | Raised by `Capture`. |
| **CardChargedBack** | Event | Raised by `Chargeback`. |
| **CardDisputed** | Event | Raised by `Dispute`. |
| **CardDisputeRejected** | Event | Raised by `RejectDispute`. |
| **CardRefunded** | Event | Raised by `Refund`. |
| **CardReversed** | Event | Raised by `Reverse`. |
| **CardVoided** | Event | Raised by `Void`. |

## Customer

| Term | Kind | Definition |
|---|---|---|
| **Customer** | Aggregate | A person the bank holds a relationship with. Suspended rather than deleted — a bank forgets nothing. |
| **Customer** | Lifecycle | Starts at `active`. States: `active`, `suspended`, `closed`. |
| **CustomerNumber** *(Customer)* | Value Object | { value: String } Must satisfy: a customer reference is present. |
| **CustomerStanding** *(Customer)* | Value Object | { value: String } Must satisfy: a standing is named. |
| **EmailAddress** *(Customer)* | Value Object | { address: String } |
| **PersonName** *(Customer)* | Value Object | { given: String, family: String } Must satisfy: a given name is present; a family name is present. |
| **Close** *(Customer)* | Command | End the relationship |
| **Register** *(Customer)* | Command | Take on a new customer |
| **Reinstate** *(Customer)* | Command | Let a cleared customer transact again |
| **Suspend** *(Customer)* | Command | Stop a customer transacting while something is investigated |
| **InGoodStanding** *(Customer)* | Query | The everyday customer roll — active, and nothing outstanding against them. |
| **NotGoodStanding** *(Customer)* | Query | Everyone who is not in the everyday roll — suspended, under review, or anything else that is not simply "good". |
| **Suspended** *(Customer)* | Query | The compliance queue, newest concern first. |
| **CustomerClosed** | Event | Raised by `Close`. |
| **CustomerRegistered** | Event | Raised by `Register`. |
| **CustomerReinstated** | Event | Raised by `Reinstate`. |
| **CustomerSuspended** | Event | Raised by `Suspend`. Triggers policy `FreezeAccountsOnSuspension` → `Account.FreezeAccount`. |
| **FreezeAccountsOnSuspension** | Policy | On `CustomerSuspended`, dispatches `Account.FreezeAccount`, once per `Account.OpenForCustomer` row. |

## ExternalTransfer

| Term | Kind | Definition |
|---|---|---|
| **ExternalTransfer** | Aggregate | A transfer sent beyond the bank, where a recall is an instruction and a return is the external network's outcome. |
| **ExternalTransfer** | Lifecycle | Starts at `requested`. States: `requested`, `sent`, `recalled`, `returned`. |
| **BeneficiaryName** *(ExternalTransfer)* | Value Object | { value: String } Must satisfy: a beneficiary name is present. |
| **EndToEndReference** *(ExternalTransfer)* | Value Object | { value: String } |
| **ExternalAmount** *(ExternalTransfer)* | Value Object | { cents: Integer } Must satisfy: an external transfer amount is positive. |
| **MovementDirection** *(ExternalTransfer)* | Value Object | { value: String } |
| **Recall** *(ExternalTransfer)* | Command | Ask the external network to stop a transfer already sent |
| **Request** *(ExternalTransfer)* | Command | Send money to an account outside the bank |
| **Return** *(ExternalTransfer)* | Command | Record that the external network sent the money back |
| **SendTransfer** *(ExternalTransfer)* | Command | Release the transfer to the external network |
| **Sent** *(ExternalTransfer)* | Query | Transfers already released to the external network, awaiting its outcome. |
| **ExternalTransferRecalled** | Event | Raised by `Recall`. |
| **ExternalTransferRequested** | Event | Raised by `Request`. |
| **ExternalTransferReturned** | Event | Raised by `Return`. |
| **ExternalTransferSent** | Event | Raised by `SendTransfer`. |
| **ExternalSettlement** | Saga | Starts on `ExternalTransferRequested`, ends on `ExternalTransferSent`. States: `requested` → `returned`. |

## OnboardingCase

| Term | Kind | Definition |
|---|---|---|
| **OnboardingCase** | Aggregate | The KYC check a newly registered customer clears before an account exists for them — screened once, and if it does not clear there is nothing to undo, because nothing was ever opened. |
| **OnboardingCase** | Lifecycle | Starts at `screening`. States: `screening`, `cleared`, `declined`. |
| **AccountNumber** *(OnboardingCase)* | Value Object | { value: String } Must satisfy: an account number is present. |
| **OnboardingReference** *(OnboardingCase)* | Value Object | { value: String } Must satisfy: an onboarding case is referenced. |
| **Clear** *(OnboardingCase)* | Command | Pass a customer's identity and screening checks |
| **Decline** *(OnboardingCase)* | Command | Refuse a customer who does not clear screening — no account was ever opened, so nothing is undone |
| **Open** *(OnboardingCase)* | Command | Open a KYC case for a newly registered customer, naming the account it will become |
| **Screening** *(OnboardingCase)* | Query | Cases still waiting on a compliance decision. |
| **OnboardingCleared** | Event | Raised by `Clear`. |
| **OnboardingDeclined** | Event | Raised by `Decline`. |
| **OnboardingOpened** | Event | Raised by `Open`. |
| **Onboarding** | Saga | Starts on `OnboardingOpened`, ends on `AccountOpened`. States: `screening` → `cleared` → `declined`. |

## SafeDepositBox

| Term | Kind | Definition |
|---|---|---|
| **SafeDepositBox** | Aggregate | A steel box in the vault, held under one customer's name and opened only against the branch and number stamped on its face. |
| **KeyIssuance** | Lifecycle | Starts at `issued`. States: `issued`, `returned`. |
| **SafeDepositBox** | Lifecycle | Starts at `vacant`. States: `vacant`, `rented`. |
| **Visit** | Lifecycle | Starts at `logged`. States: `logged`. |
| **KeyIssuance** *(SafeDepositBox)* | Entity | One key cut for the box, held by whoever last signed for it. |
| **Visit** *(SafeDepositBox)* | Entity | One opening of the box, in the order it happened that day. |
| **BoxNumber** *(SafeDepositBox)* | Value Object | { value: Integer } Must satisfy: a box is numbered from one. |
| **BranchCode** *(SafeDepositBox)* | Value Object | { value: String } Must satisfy: a branch is coded. |
| **KeySerial** *(SafeDepositBox)* | Value Object | { value: String } Must satisfy: a key is serialed. |
| **Size** *(SafeDepositBox)* | Value Object | One of `small`, `medium`, `large`. |
| **VisitDate** *(SafeDepositBox)* | Value Object | { value: String } Must satisfy: a visit names its date. |
| **VisitNote** *(SafeDepositBox)* | Value Object | { text: String } |
| **VisitSequence** *(SafeDepositBox)* | Value Object | { value: Integer } Must satisfy: a visit sequence is positive. |
| **Annotate** *(Visit)* | Command | Note something unusual about a visit after the fact |
| **IssueKey** *(SafeDepositBox)* | Command | Cut a key for the box |
| **LogVisit** *(SafeDepositBox)* | Command | Record that the box was opened |
| **Rent** *(SafeDepositBox)* | Command | Assign the box to a customer |
| **Return** *(KeyIssuance)* | Command | Take a key back when a holder is done with it |
| **Surrender** *(SafeDepositBox)* | Command | Give the box back and take the keys off the account |
| **Recent** *(Visit)* | Query | The last few visits, whatever the box has seen. |
| **Rented** *(SafeDepositBox)* | Query | Boxes currently assigned to a customer, for the annual access audit. |
| **BoxOpened** | Event | Raised by `LogVisit`. |
| **BoxRented** | Event | Raised by `Rent`. |
| **BoxSurrendered** | Event | Raised by `Surrender`. Triggers policy `ReviewOnBoxSurrender` → `BoxSurrenderReview.Open` in Compliance. |
| **KeyIssued** | Event | Raised by `IssueKey`. |
| **KeyReturnDue** | Event | Raised by `Surrender`. Triggers policy `FlagKeyReturn` → `Notifications.Send` in Notifications. |
| **KeyReturned** | Event | Raised by `Return`. |
| **VisitAnnotated** | Event | Raised by `Annotate`. |
| **FlagKeyReturn** | Policy | On `KeyReturnDue`, dispatches `Notifications.Send` in Notifications. |
| **ReviewOnBoxSurrender** | Policy | On `BoxSurrendered`, dispatches `BoxSurrenderReview.Open` in Compliance. |

## ScheduledPayment

| Term | Kind | Definition |
|---|---|---|
| **ScheduledPayment** | Aggregate | An instruction held for a future date, which may execute once or be cancelled before it does. |
| **ScheduledPayment** | Lifecycle | Starts at `scheduled`. States: `scheduled`, `executed`, `cancelled`, `failed`, `abandoned`. |
| **InstructionReference** *(ScheduledPayment)* | Value Object | { value: String } |
| **PaymentDueDate** *(ScheduledPayment)* | Value Object | { value: String } Must satisfy: a payment due date is present. |
| **PaymentRecipient** *(ScheduledPayment)* | Value Object | { value: String } Must satisfy: a payment recipient is present. |
| **RetryCount** *(ScheduledPayment)* | Value Object | { value: Integer } Must satisfy: a retry count is non-negative. |
| **RetryLimit** *(ScheduledPayment)* | Value Object | { value: Integer } Must satisfy: a retry limit is positive. |
| **ScheduledAmount** *(ScheduledPayment)* | Value Object | { cents: Integer } Must satisfy: a scheduled payment amount is positive. |
| **Abandon** *(ScheduledPayment)* | Command | Give up on a payment that could not be collected after every retry |
| **Cancel** *(ScheduledPayment)* | Command | Call off a payment before its due date |
| **Execute** *(ScheduledPayment)* | Command | Collect a payment on its due date |
| **Fail** *(ScheduledPayment)* | Command | Record that today's presentment could not be collected |
| **Retry** *(ScheduledPayment)* | Command | Re-present a failed payment, up to the limit the schedule names |
| **Schedule** *(ScheduledPayment)* | Command | Set up a payment to collect on a future date |
| **Due** *(ScheduledPayment)* | Query | Payments still scheduled, ordered by when they're due. |
| **PaymentScheduled** | Event | Raised by `Schedule`. |
| **ScheduledPaymentAbandoned** | Event | Raised by `Abandon`. |
| **ScheduledPaymentCancelled** | Event | Raised by `Cancel`. |
| **ScheduledPaymentExecuted** | Event | Raised by `Execute`. |
| **ScheduledPaymentFailed** | Event | Raised by `Fail`, `Retry`. Triggers policy `RetryOnPaymentFailure` → `ScheduledPayment.Retry`. |
| **RetryOnPaymentFailure** | Policy | On `ScheduledPaymentFailed`, dispatches `ScheduledPayment.Retry`. |

## Statement

| Term | Kind | Definition |
|---|---|---|
| **Statement** | Aggregate | A snapshot of one account's activity over one period, generated once and never revised. |
| **StatementAmount** *(Statement)* | Value Object | { cents: Integer } |
| **StatementDate** *(Statement)* | Value Object | { value: String } Must satisfy: a statement is dated. |
| **StatementFrequency** *(Statement)* | Value Object | One of: { cadence: "monthly", retention_months: 84, paper_fee_cents: 0 }; { cadence: "quarterly", retention_months: 120, paper_fee_cents: 0 }; { cadence: "annual", retention_months: 240, paper_fee_cents: 500 }. |
| **StatementPeriod** *(Statement)* | Value Object | { value: String } Must satisfy: a statement names its period. |
| **Generate** *(Statement)* | Command | Close out one period's activity into a permanent record |
| **StatementGenerated** | Event | Raised by `Generate`. |

## Transfer

| Term | Kind | Definition |
|---|---|---|
| **Transfer** | Aggregate | Money leaving one account for another. Two movements that must both happen, or neither. |
| **Transfer** | Lifecycle | Starts at `requested`. States: `requested`, `debited`, `credited`, `settled`, `reversed`, `rejected`. |
| **Narrative** *(Transfer)* | Value Object | { text: String } Must satisfy: a transfer explains itself. |
| **TransferMoney** *(Transfer)* | Value Object | { cents: Integer } Must satisfy: a transfer amount is positive. |
| **TransferReference** *(Transfer)* | Value Object | { value: String } Must satisfy: a transfer is referenced. |
| **Credited** *(Transfer)* | Command | Record that the destination credit committed |
| **Debited** *(Transfer)* | Command | Record that the source account has given up the money |
| **Reject** *(Transfer)* | Command | Refuse a transfer before any money moved |
| **Request** *(Transfer)* | Command | Send money to another account |
| **Reverse** *(Transfer)* | Command | Put the money back when the credit could not be made |
| **Settle** *(Transfer)* | Command | Record that the destination has received it |
| **InFlight** *(Transfer)* | Query | Transfers that have left one account and not arrived at the other. The list that must always empty. |
| **TransferCredited** | Event | Raised by `Credited`. |
| **TransferDebited** | Event | Raised by `Debited`. |
| **TransferRejected** | Event | Raised by `Reject`. |
| **TransferRequested** | Event | Raised by `Request`. |
| **TransferReversed** | Event | Raised by `Reverse`. |
| **TransferSettled** | Event | Raised by `Settle`. |
| **Settlement** | Saga | Starts on `TransferRequested`, ends on `TransferSettled`. States: `requested` → `awaiting_credit` → `settled` → `reversed`. |

## Roles

| Term | Kind | Definition |
|---|---|---|
| **Back office** | Role | Issues `CorrectFee`, `CorrectInterest`, `Amend`, `Reverse`, `Retire`, `Abandon`. |
| **Branch clerk** | Role | Issues `Register`, `Close`, `Open`, `CloseAccount`, `Issue`, `Rent`. |
| **Compliance officer** | Role | Issues `Suspend`, `Reinstate`, `FreezeAccount`, `Unfreeze`, `Clear`, `Decline`, `Chargeback`, `RejectDispute`. |
| **Customer** | Role | Issues `Rename`, `Withdraw`, `Activate`, `Dispute`, `Surrender`, `Request`, `Recall`, `Schedule`, `Cancel`. |
| **System** | Role | Issues `ApplyFee`, `AccrueInterest`, `Capture`, `Void`, `Refund`, `Reverse`, `Generate`, `Debited`, `Settle`, `Credited`, `Reject`, `SendTransfer`, `Return`, `Execute`, `Fail`, `Retry`. |
| **Teller** | Role | Issues `Credit`, `Debit`. |
| **Vault officer** | Role | Issues `LogVisit`, `IssueKey`, `Annotate`, `Return`. |

## Read Models

| Term | Kind | Definition |
|---|---|---|
| **AccountsByKind** | Read Model | Every account the bank holds, sorted into what kind it is, then by its own number. |
| **ComplianceDashboard** | Read Model | One account, its own status, and any card charges disputed against it — the working set for a compliance review. |
| **CustomerPortfolio** | Read Model | A customer's cross-account position, rebuilt from aggregate heads. |
| **DisputedPaymentCount** | Read Model | How many of an account's own card charges are under dispute — a single number, not the rows themselves. |
| **DisputedPaymentMedian** | Read Model | The median amount of an account's own disputed card charges. |
