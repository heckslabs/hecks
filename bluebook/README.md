# bluebook/

*Bluebook* — here lives **the language itself**. Not Ruby's reading of it, not Rust's ; *la langue* before any runtime puts a tongue to it. Both implementations bow to what lives here. The language is **like sheet music** — Ruby and Rust are two orchestras that must play the same piece, and this directory holds the score.

What's here in i118 Round 2 :

- **`bluebook.bluebook`** — the IR canonical shape, expressed *in bluebook itself*. Defines the Domain aggregate (the root of the IR tree, holding aggregates and policies), Aggregate, Command, Policy, Query, Lifecycle — every shape that a `Hecks.bluebook "Foo" do ... end` source compiles into. Self-describing : the file is a Bluebook source whose IR describes Bluebook IR. The Futamura fixed point.

Still to come :

- **`grammar/`** — the formal DSL surface (what tokens / forms exist, recursively in bluebook)
- **`fixtures/`** — conformance test cases that lock the language. Both parsers must produce the same IR from each fixture. (Today the parity suite at `parity/` does this implicitly ; the conformance fixtures will be promoted out as canonical reference.)

Reading order, when populated : `bluebook.bluebook` first (the IR), then `grammar/*.bluebook` (the surface), then `fixtures/*.bluebook` (worked examples). Each of the 13 chapters in `self/` is a *user* of this language ; the language itself is here.
