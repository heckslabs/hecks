require "spec_helper"

# Fails when rust/parser/src/keywords.rs drifts from the syntax tables: regenerates the file
# in memory and compares it with the committed one.
RSpec.describe "the generated parser table" do
  let(:committed_path) { File.expand_path("../rust/parser/src/keywords.rs", __dir__) }

  def regenerated_table
    Hecks::Projector.call(:parser_table, bluebook: Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook"))
  end

  it "is exactly what `hecks project_parser_table` would regenerate " \
     "from the aggregate-local syntax tables right now", :aggregate_failures do
    expect(File).to exist(committed_path), "rust/parser/src/keywords.rs is missing — run hecks project_parser_table"
    expect(File.read(committed_path))
      .to eq(regenerated_table), "rust/parser/src/keywords.rs is stale — run hecks project_parser_table and commit the result"
  end

  it "declares at least one row (a real, non-empty grammar table)", :aggregate_failures do
    # `render` reads through `SyntaxBoot.call`, not the static seed rows.
    table = Hecks::Bluebook::MetaValidator::SyntaxBoot.call

    expect(table[:keywords]).not_to be_empty
    expect(table[:arguments]).not_to be_empty
  end

  # `declares: "Syntax"` is stated at registration, so the registry refuses before the
  # projection runs.
  it "refuses a chapter with no Syntax aggregate" do
    expect { Hecks::Projector.call(:parser_table, bluebook: boot_in_memory.registry.bluebook("Pizzas")) }
      .to raise_error(Hecks::Projector::WrongConstruct, /needs a chapter declaring Syntax/)
  end
end
