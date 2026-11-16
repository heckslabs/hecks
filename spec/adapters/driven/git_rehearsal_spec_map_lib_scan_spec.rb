require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/hecks/adapters/git_rehearsal"

# A scan tagged :lib_scan reads only lib/, so a change inside spec/ leaves it out; a scan that
# reads more (a bare :repo_scan) still runs for every change.
LIB_SCAN_PATH = "spec/load_scan_spec.rb".freeze
LIB_SCAN_TEXT = %(require_relative "support/slice_helper"\nRSpec.describe "lib", :io, :repo_scan, :lib_scan do\nend\n).freeze

RSpec.describe Hecks::Adapters::GitRehearsal::SpecMap, "#map" do
  let(:root) { Dir.mktmpdir("hecks-spec-map-lib-scan") }
  let(:lib_scan) { LIB_SCAN_PATH }

  before do
    add(lib_scan, LIB_SCAN_TEXT)
    add("spec/tree_scan_spec.rb", %(RSpec.describe "tree", :io, :repo_scan do\nend\n))
    %w[spec/support/slice_helper.rb spec/other_spec.rb lib/hecks/widgets/gear_box.rb].each { |path| add(path, "# #{path}\n") }
  end

  after { FileUtils.remove_entry(root) }

  def add(path, text)
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), text)
  end

  def specs(*changed) = described_class.new(root).map(changed, limit: 60).specs

  it "leaves a lib scan out of a change to one spec file" do
    expect(specs("spec/other_spec.rb")).not_to include(lib_scan)
  end

  it "still runs a whole-tree scan for a change to one spec file" do
    expect(specs("spec/other_spec.rb")).to include("spec/tree_scan_spec.rb")
  end

  it "runs a lib scan for a change to a lib file" do
    expect(specs("lib/hecks/widgets/gear_box.rb")).to include(lib_scan)
  end

  it "reaches a lib scan by what it mentions when a spec support file changes" do
    expect(specs("spec/support/slice_helper.rb")).to include(lib_scan)
  end
end
