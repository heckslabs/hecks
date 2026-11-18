require "spec_helper"

# A list of value objects is given as repeated columns, `stuck.kind=` and `stuck.what=`, and the
# launcher zips the columns by position into one element per row.
RSpec.describe Hecks::Adapters::Driving::Cli, ".arguments rows" do
  let(:spec) do
    { arguments: [{ path: "stuck.kind", type: "String", required: true, list: true },
                  { path: "stuck.what", type: "String", required: true, list: true },
                  { path: "stuck.link", type: "String", required: false, list: true }] }
  end

  def args(*words) = described_class.arguments(spec, words)

  it "builds one row from one of each column" do
    expect(args("stuck.kind=a", "stuck.what=b")[:stuck]).to eq([{ kind: "a", what: "b" }])
  end

  it "builds two rows by position" do
    words = %w[stuck.kind=a stuck.what=b stuck.kind=c stuck.what=d stuck.link=x stuck.link=y]
    expect(args(*words)[:stuck]).to eq([{ kind: "a", what: "b", link: "x" }, { kind: "c", what: "d", link: "y" }])
  end

  it "refuses columns of different lengths, naming every column" do
    expect { args("stuck.kind=a", "stuck.kind=c", "stuck.what=b") }
      .to raise_error(Hecks::Runtime::TypeMismatch, /stuck columns differ in length: kind 2, what 1, link 0/)
  end

  it "leaves an omitted optional column out" do
    expect(args("stuck.kind=a", "stuck.what=b")[:stuck].first).not_to have_key(:link)
  end
end
