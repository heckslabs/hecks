# Bugs #103-105: Structural IR Issues - CRITICAL

**Status:** IDENTIFIED  
**Severity:** CRITICAL (IR integrity compromised)  
**Type:** Data Structure Validation  

---

## Bug #103: Duplicate Event Emissions

**Issue:** ScheduledPaymentFailed event is emitted by multiple commands

**Evidence:**
- Banking domain emits "ScheduledPaymentFailed" more than once across different commands
- Same event name used in multiple contexts

**Impact:**
- Event handlers may receive duplicate events
- Policies listening for this event may fire multiple times
- Can cause state machine violations

---

## Bug #104: Policies Reference Unknown Commands

**Issue:** Multiple policies trigger commands in domains that don't exist in the current bluebook

**Evidence:**
- Policy "ReviewOnFreeze" triggers "Compliance.OpenReview" (Compliance domain not in Banking IR)
- Policy "NotifyOnClosure" triggers "Notifications.Send" (Notifications domain not in Banking IR)
- Policy "ReviewOnBoxSurrender" triggers "Compliance.OpenReview"
- Policy "FlagKeyReturn" triggers "Notifications.Send"

**Impact:**
- CRITICAL: Policies will fail at runtime when trying to trigger non-existent commands
- Cross-domain policies not properly validated
- Commands will be refused with "unknown command" errors

**Root Cause:**
- Policies can reference commands in external domains (by design)
- But validation doesn't check if external domain is registered
- Or the cross-domain reference format is incorrect

---

## Bug #105: Lifecycle Field Not in Aggregate Attributes

**Issue:** Many aggregates declare lifecycle with a field that doesn't exist in their attributes

**Evidence:**
- Customer aggregate: lifecycle field 'status' not in attributes
- Account aggregate: lifecycle field 'status' not in attributes  
- ATMCard aggregate: lifecycle field 'status' not in attributes
- Transfer aggregate: lifecycle field 'status' not in attributes
- CardPayment aggregate: lifecycle field 'status' not in attributes
- ExternalTransfer aggregate: lifecycle field 'status' not in attributes
- ScheduledPayment aggregate: lifecycle field 'status' not in attributes
- SafeDepositBox aggregate: lifecycle field 'status' not in attributes
- OnboardingCase aggregate: lifecycle field 'status' not in attributes

**Pattern:** All lifecycle declarations reference 'status' field, but this field is NOT declared as an aggregate attribute.

**Impact:**
- CRITICAL: Lifecycle state cannot be stored/loaded
- Aggregate state will be incomplete
- Lifecycle transitions may silently fail
- Persistence layer cannot persist the lifecycle value

**Root Cause:**
- Lifecycle field declarations are missing from aggregate attribute lists
- Framework should validate that lifecycle fields are declared as attributes
- This is likely a bluebook DSL issue where `state_field` should auto-create an attribute

---

## Summary

**3 Categories of Bugs Found:**

1. **Duplicate Events (#103)** - Single event name used multiple times
2. **Cross-Domain References (#104)** - Policies trigger commands in undefined domains
3. **Missing Lifecycle Attributes (#105)** - 9 aggregates missing their lifecycle field as an attribute

**Total Instances:** 14 distinct occurrences across 3 bug categories

**Severity:** All CRITICAL - they affect core domain functionality

---

## Recommendations

### Immediate Fixes

1. **Bug #103** - Rename or consolidate duplicate ScheduledPaymentFailed events
2. **Bug #104** - Validate that cross-domain policy references exist OR move policies to the correct domain
3. **Bug #105** - Add missing 'status' attribute to all 9 aggregates, OR fix bluebook DSL to auto-create it

### Framework Improvements

- Add validation: lifecycle field must be declared as attribute
- Add validation: cross-domain policy references must exist
- Add validation: event names must be unique within domain
- Consider auto-creation of lifecycle field attribute in DSL
