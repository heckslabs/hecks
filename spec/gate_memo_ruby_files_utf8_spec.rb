require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/tools/gate_memo/ruby_files"

# The pre-push hook runs with no locale, so the process reads files as US-ASCII; the gate's memo
# reads Ruby files as UTF-8 all the same, and a non-ASCII byte neither crashes it nor hides a require.
RSpec.describe "The gate memo reading a Ruby file with a non-ASCII comment under a US-ASCII locale" do
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
  end

  after { FileUtils.rm_rf(root) }

  def write(rel, text)
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, text)
  end

  before do
    write("lib/a.rb", "# café — naive\nrequire_relative \"b\"\n")
    write("lib/b.rb", "B = 1\n")
  end

  it "returns the files the file requires" do
    expect(ruby.requires(root, "lib/a.rb")).to eq(["lib/b.rb"])
  end

  it "reads a file holding an invalid byte without raising" do
    write("lib/c.rb", "# \xFF\nrequire_relative \"b\"\n")
    expect(ruby.requires(root, "lib/c.rb")).to eq(["lib/b.rb"])
  end

  it "plans an incremental run, not a full one, when such a file changes" do
    entry = { "inputs" => ruby.config(root), "files" => ruby.hashes(root) }
    write("lib/b.rb", "B = 2\n")
    expect(ruby.plan(root, entry, ruby.hashes(root)).first).to eq(:incremental)
  end
end
