# Bug #107: Commands Missing Role - HIGH

**Status:** IDENTIFIED  
**Severity:** HIGH (Missing required metadata)  
**Type:** Documentation/Validation Gap  

---

## The Bug

18 commands in the Banking domain are missing the required `role` field that describes who can execute the command.

**Evidence:**
- Account: ApplyFee, CorrectFee, AccrueInterest, CorrectInterest
- CardPayment: Authorize, Capture, Void, Refund, Reverse, Chargeback, RejectDispute
- ExternalTransfer: Request, Send, Recall, Return
- ScheduledPayment: Schedule, Execute, Cancel

**Impact:**
- Commands lack role-based access control specification
- Security implications (who should be able to execute each command is undefined)
- Documentation incomplete

**Severity:** HIGH - Security/authorization gap

---

## Root Cause

The golden IR for Banking domain has commands without `role` field. Either:
1. Commands were declared without role in the bluebook
2. Role field is optional but should be required
3. Role validation is not enforced during IR generation

---

## Related Findings

This complements Bug #106 (missing goals). Commands lack both role and goal documentation.

---

## Fix Required

Add role specification to all 18 commands:
```
command "ApplyFee" do
  role "Bank Officer"  # Add this
  ...
end
```

Or enforce that role is required during IR validation.
