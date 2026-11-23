require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/tools/gate_memo/ruby_files"

# The pre-push hook runs with no locale, so Ruby's default external encoding is US-ASCII; the
# gate memo still reads a Ruby file holding a non-ASCII byte as UTF-8 and finds its requires.
RSpec.describe "The gate memo reading Ruby files under a US-ASCII locale" do
  let(:root) { Dir.mktmpdir("gate-memo-utf8") }
  let(:ruby) { Hecks::Tools::GateMemo::RubyFiles }

  around do |example|
    was = Encoding.default_external
    verbose = $VERBOSE
    $VERBOSE = nil
    Encoding.default_external = Encoding::US_ASCII
    example.run
  ensure
    Encoding.default_external = was
    $VERBOSE = verbose
    FileUtils.rm_rf(root)
  end

  def write(rel, text)
    FileUtils.mkdir_p(File.dirname(File.join(root, rel)))
    File.binwrite(File.join(root, rel), text)
  end

  before do
    write("lib/a.rb", "# café — naïve\nrequire_relative \"b\"\n")
    write("lib/b.rb", "B = 1\n")
  end

  it "returns the requires of a file holding a non-ASCII comment" do
    expect(ruby.requires(root, "lib/a.rb")).to eq(["lib/b.rb"])
  end

  it "returns the requires of a file holding an invalid byte" do
    write("lib/a.rb", "# \xff\nrequire_relative \"b\"\n")
    expect(ruby.requires(root, "lib/a.rb")).to eq(["lib/b.rb"])
  end

  it "plans an incremental lint when a file requiring a changed one holds non-ASCII text" do
    was = ruby.hashes(root)
    write("lib/b.rb", "B = 2\n")
    entry = { "inputs" => ruby.config(root), "files" => was }
    expect(ruby.plan(root, entry, ruby.hashes(root)).first).to eq(:incremental)
  end
end
