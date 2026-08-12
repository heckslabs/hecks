# Bug #92: Command.name Returns Nil - CRITICAL

**Status:** IDENTIFIED  
**Severity:** CRITICAL (Command identification broken)  
**Type:** Data Loading/Representation Bug  
**GitHub Issue:** TBD

---

## The Bug

Command objects loaded from the bluebook do not have accessible names at runtime, despite the golden IR containing command names.

**Evidence:**

Golden IR (Banking.json) contains command names:
```json
"commands": [
  { "name": "Register", ... },
  { "name": "Suspend", ... },
  { "name": "Reinstate", ... },
  { "name": "Close", ... }
]
```

But at runtime, command.name returns nil:
```ruby
bluebook = runtime.registry.bluebook('Banking')
account = bluebook.aggregates.find { |a| a.name == 'Account' }
account.commands.first.name  # => nil (should be "Open" or similar)
```

---

## Root Cause

The IR::Command class (or its loading/instantiation) is not properly setting or exposing the name attribute that exists in the golden IR JSON.

Possible causes:
1. IR::Command class missing name accessor
2. Loader not setting name from JSON
3. Ruby representation class doesn't expose name

---

## Business Impact

**CRITICAL** - Command names are essential for identification and diagnostics. This affects:
- Command identification in dispatches
- Error messages that reference commands
- Facade method generation (commands without names can't be exposed as methods)
- Debugging and logging

---

## Related Issue

This may explain why guide doctests fail with "undefined method `rent'" - the facade can't generate methods for commands that don't have names.

---

## Files Involved

- `lib/hecksagain/bluebook/ir/command.rb` (likely)
- Command loading/instantiation code
- Facade generation code

---

## Next Steps

1. Check IR::Command class for name attribute
2. Verify loader sets name from JSON
3. Check facade generation to see if it uses command.name
