# Bug #130: Transfer.Debited Missing Destination Validation

**Severity:** HIGH  
**Type:** Missing Cross-Aggregate Validation  

## Problem

Transfer.Debited validates source but not destination. Money leaves source for an account that might be closed.

## Fix

Add destination account/customer validation to ensure the receiving account is valid.
