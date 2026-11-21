require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/impediment_looks"

# The impediment view reads the machine's load itself, and a load it cannot read is a row.
RSpec.describe "StallWatch impediments: the load reading" do
  include_context "with a stall watch tap"
  include ImpedimentLooks

  let(:reader) { -> {} }
  let(:aggregate) { registry.bluebook("Hecks").aggregate("StallWatch") }

  def watching
    Hecks::Adapters::StallWatching.new(registry: registry, aggregate: aggregate, tap: tap, branches: branch_read,
                                       load: reader, leftovers: ->(_name) { 0 })
  end

  def load_rows = impediments.select { |row| row[:subject] == "load" }

  before { write_sources([]) }

  it "answers a named row for each held-starts signal when the load gives no figure", :aggregate_failures do
    expect(load_rows.map { |row| row[:detail] }).to all(include("impediment view cannot read load"))
    expect(load_rows.size).to eq(2)
  end

  context "when the reader raises" do
    let(:reader) { -> { raise Errno::ENOENT } }

    it "answers the named row, not an exception" do
      expect(load_rows).not_to be_empty
    end
  end

  context "when the reader answers a figure" do
    let(:reader) { -> { 1.5 } }

    it "raises no load row" do
      expect(load_rows).to be_empty
    end
  end

  describe Hecks::Adapters::StallWatching::MachineLoad do
    let(:shell)  { instance_double(Hecks::Adapters::Shell) }
    let(:result) { Hecks::Adapters::Shell::Result.new("{ 1.23 2.5 3.0 }\n", "", instance_double(Process::Status, success?: true)) }

    it "reads the 1-minute figure from sysctl" do
      allow(shell).to receive(:capture).with("sysctl", "-n", "vm.loadavg").and_return(result)
      expect(described_class.new(shell: shell).call).to eq(1.23)
    end

    it "answers nil when sysctl and the file both fail" do
      allow(shell).to receive(:capture).and_raise(Errno::ENOENT)
      expect(described_class.new(shell: shell, proc_path: "/nonexistent").call).to be_nil
    end

    it "answers a figure on this Ruby with no stand-in" do
      expect(described_class.new.call).to be_a(Float).or be_nil
    end
  end
end
