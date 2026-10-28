require "spec_helper"

RSpec.describe Hecks::Projections::Site::RootRows do
  let(:rows) do
    described_class.new("Editor", fields: { domain: String, bluebook: String }, required: %i[domain bluebook],
                                  renamed: { chapter: :bluebook })
  end
  let(:table) { Hecks::Projections::Site::Table }

  def read(*members)
    allow(table).to receive(:rows_of).and_return(members)
    rows.read(:a_bluebook)
  end

  it "reads a row that spells a retired field as the field that replaced it, saying so", :aggregate_failures do
    found = nil

    expect { found = read({ domain: "d", chapter: "Press" }) }
      .to output(/Editor row field chapter is deprecated, use bluebook/).to_stderr
    expect(found).to eq([{ domain: "d", bluebook: "Press" }])
  end

  it "says nothing for a row that spells the new field", :aggregate_failures do
    expect { expect(read({ domain: "d", bluebook: "Press" })).to eq([{ domain: "d", bluebook: "Press" }]) }
      .not_to output.to_stderr
  end

  it "refuses a row that carries both, naming the retired one as unknown", :aggregate_failures do
    expect { read({ domain: "d", bluebook: "Press", chapter: "Other" }) }
      .to raise_error(Hecks::Projections::Site::Table::Invalid, /no field chapter/)
  end
end
