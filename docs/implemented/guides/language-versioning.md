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

A renamed word keeps its old spelling in `was:` — read straight off
the language's own live grammar table, the same one every builder's
word-admission check reads:

```ruby
table = Hecks::Bluebook::MetaValidator::SyntaxBoot.call
read_model_row = table[:keywords].find { |row| row[:context] == "Bluebook" && row[:word] == "read_model" }
read_model_row[:was] # => "report"
```

That `was:` is what lets era text minted back when `report` was still
the word keep parsing today, under the same shadow-parsing bridge
`MetaValidator.shadow_parsing?` gates for every renamed word
(`EraGuard.shadow_parse` runs it at boot, at mint, and during tamper
detection): live source refuses the old spelling outright, and frozen
era text still gets it.

```ruby bluebook
Hecks.bluebook "LanguageVersioningDemo" do
  vision "One aggregate and one read model, to watch a renamed word's two fates."

  aggregate "Ticket" do
    attribute :code, Code
    identified_by :code
    value_object("Code") { attribute :value, String }

    command "Open" do
      sets :code
      emits "TicketOpened"
    end
  end

  Hecks::Bluebook::MetaValidator.while_shadow_parsing do
    report "TicketList" do
      reference_to Ticket
      include Ticket
    end
  end
end
```

Live source gets no such bridge — the same `report` call, outside
`while_shadow_parsing`, names its own replacement instead of running:

```ruby
Hecks.bluebook("LanguageVersioningLiveAttempt") { report("Nope") { } } # ~> Malformed: report is gone
```

Not every renamed word takes this two-tier shape — `then_set`, `sets`'s
own predecessor, instead keeps a dedicated `status: "deprecated"` row
of its own rather than living only as `sets`'s `was:` (see
`CommandBuilder#then_set_impl`'s own comment for why); either shape
answers "does this still parse" from the language's own declaration,
never from a maintained changelog.

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
