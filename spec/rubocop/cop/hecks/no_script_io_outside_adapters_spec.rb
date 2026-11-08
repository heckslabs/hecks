require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/no_script_io_outside_adapters"

RSpec.describe RuboCop::Cop::Hecks::NoScriptIoOutsideAdapters do
  include_context "with a Hecks cop under test"

  let(:unlisted_path) { "lib/hecks/unlisted_library_file.rb" }

  def offenses_for(source, path = unlisted_path)
    inspect_source(source, path)
  end

  it "flags OptionParser" do
    expect(offenses_for("OptionParser.new\n").size).to eq(1)
  end

  it "flags ARGV" do
    expect(offenses_for("ARGV.first\n").size).to eq(1)
  end

  it "flags exit and Kernel.exit" do
    expect(offenses_for("exit 1\nKernel.exit!\n").size).to eq(2)
  end

  it "flags $stdout reads and assignments" do
    expect(offenses_for("$stdout.puts 1\n$stdout = nil\n").size).to eq(2)
  end

  it "does not flag a file that takes values and raises" do
    expect(offenses_for("def run(name)\n  raise ArgumentError, name\nend\n")).to be_empty
  end

  it "does not flag a file the baseline lists", :aggregate_failures do
    expect(offenses_for("exit 1\n", described_class.baseline.first)).to be_empty
    expect(offenses_for("exit 1\n")).not_to be_empty
  end
end
