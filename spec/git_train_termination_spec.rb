# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "hecks/hecks/adapters/git_train"

# A boarding told to stop leaves a fault record and a named refusal.
RSpec.describe Hecks::Adapters::GitTrain::Termination, :io do
  let(:dir) { Dir.mktmpdir("hecks-termination") }
  let(:fault) { described_class.new(dir, "main") }
  let(:path) { File.join(dir, described_class::FILE) }

  def terminated
    fault.at("settling")
    fault.watch do
      Process.kill("TERM", Process.pid)
      loop { Thread.pass }
    end
  end

  after { FileUtils.remove_entry(dir) }

  it "refuses by name when a SIGTERM arrives" do
    expect { terminated }.to raise_error(described_class::Stopped, /terminated by SIGTERM while settling/)
  end

  it "leaves a fault record naming the signal and the step", :aggregate_failures do
    expect { terminated }.to raise_error(described_class::Stopped)
    record = JSON.parse(File.read(path))
    expect(record).to include("branch" => "main", "signal" => "TERM", "step" => "settling")
  end

  it "removes a record left by an earlier boarding once one carries a commit" do
    File.write(path, "{}")
    fault.watch { :carried }

    expect(File.exist?(path)).to be(false)
  end

  it "restores the signal handler it replaced" do
    before = Signal.trap("TERM", "DEFAULT")
    fault.watch { :ok }

    expect(Signal.trap("TERM", before)).to eq("DEFAULT")
  end
end
