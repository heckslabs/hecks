# Bug #30: Visit.Annotate Missing State Guard

**Severity:** MEDIUM  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 1164-1174

## Problem

Visit.Annotate command has no guard to enforce it only annotates "logged" visits. The lifecycle declares `transition "Annotate" => "logged", from: "logged"` but the command lacks guards (though it's a self-loop).

## Impact

- Can annotate visits in unknown state (if state ever changes)
- Audit trail inconsistent
- Future refactoring risk if lifecycle changes

## Fix

Add guard to enforce state == "logged" before allowing annotate, even though it's a self-loop.
