require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/no_script_io_outside_adapters"

# The baseline only shrinks: no line for a file that is gone, one that now passes, or an adapter.
RSpec.describe "the NoScriptIoOutsideAdapters baseline" do
  include_context "with a Hecks cop under test"

  let(:described_class) { RuboCop::Cop::Hecks::NoScriptIoOutsideAdapters }
  let(:ruby_version) { 3.3 }
  let(:root) { File.expand_path("../../../..", __dir__) }
  let(:listed) { described_class.baseline }

  def offends_unlisted?(entry)
    path = File.join(root, entry)
    allow(described_class).to receive(:baseline).and_return([])
    inspect_source(File.read(path), path).any?
  end

  it "lists only files that exist" do
    expect(listed.reject { |entry| File.file?(File.join(root, entry)) }).to be_empty
  end

  it "lists only files that still offend" do
    expect(listed.reject { |entry| offends_unlisted?(entry) }).to be_empty
  end

  it "lists no file twice" do
    expect(listed).to eq(listed.uniq)
  end

  it "lists no adapter file" do
    expect(listed.grep(%r{(\A|/)adapters/})).to be_empty
  end
end
