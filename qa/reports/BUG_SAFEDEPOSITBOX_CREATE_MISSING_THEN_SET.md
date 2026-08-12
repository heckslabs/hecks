# Bug #123: SafeDepositBox.Create Missing then_set

**Severity:** HIGH  
**Type:** Missing Attribute Persistence  

## Problem

SafeDepositBox.Create accepts branch_code and box_number attributes but never persists them to the box record.

## Fix

Add `then_set :branch_code, to: :branch_code` and `then_set :box_number, to: :box_number`.
