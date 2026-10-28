require "spec_helper"
require "hecks/cli/stores"

# `stores` reads one record without dumping the rest: the document narrows to an aggregate's dump,
# or to that aggregate's one record as its plain fields.
RSpec.describe Hecks::CLI::Stores, ".narrow" do
  let(:document) do
    { "book"  => { "authoritative" => [{ "id" => "dune", "title" => "Dune" }, { "id" => "emma", "title" => "Emma" }] },
      "shelf" => { "authoritative" => [] } }
  end

  it "keeps the whole document when nothing is named" do
    expect(described_class.narrow(document, nil, nil)).to eq(document)
  end

  it "keeps one aggregate's dump under its storage name" do
    expect(described_class.narrow(document, "shelf", nil)).to eq("shelf" => { "authoritative" => [] })
  end

  it "answers one record as its plain fields" do
    expect(described_class.narrow(document, "book", "emma")).to eq("id" => "emma", "title" => "Emma")
  end

  it "refuses an aggregate that is not stored, naming the ones that are" do
    expect { described_class.narrow(document, "bok", nil) }
      .to raise_error(Hecks::Runtime::NotFound, /no aggregate stored as "bok"; stored: book, shelf/)
  end

  it "refuses a record that is not in the aggregate" do
    expect { described_class.narrow(document, "book", "nope") }
      .to raise_error(Hecks::Runtime::NotFound, /no book record with id "nope"/)
  end

  it "refuses a record named without its aggregate" do
    expect { described_class.narrow(document, nil, "dune") }
      .to raise_error(Hecks::Runtime::NotFound, /name the aggregate/)
  end
end
