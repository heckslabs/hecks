# Bug #71: SafeDepositBox.Rent Missing Reference

**Status:** FIXED

## The Bug

SafeDepositBox.Rent command was missing `reference_to SafeDepositBox`, causing it to attempt creating a new SafeDepositBox instead of referencing the existing one.

**Before Fix:**
```ruby
command "Rent" do
  role "Branch clerk"
  goal "Assign the box to a customer"

  reference_to Customer
  attribute :branch_code, BranchCode
  attribute :box_number,  BoxNumber
  attribute :size,        Size
  
  then_set :size, to: :size
  emits "BoxRented"
end
```

**Error Encountered:**
```
AlreadyExists: Rent creates a SafeDepositBox that already exists — branch_code.value, box_number.value "MAIN:100"
```

## Root Cause

The Rent command didn't declare `reference_to SafeDepositBox`, so the runtime treated it as a creating command. When called with an existing SafeDepositBox ID (composite key: branch_code:box_number), the runtime attempted to create a duplicate, which violated the constraint that identities must be unique.

## The Fix

Added `reference_to SafeDepositBox` to properly reference the existing box:

```ruby
command "Rent" do
  role "Branch clerk"
  goal "Assign the box to a customer"

  reference_to SafeDepositBox
  reference_to Customer
  attribute :size, Size

  then_set :size, to: :size
  emits "BoxRented"
end
```

Also removed branch_code and box_number attributes from the command since they come from the SafeDepositBox reference.

## Verification

After fix:
```
✓ Box created: MAIN:100
✓ Box rented successfully
Box status: rented
```

## Pattern

This is the inverse of Bug #70 (CreatePizza). While CreatePizza incorrectly had explicit then_sets (when auto-assignment would have worked), SafeDepositBox.Rent was missing proper reference resolution (which auto-assignment cannot compensate for).

The distinction:
- **Creating commands**: Can omit then_set if using auto-assignment
- **Non-creating commands**: MUST declare reference_to to find the aggregate

## Commit

Fixed in current session - banking.bluebook lines 1201-1213.
