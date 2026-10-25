# Process managers in plain sentences (draft)

**Status: draft, not parsed.** Nothing here runs yet. It is the proposed wording for the sentence
form (ADR 0131), written against the Ruby-form `Settlement` and `ExternalSettlement` process
managers in `examples/banking/bluebook/transfers_and_payments.bluebook`.

## Settlement

```
Process: Settlement
  A transfer moves money out of one account and into another, and is undone if a leg refuses.

  It follows a transfer by its reference.
  It starts when TransferRequested is announced.
  It ends when TransferSettled is announced.

  When TransferRequested is announced, a settlement is requested
    Then Debit runs on the source account with the amount, the narrative "transfer out" and the reference
      If it is refused later, Credit runs on the source account with the amount and the narrative "transfer reversed"

  When AccountDebited is announced, a requested settlement is awaiting credit
    Then Debited runs on the transfer
    And Credit runs on the destination account with the amount, the narrative "transfer in" and the reference

  When AccountCredited is announced, an awaiting-credit settlement stays awaiting credit
    Then Credited runs on the transfer

  When TransferCredited is announced, an awaiting-credit settlement is settled
    Then Settle runs on the transfer

  When any step is refused, an awaiting-credit settlement is reversed
    Then Reverse runs on the transfer
```

## ExternalSettlement

```
Process: External Settlement
  An outgoing transfer on the external network, returned if the network refuses it.

  It follows a transfer by its end to end.
  It starts when ExternalTransferRequested is announced.
  It ends when ExternalTransferSent is announced.

  When ExternalTransferRequested is announced, a settlement is requested
    Then SendTransfer runs with the end to end

  When any step is refused, a requested settlement is returned
    Then Return runs with the end to end
```

## How each sentence maps to the Ruby form

| Sentence | Ruby form |
|---|---|
| `Process: <Name>` | `process_manager "<Name>"` |
| `It follows a <aggregate> by its <field>.` | `correlates_by :"<field>.value"` |
| `It starts when <Event> is announced.` | `starts_on <Event>` |
| `It ends when <Event> is announced.` | `ends_on <Event>` |
| `When <Event> is announced, a <from> <thing> is <to>` | `transition <Event> => "<to>", from: "<from>"` |
| `Then <Command> runs on the <name> …` | `dispatch <Command>, with: { … }` |
| `And <Command> runs …` | a second `dispatch` in the same transition |
| `If it is refused later, <Command> runs …` | `compensates <Command>, with: { … }` on that dispatch |
| `When any step is refused, …` | `transition :refused => "<to>", from: "<from>"` |
| `stays <state>` | a transition whose target equals its `from:` |

## Choices to settle before parsing

1. **Binding wording.** `with: { number: :source, amount: :amount }` becomes `runs on the source
   account with the amount`. The words after `with the` must resolve to a field of the opening
   event's payload, checked against the domain like every other name. A literal narrative reads
   `the narrative "transfer out"`.
2. **Addressing.** `transfer: :reference` (the record's own reference key, filled with the
   correlation) becomes `on the transfer`. This only works when the command's reference
   aggregate is unambiguous.
3. **`compensates`** is written under the dispatch it undoes, so the undo reads next to what it
   undoes. The Ruby form has the same nesting.
4. **State names.** A multi-word state reads `awaiting credit` in prose and is stored as
   `awaiting_credit`, as lifecycle states are in the guide.
5. **Event naming.** An event another aggregate announces needs `announced by an account`, as
   policies do (`Whenever CreditCleared is announced by an order`).
6. **Refused.** `:refused` is not an event. It is the saga's own failure signal, so it gets its own
   sentence and cannot be confused with an announcement.
7. **Examples.** `Examples for:` can drive a process by announcing its starting event and
   expecting the dispatches in order (`Then Debit is run on the source account`). This is the
   piece that would let a process be shown without a live run.

## Not decided here

- Whether a state list is ever declared, or always implied by the transitions. The Ruby form
  implies it, and this draft follows that.
- Timeouts and scheduled steps. The Ruby form has none to map.
- Whether handlers may branch (`If the amount is over …`). It has none to map either.
