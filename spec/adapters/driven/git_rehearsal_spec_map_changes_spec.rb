require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_rehearsal"

# The specs a change to a world setting, a bluebook row or a routing list reaches by the names the
# diff changed, over a temporary git repository holding the six train-PR cases of 2026-11-11.
RSpec.describe Hecks::Adapters::GitRehearsal::SpecMap::Changes do
  let(:root) { Dir.mktmpdir("hecks-spec-map-changes") }
  let(:map) { Hecks::Adapters::GitRehearsal::SpecMap.new(root) }

  def git(*args) = Open3.capture2e("git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@t", *args)

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), text)
  end

  def commit(message) = git("add", "-A") && git("commit", "-q", "-m", message)

  def start(files)
    git("init", "-q", "-b", "main")
    files.each { |path, text| write(path, text) }
    commit("base")
  end

  def reached(path, because: false)
    mapping = map.map([path], limit: 60, since: "HEAD")
    because ? mapping.because : mapping.specs
  end

  after { FileUtils.remove_entry(root) }

  context "when a world setting changes value (cases 1325 and 1326)" do
    let(:world) { "lib/hecks/hecks/tickets.world" }

    before do
      start(world => world_text(8.0), "spec/hecks_machine_crossings_spec.rb" => "world.dispatch_max_load\n",
            "spec/unrelated_spec.rb" => "# nothing\n")
      write(world, world_text(10.0))
    end

    def world_text(max) = %(dispatch_max_load "Dispatch", max: #{max}\nspec_bounds "Specs", file_seconds: 600\n)

    it "selects every spec that reads the setting" do
      expect(reached(world)).to include("spec/hecks_machine_crossings_spec.rb")
    end

    it "leaves out a spec that reads another setting", :aggregate_failures do
      expect(reached(world)).not_to include("spec/unrelated_spec.rb")
      expect(reached(world, because: true)["spec/hecks_machine_crossings_spec.rb"]).to include("dispatch_max_load")
    end
  end

  context "when a stall move changes (case 1328)" do
    let(:path) { "lib/hecks/hecks/stall_watch/stall_watch.bluebook" }
    let(:text) do
      ["aggregate \"StallWatch\" do", "  value_object \"StallKind\" do", "    attribute :move, String",
       "    member kind: \"a\", move: \"%s\"", "  end", "end", ""].join("\n")
    end

    before do
      start(path => format(text, "Finding.file!"), "spec/agents_routing_guard_spec.rb" => "StallKind\n",
            "spec/unrelated_spec.rb" => "# nothing\n")
      write(path, format(text, "Finding.report!"))
    end

    it "selects the routing guard spec that reads the kinds" do
      expect(reached(path)).to include("spec/agents_routing_guard_spec.rb")
    end

    it "names the declaration it changed", :aggregate_failures do
      expect(reached(path, because: true)["spec/agents_routing_guard_spec.rb"]).to match(/StallKind.*#{Regexp.escape(path)}/)
      expect(reached(path)).not_to include("spec/unrelated_spec.rb")
    end
  end

  context "when nothing changed in the file" do
    it "reads no names" do
      start("lib/a.world" => "dispatch_max_load \"x\", max: 8.0\n")
      expect(described_class.new(root, "HEAD").names(["lib/a.world"])).to eq({})
    end
  end
end
