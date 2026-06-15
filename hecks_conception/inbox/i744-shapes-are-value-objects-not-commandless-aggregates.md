# i744 — Shapes are value objects inside the behavioural aggregate, not command-less wrapper aggregates

**Filed:** 2026-06-15. **Found via:** the bucket-3 step-2 validator block (a
staged `*_shape.bluebook` failed `aggregates_have_commands`). Chris drove the
diagnosis Socratically ; this card captures the root so the patch isn't lost.

## The smell that started it

Staging `codegen/hecksagon_parser_shape/hecksagon_parser_shape.bluebook` tripped
the pre-commit validator gate :

```
INVALID — 1 errors: HecksagonParserShape has no commands
```

The reflex fix was "add `autophagy` to the validator's `skip_if_category` list"
(it already skips `meta`). That treats the symptom and **cements** the smell.

## The evidence chain (each link verified in-tree)

1. **`category "meta"` does exactly one thing** — `rust/src/validator.rs:47` :
   `if domain.category.as_deref() == Some("meta") { return vec![]; }`. Its only
   job is to skip the `aggregates_have_commands` rule. Nothing else reads it.

2. **The `meta` tag is mostly vestigial** — of ~20 `category "meta"` books,
   almost all are *behavioural* and pass the rule anyway : `catalog/law` (12
   commands), `catalog/court` (9), `world/generation/shard` (2), the
   `library/training/*` books (1+ each). The skip excuses nothing for them.

3. **The genuinely command-less aggregates are ALL codegen shapes** — every
   `cmds=0` bluebook is a `codegen/*_shape` (`validator_shape`,
   `hecksagon_parser_shape`, `repository_shape`, `runtime_shape`, …, ~25 of
   them) plus exactly one domain book : `language/grammar/bluebook.bluebook`
   (the self-describing IR grammar — also a schema). **There is not one
   legitimate command-less *behavioural* aggregate in the lexicon.**

4. **A shape is double-modelled** — in the shape bluebook the row-types are
   `value_object`s trapped in a dummy wrapper aggregate ; in the sibling
   `.fixtures` the *same* names are `aggregate`s holding instances :

   ```
   # hecksagon_parser_shape.bluebook
   aggregate "HecksagonParserShape" do
     value_object "LineParser"   do … end
     value_object "LineDispatch" do … end
     value_object "ParserHelper" do … end
   end

   # hecksagon_parser_shape.fixtures
   aggregate "LineDispatch" do  fixture "Binding", …  fixture "Family", … end
   ```

   The truth is simpler : `LineDispatch` is a **record type**, each fixture row
   is an **instance**. Type + instances — value-object-shaped.

5. **The wrapper aggregate is pure ceremony forced by i555** — the locked
   macrophage rule `bluebook_top_level_value_object` forbids standalone
   value_objects (every VO must live inside an aggregate). A shape has no
   behavioural aggregate to host its row-types, so it invents an empty one.
   **i555 stays** : VOs belong inside aggregates. The fix is to host them in the
   *right* aggregate, not to relax the rule.

## The model already exists : `Specializer`

`codegen/specializer/specializer.bluebook` is the correct shape, today :

```
aggregate "Specializer" do            # has the Specialize COMMAND — behavioural
  value_object "IRLayer"            do … end
  value_object "Projection"        do … end
  value_object "SpecializerTarget" do … end   # name, source_bluebook, output_rs
  value_object "SpecializerSubclass" do … end  # shape_path, target_rs_path …
  command "Specialize" …
end
```

Behaviour (`Specialize`) on the aggregate ; the codegen catalog (targets,
layers, projections) as **value objects inside it** ; it already carries
`shape_path`, so it *knows about* the shapes. This is value-objects-inside-a-
command-bearing-aggregate — exactly what every `*_shape` should be.

## The fix (the arc)

Fold each `*_shape` bluebook's row-type value_objects into the **behavioural
aggregate that acts on them** (the specializer / its target) instead of giving
each shape its own headless wrapper aggregate. Then :

- every shape's value objects sit inside a command-bearing aggregate
- `aggregates_have_commands` is simply true — no exceptions
- the `meta` AND `autophagy` category-skips both **retire** (their whole reason
  to exist is gone)
- i555 is untouched (VOs still live inside aggregates)
- `validator.rs:47` and `validator_shape.fixtures :: skip_if_category` delete

## Scope / cost

Real arc — ~25 `codegen/*_shape.bluebook` files + their sibling `.fixtures` +
however each specializer walks them (the specializers read fixtures by
aggregate name, so the regrouping touches the read path) + the `bluebook.bluebook`
grammar. Goldens re-baseline as shapes move. **NOT** a one-liner ; do it as its
own thread, deliberately, with the parity/golden gates green at each step.

## Do NOT, in the meantime

- Do **not** add `autophagy` to `skip_if_category` — it entrenches the wrapper
  this card removes.
- Do **not** relax i555 / allow top-level value_objects — the wrapper is the
  problem, not the rule.

## Provenance

Surfaced 2026-06-15 during bucket-3 step 2 (parse hexagon binds → IR). The
step-2 commit deliberately held back its `hecksagon_parser_shape.bluebook`
doc-edit (the `condition_kind`/`condition_fn` attribute docs) rather than extend
the skip — that doc-edit lands with this restructure, on the file that's going
to move anyway.
