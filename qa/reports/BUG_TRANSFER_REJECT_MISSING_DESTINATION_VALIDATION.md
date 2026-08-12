# Bug #131: Transfer.Reject Missing Destination Validation

**Severity:** MEDIUM  
**Type:** Missing Cross-Aggregate Validation  

## Problem

Transfer.Reject validates source but not destination. Can reject transfers to closed/suspended accounts without validation.

## Fix

Add destination account/customer validation.
