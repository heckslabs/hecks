# Bug #86: Compliance Domain - Empty Bluebook Causes Fuzzer Crash - CRITICAL

**Status:** IDENTIFIED  
**Severity:** CRITICAL (Framework crash)  
**Type:** Configuration/Framework Bug  
**GitHub Issue:** #101

---

## The Bug

Fuzzer crashes with `NoMethodError: undefined method 'aggregates' for nil` when testing the Compliance domain.

**Error:**
```
── compliance
   100 seeds executed (100 drawn) — 0 clean, 100 found something
   1 distinct finding(s):

   (1) crash: NoMethodError — NoMethodError: undefined method `aggregates' for nil
       100 of 100 seeds: 1, 2, 3, 4, 5, 6, 7, 8, …
```

**All 100 seeds crash with identical error** - this is not a random failure but a systematic issue.

---

## Root Cause

The Compliance domain exists (`examples/compliance/`) but has an **empty bluebook directory**:

```
examples/compliance/bluebook/ (empty - no .bluebook files)
```

When the fuzzer boots the domain:
1. `Hecks.boot(domain_path)` successfully boots but loads 0 bluebooks
2. `runtime.registry.bluebooks` is empty (length 0)
3. `Replay.call` returns `bluebook: nil` (because `.values.first` on empty hash returns nil)
4. `Properties.check(history)` crashes when trying to call `.aggregates` on nil

**Exact call stack:**
```ruby
# replay.rb line 105
bluebook: runtime.registry.bluebooks.values.first  # returns nil if empty

# properties.rb line 32
bluebook.aggregates.each do |aggregate|  # crashes: undefined method 'aggregates' for nil
```

---

## Framework Impact

**CRITICAL** - This reveals a framework-level issue:

1. **Fuzzer cannot test empty domains** - should handle gracefully
2. **No nil-check in Properties** - crashes on nil bluebook
3. **Compliance domain exists but is incomplete** - unclear purpose

---

## Business Impact

The Compliance domain is non-functional and the fuzzer cannot test domains with empty bluebooks.

---

## Fix Options

### Option 1: Handle nil gracefully in Properties
Add nil-check before trying to access bluebook methods:

```ruby
def lifecycle_values_are_declared(history)
  bluebook = history.fetch(:bluebook)
  return true unless bluebook  # Handle empty domain gracefully
  
  declared = {}
  bluebook.aggregates.each do |aggregate|
    # ...
  end
end
```

### Option 2: Validate domain has bluebooks before fuzzing
Add validation in `bin/fuzz` or fuzzer to skip/warn on empty domains:

```ruby
if runtime.registry.bluebooks.empty?
  puts "── #{name} (SKIPPED: no bluebook definitions)"
  return true  # Clean skip, not a crash
end
```

### Option 3: Add Compliance domain definitions
Populate `examples/compliance/bluebook/` with actual domain definitions if this is an example domain.

---

## Recommendation

Implement **Option 1 + Option 2** together:
1. Add nil-check in Properties for defensive programming
2. Add validation in fuzzer to gracefully skip empty domains
3. Clarify Compliance domain purpose - is it intentionally empty or incomplete?

---

## Related Files

- `lib/hecksagain/fuzzing/replay.rb` (line 105)
- `lib/hecksagain/fuzzing/properties.rb` (line 32)
- `bin/fuzz` (fuzzing orchestrator)
- `examples/compliance/bluebook/` (empty directory)

---

## Test Evidence

```
Direct boot test:
  runtime.registry.bluebooks.length => 0
  runtime.registry.bluebooks.values.first => nil

Fuzzer output:
  100 seeds executed => 100 found something (all crash)
  Error: NoMethodError: undefined method 'aggregates' for nil
```

---

## Discovered Via

Property-based fuzzer (bin/fuzz) with 100 seeds and varied step counts.
