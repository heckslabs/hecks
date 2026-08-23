require "spec_helper"

# `bin/project_parser_table` has no `.rb` extension (matching every other
# executable under bin/), so `require`/`require_relative` refuse to load
# it — `Kernel.load` is the one Ruby primitive that loads a plain path
# regardless of extension, and it's what the script's own
# `$PROGRAM_NAME == __FILE__` guard exists for: loaded (not run) here, its
# file-writing side effect never fires, only `Projections::ParserTable` gets
# defined.
Kernel.load(File.expand_path("../bin/project_parser_table", __dir__))

# GRAMMAR DRIFT FAILS THE NORMAL SUITE IMMEDIATELY, not "someone eventually
# notices". rust/parser/src/keywords.rs is GENERATED from the aggregate-local syntax tables
# by bin/project_parser_table (see that file's own header) — this spec
# regenerates it into memory and asserts byte equality with the committed
# file. A syntax-table change that lands without re-running
# `bin/project_parser_table` fails HERE, in the loop every push already
# runs, rather than silently leaving the Rust parser's own word/argument
# knowledge stale.
RSpec.describe "the generated parser table" do
  let(:committed_path) { File.expand_path("../rust/parser/src/keywords.rs", __dir__) }

  it "is exactly what bin/project_parser_table would regenerate from the aggregate-local syntax tables right now" do
    expect(File).to exist(committed_path), "rust/parser/src/keywords.rs is missing — run bin/project_parser_table"

    committed = File.read(committed_path)
    regenerated = Hecksagain::Projector.call(
      :parser_table,
      bluebook: Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
    )

    expect(committed).to eq(regenerated),
                         "rust/parser/src/keywords.rs is stale — run bin/project_parser_table and commit the result"
  end

  it "declares at least one row (a real, non-empty grammar table)" do
    # S14, ADR 0026 — Keyword/Argument are genuine entities of Syntax
    # now, dispatched through a real lifecycle — `render` (what
    # `bin/project_parser_table` actually calls) reads them through
    # `SyntaxBoot.call`, not `rows` directly any more (that still reads
    # the still-static seed rows, `KeywordSeed`/`ArgumentSeed`, straight
    # off the closed set).
    table = Hecksagain::Bluebook::MetaValidator::SyntaxBoot.call

    expect(table[:keywords]).not_to be_empty
    expect(table[:arguments]).not_to be_empty
  end

  # `declares: "Syntax"` is stated at registration, so the REGISTRY
  # refuses before the projection runs. It used to be a `raise` inside
  # the projection's own body — a requirement written as behaviour
  # instead of declared.
  it "refuses a chapter with no Syntax aggregate" do
    expect { Hecksagain::Projector.call(:parser_table, bluebook: boot_in_memory.registry.bluebook("Pizzas")) }
      .to raise_error(Hecksagain::Projector::WrongConstruct, /needs a chapter declaring Syntax/)
  end
end
