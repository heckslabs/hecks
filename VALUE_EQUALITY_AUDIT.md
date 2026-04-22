# Ruby/Rust Value-Equality Parity Audit

**Audit branch:** `miette/value-equality-parity-audit`
**Baseline:** `origin/main` @ 8ef8afb4
**Context:** follow-up to PR #262 (`compost_seasonal_beings` cascade regression).
**Scope:** inventory only — every divergence below needs its own PR.

PR #262 fixed one specific false-positive in Ruby's `Hecks::Behaviors::Value.equal?`
(Null == Str("") via a display-form tiebreaker). The hypothesis driving this
audit is that the same _class_ of bug — divergent coercion or divergent
display-form fallback — exists in other shapes. It does. **Twelve pairs**
disagree between Ruby's `Value.equal?` and Rust's `values_equal`; four are
plausibly cascade-dropping in real bluebooks.

---

## Method

1. Read both sides end-to-end:
   - Ruby: `lib/hecks/behaviors/value.rb` (the `Value.equal?` class method).
   - Rust: `hecks_life/src/runtime/interpreter.rs` (`values_equal` +
     `numeric_value`), plus `hecks_life/src/runtime/mod.rs`
     (`enum Value` + `impl Display for Value`).
2. Diffed the two algorithms pass by pass:
   structural equality → numeric coercion → display-form fallback.
3. Built a harness (`value_equality_audit_harness.rb`) that runs thirty-nine
   synthetic pairs through:
   - the _actual_ Ruby `Hecks::Behaviors::Value.equal?`, and
   - a line-faithful Ruby port of Rust's `values_equal`
     (cross-checked against live `rustc` runs for `f64::parse`
     and `HashMap == HashMap` semantics).
4. Tabulated every disagreement.

Both reference algorithms are short:

**Ruby `Value.equal?(a, b)`**
```
return true if a.kind == b.kind && a.raw == b.raw    # structural
an = a.numeric; bn = b.numeric                       # coercion
return an == bn if an && bn
a.to_display == b.to_display                         # display fallback
```

**Rust `values_equal(left, right)`**
```
if left == right { return true }                     # structural (derived PartialEq)
if let (Some(a), Some(b)) = (numeric_value(left), numeric_value(right)) {
    return a == b;                                   # coercion
}
format!("{}", left) == format!("{}", right)          # display fallback
```

The shape is identical. The bugs live in _what each step means_:

