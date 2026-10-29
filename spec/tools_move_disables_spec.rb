require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/tools/move_disables"

# The move runs against throwaway checkouts: a config, and the files a case names. Nothing under
# the real repository is touched.
RSpec.describe Hecks::Tools::MoveDisables do
  CONFIG_TEXT = "Layout/LineLength:\n  Max: 130\n".freeze
  REGISTRY_SOURCE = "x = 1 # rubocop:disable Style/MutableConstant -- registry\n" \
                    "# rubocop:disable Metrics/AbcSize\n" \
                    "def y; end\n" \
                    "# rubocop:enable Metrics/AbcSize\n".freeze

  before { @roots = [] }
  after { @roots.each { |root| FileUtils.remove_entry(root) } }

  # Builds a checkout holding `files`, runs the move over it, and returns its root.
  def checkout(files, apply: true)
    root = Dir.mktmpdir
    @roots << root
    File.write(File.join(root, ".rubocop.yml"), CONFIG_TEXT)
    files.each { |path, text| write_file(root, path, text) }
    described_class.transform(root: root, apply: apply)
    root
  end

  def write_file(root, path, text)
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), text)
  end

  def read(root, path) = File.read(File.join(root, path))

  it "strips directives and keeps the code" do
    root = checkout({ "lib/a.rb" => REGISTRY_SOURCE })
    expect(read(root, "lib/a.rb")).to eq("x = 1\ndef y; end\n")
  end

  it "adds each moved cop with its reason and file" do
    root = checkout({ "lib/a.rb" => REGISTRY_SOURCE })
    expect(read(root, ".rubocop.yml")).to include("Style/MutableConstant:\n  Exclude:\n    - \"lib/a.rb\"")
  end

  it "fills an existing block and keeps its other keys" do
    root = checkout({ "spec/b.rb" => "# rubocop:disable-next Layout/LineLength\nLONG = 1\n" })
    expect(read(root, ".rubocop.yml")).to include("  Max: 130")
  end

  it "leaves SKIP files untouched" do
    text = "# rubocop:disable Hecks/ThreadSharedIvarMutation\n@x = 1\n"
    root = checkout({ "lib/hecks/runtime/registry.rb" => text })
    expect(read(root, "lib/hecks/runtime/registry.rb")).to eq(text)
  end

  it "plans without writing when apply is false" do
    root = checkout({ "lib/a.rb" => REGISTRY_SOURCE }, apply: false)
    expect(read(root, "lib/a.rb")).to eq(REGISTRY_SOURCE)
  end

  it "refuses a cop that has no reason written" do
    expect { checkout({ "lib/a.rb" => "x = 1 # rubocop:disable Some/UnreasonedCop -- why\n" }) }
      .to raise_error(Hecks::Tools::MoveDisables::MissingReason, %r{Some/UnreasonedCop})
  end
end
