# Bug #77: Pizzas.Order.CreatePizza Size one_of Validation Not Enforced

**Status:** IDENTIFIED

## The Bug

CreatePizza command accepts any size value, ignoring the one_of constraint that should restrict sizes to "small" and "large".

**Evidence:**
```ruby
# All of these succeed (should fail)
- size: "medium" ✓ (should fail)
- size: "xl" ✓ (should fail)
- size: "tiny" ✓ (should fail)
- size: "huge" ✓ (should fail)
- size: "extra-large" ✓ (should fail)

# Valid sizes still work
- size: "small" ✓
- size: "large" ✓
```

## Root Cause

The Size VO has a one_of declaration:
```ruby
value_object "Size" do
  attribute :value, String, pattern: '[^ \t\n\r]'

  one_of do
    member value: "small"
    member value: "large"
  end
end
```

But the one_of validation is NOT being enforced for Size, even though the same pattern works correctly for AccountKind.

## Comparison

**AccountKind** (WORKING):
```ruby
value_object "AccountKind" do
  attribute :name, String
  
  one_of do
    member name: "current"
    member name: "savings"
    member name: "reserve"
  end
end
```
- ✓ "premium" correctly rejected
- ✓ Valid kinds accepted

**Size** (BROKEN):
```ruby
value_object "Size" do
  attribute :value, String, pattern: '[^ \t\n\r]'
  
  one_of do
    member value: "small"
    member value: "large"
  end
end
```
- ✗ Invalid sizes accepted
- ✓ Valid sizes accepted

## File Location

examples/pizzas/bluebook/pizzas.bluebook (Size VO definition)

## Impact

HIGH - Invalid pizza sizes can be created, violating business constraints.

## Possible Root Causes

1. The pattern validation might be interfering with one_of validation
2. The Size one_of validation might not be compiled correctly
3. Framework bug in how one_of works with pattern-validated strings
4. Size validation might be disabled somewhere in Pizza aggregate

## Business Impact

Business logic violation - only specific sizes should be offered but system accepts arbitrary values.

