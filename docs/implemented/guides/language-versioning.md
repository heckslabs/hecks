# Language versioning

The bluebook surface is itself declared, in `syntax.bluebook` — which
means the surface can carry its own lifecycle the same way any other
word in this language does: `proposed`, `admitted`, `deprecated`,
`retired`.

A `proposed` or `retired` word reaches no projected parser table. To a
projected reader — the generated Rust parser, the DSL reference, the
keyword table any tool builds from `Syntax` — that word does not exist
yet, or does not exist any more. There is no separate "is this word
still supported" question to answer by hand; the language's own
declaration already answers it.

A renamed word keeps its old spelling in `was:`, so a bluebook written
under an earlier spelling keeps parsing rather than breaking the day a
word is renamed for clarity:

```ruby skip
word "sets", was: "assigns"
```

`bin/evolve` walks a language change through the stations a rename or
a new word actually needs: snapshot the current state, rewrite the
corpus to the new spelling, regenerate every projected table (parser,
reference, vocabulary), gate on the full suite, and restore the
snapshot on red rather than leaving the tree half-migrated.

This is the same discipline `PostgresEra` applies to a *domain's* own
vocabulary (see [Schema evolution](schema-evolution.md)), turned on the
language that hosts every domain: a word can change without every
bluebook that already used the old spelling breaking, and the record
of what changed and why lives in the language's own declaration, not
in a changelog someone has to remember to update.
