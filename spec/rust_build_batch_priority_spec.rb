# frozen_string_literal: true

require "spec_helper"
require "open3"
require "hecks/rust_build/gate_build"
require "hecks/hecks/adapters/bounded_capture"

# Batch work (a gate's checks, a spec file's run) starts under `taskpolicy -b`, the efficiency
# cores, only inside a heavy-job place and only when the Tickets world's `batch_priority` line
# says so; the owner's terminal, residents and coders keep normal priority.
RSpec.describe "Batch priority" do
  let(:root) { "/checkout" }
  let(:row) { { qos: "background" } }
  let(:held) { { "HECKS_HEAVY_SLOT_HELD" => "99999" } }
  let(:rubocop) { %w[bundle exec rubocop] }

  before do
    allow(Hecks::RustBuild::WorldRows).to receive(:row).with(root, "batch_priority").and_return(row)
    allow(File).to receive(:executable?).and_call_original
    allow(File).to receive(:executable?).with("/usr/sbin/taskpolicy").and_return(true)
  end

  def priority = Hecks::RustBuild::BatchPriority

  def wrap(argv, base: held, **options)
    priority.wrap(argv, root, base: base, platform: "arm64-darwin24", tool: "/usr/sbin/taskpolicy", **options)
  end

  it "starts a held job's command under taskpolicy -b" do
    expect(wrap(rubocop)).to eq(["/usr/sbin/taskpolicy", "-b", *rubocop])
  end

  it "leaves a command alone when no heavy-job place is held" do
    expect(wrap(rubocop, base: {})).to eq(rubocop)
  end

  it "leaves a command alone in CI" do
    expect(wrap(rubocop, base: held.merge("CI" => "true"))).to eq(rubocop)
  end

  context "when a thread holds a place under the real environment" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("CI").and_return(nil)
      Hecks::Adapters::Codebase::HolderMark.set(true)
    end

    after { Hecks::Adapters::Codebase::HolderMark.set(false) }

    it "demotes the thread's commands" do
      expect(wrap(rubocop, base: ENV)).to eq(["/usr/sbin/taskpolicy", "-b", *rubocop])
    end
  end

  it "leaves a command alone off macOS or without the tool", :aggregate_failures do
    expect(wrap(rubocop, platform: "x86_64-linux")).to eq(rubocop)
    expect(wrap(rubocop, tool: "/nonexistent/taskpolicy")).to eq(rubocop)
  end

  it "does not wrap a command already under taskpolicy" do
    under = ["/usr/sbin/taskpolicy", "-b", *rubocop]

    expect(wrap(under)).to eq(under)
  end

  context "when the world says normal or has no line" do
    let(:row) { { qos: "normal" } }

    it "leaves a command alone for qos normal" do
      expect(wrap(rubocop)).to eq(rubocop)
    end

    it "leaves a command alone for a missing line" do
      allow(Hecks::RustBuild::WorldRows).to receive(:row).with(root, "batch_priority").and_return({})

      expect(wrap(rubocop)).to eq(rubocop)
    end
  end

  describe "at the spawn points" do
    let(:status) { instance_double(Process::Status, success?: true) }

    before do
      allow(priority).to receive(:wrap) { |argv, *| ["taskpolicy", "-b", *argv] }
      allow(Open3).to receive(:capture2e).and_return(["", status])
    end

    it "wraps a gate check that does not compile" do
      Hecks::RustBuild::GateBuild.capture(rubocop, {}, root, base: {})

      expect(Open3).to have_received(:capture2e).with({}, "taskpolicy", "-b", *rubocop, chdir: root)
    end

    it "wraps a spec file's run" do
      allow(Open3).to receive(:popen3).and_raise(Errno::ENOENT)
      Hecks::Adapters::BoundedCapture.new(seconds: 5, setting: "x").call(%w[rspec a_spec.rb], chdir: Dir.pwd)

      expect(Open3).to have_received(:popen3).with(anything, "taskpolicy", "-b", "rspec", "a_spec.rb", any_args)
    end
  end
end