| Step | Ruby | Rust |
|---|---|---|
| Structural | `a.raw == b.raw` — inner `Value` objects have **no custom `==`**, so nested equality falls through to `Object#equal?` (identity). | `#[derive(PartialEq)]` on the `Value` enum — nested `Value`s compare structurally; `HashMap` ignores key order; `Vec` is positional. |
| Numeric `Str → f64` | `Float(s, exception: false)` — lenient; accepts whitespace, leading `.`, etc. | `s.parse::<f64>().ok()` — strict; rejects any whitespace, empty string. |
| Display `List` | `"[1, 2]"` — recurses into each element. | `"[N items]"` — **count only**. |
| Display `Map` | `"{a: 1, b: 2}"` — recurses; preserves insertion order. | `"{N fields}"` — **count only**. |
| Display `Null` | `""` (fix in PR #262 skips fallback when either side is Null, but the empty-string form is still exposed elsewhere). | `"null"` |

Those five cells generate every divergence below.

---

## Test cases

| # | Case | Ruby | Rust | Agrees |
|---|------|------|------|--------|
| 1 | `Null == Str("")` (PR #262 regression) | `true` | `false` | **NO** |
| 2 | `Null == Int(0)` | `true` | `true` | yes |
| 3 | `Null == Str("0")` | `true` | `true` | yes |
| 4 | `Null == Bool(false)` | `true` | `true` | yes |
| 5 | `Null == Null` | `true` | `true` | yes |
| 6 | `Null == []` | `false` | `false` | yes |
| 7 | `Null == {}` | `false` | `false` | yes |
| 8 | `Null == Str("null")` | `false` | `true` | **NO** |
| 9 | `Int(0) == Str("0")` | `true` | `true` | yes |
| 10 | `Int(1) == Str("1.0")` | `true` | `true` | yes |
| 11 | `Int(1) == Str("1.5")` | `false` | `false` | yes |
| 12 | `Int(0) == Bool(false)` | `true` | `true` | yes |
| 13 | `Int(1) == Bool(true)` | `true` | `true` | yes |
| 14 | `Str("1") == Bool(true)` | `true` | `true` | yes |
| 15 | `Str("true") == Bool(true)` | `true` | `true` | yes |
| 16 | `Str(" 1 ") == Int(1)` (whitespace) | `true` | `false` | **NO** |
| 17 | `Str("1e3") == Int(1000)` | `true` | `true` | yes |
| 18 | `Bool(false) == Int(0)` | `true` | `true` | yes |
| 19 | `Bool(false) == Null` | `true` | `true` | yes |
| 20 | `Bool(false) == Str("false")` | `true` | `true` | yes |
| 21 | `Bool(true) == Str("true")` | `true` | `true` | yes |
| 22 | `Bool(true) == Str("TRUE")` | `false` | `false` | yes |
| 23 | `Str("foo") == Str("FOO")` | `false` | `false` | yes |
| 24 | `Str("") == Str("")` | `true` | `true` | yes |
| 25 | `Str("abc") == Str("abc")` | `true` | `true` | yes |
| 26 | `[1,2] == [1,2]` | `true` | `true` | yes |
| 27 | `[1,2] == [2,1]` (order) | `false` | `true` | **NO** |
| 28 | `[1,2] == [3,4]` (same length, different content) | `false` | `true` | **NO** |
| 29 | `[] == []` | `true` | `true` | yes |
| 30 | `[] == Str("[]")` | `true` | `false` | **NO** |
| 31 | `[] == Str("[0 items]")` | `false` | `true` | **NO** |
| 32 | `{a:1} == {a:1}` | `true` | `true` | yes |
| 33 | `{a:1} == {b:1}` (same size, different keys) | `false` | `true` | **NO** |
| 34 | `{a:1,b:2} == {b:2,a:1}` (insertion order) | `false` | `true` | **NO** |
| 35 | `{} == Str("{0 fields}")` | `false` | `true` | **NO** |
| 36 | `{} == Str("{}")` | `true` | `false` | **NO** |
| 37 | `Float 1.0 (Ruby-side Str) == Int(1)` | `true` | `true` | yes |
| 38 | `Int(2) == Str("[2 items]")` | `false` | `false` | yes |
| 39 | `[a,b] == [c,d]` (same length, different content) | `false` | `true` | **NO** |

**Totals:** 39 cases, 27 agreements, **12 disagreements**.

---

## Disagreements — root cause, fix sketch, severity

Severity grades:
- **cascade-dropping** — plausible to appear in a real bluebook `given` and
  silently halt a cascade (same class as PR #262).
- **cosmetic** — likely only surfaces in synthetic inputs; still a parity bug.
- **design-gap** — both sides disagree _and_ both sides are arguably wrong;
  needs a spec decision before picking a side to fix.

### 1. `Null == Str("")` — PR #262 regression baseline
Ruby `true`, Rust `false`. **Already fixed** on the PR #262 branch; included
here as the control. Severity: cascade-dropping (historical).

### 2. `Null == Str("null")` (case 8)
- **Ruby:** `Null.to_display == ""`, `Str("null").to_display == "null"`,
  fallback says no.
- **Rust:** `Null.display == "null"`, `Str("null").display == "null"`,
  fallback says yes.
- **Fix sketch:** change Rust `Display(Null)` from `"null"` to `""`, OR
  drop the display-form fallback when either side is `Null` (same shape
  as PR #262). Symmetric with PR #262 — only flipped.
- **Severity: cascade-dropping.** A `given { status != "null" }` where
  `status` is the literal string `"null"` (rare but possible in e.g. a
  parsed CSV) would fire in Ruby, be blocked in Rust.

### 3. `Str(" 1 ") == Int(1)` (case 16)
- **Ruby:** `Float(" 1 ", exception: false) == 1.0`, Ruby's `Float()` trims.
- **Rust:** `" 1 ".parse::<f64>()` returns `Err`; numeric coercion bails;
  display `" 1 "` vs `"1"` differ.
- **Fix sketch:** make Ruby `Value#numeric` strip-reject: return `nil`
  for any `Str` that isn't already trimmed. Mirrors Rust's `f64::parse`.
- **Severity: cascade-dropping.** Any attribute piped through a stringy
  source (CSV cell, JSON body, user input without normalization) can end
  up as `" 1 "` and silently switch on one runner only.

### 4. `[1,2] == [2,1]` (list order) (case 27)
- **Ruby:** `raw == raw` is `Array#==` on `Hecks::Behaviors::Value` objects,
  but `Value` has no custom `==` so elements compare by identity → `false`.
  Display `"[1, 2]"` vs `"[2, 1]"` → `false`. Correct result _by luck_.
- **Rust:** derived `Vec<Value>` `==` is positional → `false` for reversed.
  But then `Display` for both is `"[2 items]"` → fallback says **equal**.
- **Fix sketch:** Rust should early-return on structural inequality for
  List/Map rather than falling through to a display-count fallback. (Or:
  make Rust's Display recursive like Ruby's.)
- **Severity: cascade-dropping.** Any `given { members != members_before }`
  across a list reorder fires in Ruby, is blocked in Rust.

### 5. `[1,2] == [3,4]` (same-length different-content) (case 28)
Same root cause as case 27. Rust falls back to `"[2 items]" == "[2 items]"`
and says **equal**. Severity: **cascade-dropping**. More dangerous than
reorder — this is "different-but-same-size" which is common (two lists
of ingredients, two event queues, etc.).

### 6. `[] == Str("[]")` (case 30)
- **Ruby:** `"[]".to_display == "[]"` fallback matches.
- **Rust:** `Str("[]").display == "[]"`, `[].display == "[0 items]"`, differ.
- **Fix sketch:** this one the display-form disagreement between runners
  does the work. Aligning Rust Display to Ruby's (`"[]"` for empty list)
  or vice versa will flip it. Given PR #262's direction (skip display when
  either side is "specialish"), prefer: don't compare list/map by
  display form at all — structural only.
- **Severity: cosmetic.** `given { items == "[]" }` is implausible real-world;
  authors write `items.empty?`.

### 7. `[] == Str("[0 items]")` (case 31)
- Inverse of case 30. Ruby false, Rust true (Rust's display form collides
  with the literal). Severity: **cosmetic** but demonstrates the
  `[N items]` display form is leaking into equality.

### 8. `{a:1} == {b:1}` (same-size different-keys) (case 33)
Same shape as case 28 but for Map. Ruby `false`, Rust `true` via
`"{1 fields}" == "{1 fields}"`. **Cascade-dropping.** Two records with
the same number of fields but different field names are considered
equal in Rust.

### 9. `{a:1,b:2} == {b:2,a:1}` (insertion order) (case 34)
- **Rust:** derived `HashMap == HashMap` is order-independent → `true`
  structurally.
- **Ruby:** inner `Value` identity makes `raw == raw` `false`; `to_display`
  is insertion-ordered `"{a: 1, b: 2}"` vs `"{b: 2, a: 1}"` — differs.
- **Fix sketch:** define `Hecks::Behaviors::Value#==` / `#eql?` /
  `#hash` properly (structural, kind + raw) so nested lists/maps
  compare by value. Once that's in place, Ruby Hash `==` will handle
  order-insensitivity for free and these cases align with Rust.
- **Severity: cascade-dropping.** Any `given { attrs == prior_attrs }`
  where attrs come from a HashMap-backed state store can flip purely
  on insertion-order differences.

### 10. `{} == Str("{0 fields}")` (case 35)
Inverse of case 8 for maps. Ruby `false`, Rust `true` (literal string
equals Rust's display form for empty map). Severity: **cosmetic**.

### 11. `{} == Str("{}")` (case 36)
- **Ruby:** display `"{}"` vs `"{}"` → `true`.
- **Rust:** display `"{0 fields}"` vs `"{}"` → `false`.
Severity: **cosmetic** — but confirms the Display inconsistency runs
in both directions.

### 12. `[a,b] == [c,d]` (string-content differ, same length) (case 39)
Same root as case 28. Strings instead of ints; Rust still says
`"[2 items]" == "[2 items]"` → **equal**. Severity: **cascade-dropping**.

---

## Summary of bug classes

| Class | Cases | Severity | Root cause |
|---|---|---|---|
| Rust Display-count collision for List | 27, 28, 30, 31, 39 | cascade-dropping + cosmetic | `impl Display for Value::List` emits `"[N items]"` — not a diagnostic-only form, it's load-bearing in equality. |
| Rust Display-count collision for Map | 33, 35, 36 | cascade-dropping + cosmetic | `impl Display for Value::Map` emits `"{N fields}"` — same issue. |
| Ruby `Null` display is empty string | 1 (fixed), 8 | cascade-dropping | `Null.to_display == ""` leaks into comparisons. PR #262 patched half; case 8 remains the mirror. |
| Ruby `Float()` accepts whitespace | 16 | cascade-dropping | Ruby `Float(s, exception: false)` trims; Rust `f64::parse` doesn't. |
| Ruby `Value` lacks structural `==` | 27, 28, 33, 34, 39 (secondary) | latent | Without `Value#==`, nested equality depends on object identity; masked today only because `to_display` _happens_ to recurse. Any refactor of display form would re-expose this. |

**Count:** 12 disagreements / 39 cases.
**Severity distribution:** 7 cascade-dropping, 5 cosmetic, 0 design-gap.

---

## Recommended follow-up inbox items (do **not** file yet)

Each of these should become its own Linear issue + PR. They are ordered by
severity, not by effort.

1. **Rust: drop display-form fallback for `List`/`Map`** — structural
   inequality should be final, don't let `"[N items]"` act as a
   comparison primitive. Fixes cases 27, 28, 30, 31, 39.
2. **Rust: drop display-form fallback for `Map`** (same as #1 but
   separately scoped if one lands first) — fixes cases 33, 35, 36.
3. **Ruby: mirror PR #262 fix for `Str("null")`** — when either side is
   `Null`, skip the display fallback (currently fallback uses `""` vs
   `"null"` which hides the bug; case 8 shows it still leaks).
   Alternative: change `Null.to_display` to return `"null"` and revisit
   PR #262's direction. Needs a spec decision.
4. **Ruby: strict numeric coercion for `Str`** —
   `Value#numeric` for `:str` should reject whitespace (and empty
   string, already does). Mirror Rust's `f64::parse` semantics. Fixes
   case 16.
5. **Ruby: define structural `==` / `eql?` / `hash` on
   `Hecks::Behaviors::Value`** — so nested list/map comparisons use
   value identity, not object identity. Precondition for many other
   fixes (e.g. once Rust stops falling back to display for lists, Ruby
   will need real structural equality for list-content cases to stay
   green). Latent-bug class (currently masked by `to_display`).
6. **Consider a shared test harness** — the
   `tmp_audit/harness.rb` pattern (run the same pairs through both
   runners) is cheap; promote it to `hecks_life/tests/` or
   `spec/parity/` and gate CI on it. Would have caught PR #262 before it
   shipped.

---

## Appendix — harness source

See `value_equality_audit_harness.rb`. To re-run:

```
ruby value_equality_audit_harness.rb
```

The harness loads the real `Hecks::Behaviors::Value` from `lib/` and runs
it alongside a line-faithful port of `values_equal` / `numeric_value` /
`Display for Value` from `hecks_life/src/runtime/`. The Rust port was
spot-checked against `rustc` for `f64::parse` whitespace rejection and
`HashMap == HashMap` order-independence — both behave as ported.
