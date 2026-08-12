# Bug #62: Visit.Annotate Missing Box Status Guard

**Severity:** MEDIUM  
**Type:** Cross-aggregate State Validation Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 1177-1189

## Problem

Visit.Annotate command has a guard on visit state but no guard to enforce the box is "rented". Visits can only be annotated on rented boxes, not vacant or surrendered ones.

## Impact

- Can annotate visits on vacant boxes
- Can annotate visits on surrendered boxes
- Vault audit trail corrupted
- Visit tracking inconsistent

## Fix

Add guard to enforce parent.status == "rented" before allowing annotation.
