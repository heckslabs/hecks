# Bug #18: ATMCard.Activate Missing Status Guard

**Severity:** HIGH  
**Type:** State Machine Enforcement Gap  
**File:** examples/banking/bluebook/banking.bluebook  
**Lines:** 579-585

## Problem

ATMCard.Activate command has no guard to enforce it only activates "issued" cards. The lifecycle declares `transition "Activate" => "active", from: "issued"` but the command lacks guards.

## Impact

- Can activate already-active cards
- Can activate retired cards
- Card state corrupted
- Usage analytics inaccurate

## Fix

Add guard to enforce status == "issued" before allowing activate.
