# frozen_string_literal: true

require "tmpdir"
require_relative "../../tools/command_catcher"

RSpec.describe CommandCatcher do
  describe ".shape" do
    it "keeps leading bare words and blanks the first argument" do
      expect(described_class.shape("bundle exec rspec spec/x_spec.rb --format doc")).to eq("bundle exec rspec <arg>")
    end

    it "returns the bare command when there are no arguments" do
      expect(described_class.shape("git status")).to eq("git status")
    end

    it "uses only the first segment of a pipeline" do
      expect(described_class.shape("hecks domain build | tee out.log")).to eq("hecks domain build")
    end

    it "skips leading env assignments", :aggregate_failures do
      expect(described_class.shape("RAILS_ENV=test bin/rspec")).to be_nil
      expect(described_class.shape("FOO=1 make deploy")).to eq("make deploy")
    end

    it "returns nil when no bare word leads" do
      expect(described_class.shape("./script.sh x")).to be_nil
    end
  end

  describe ".record and .candidates" do
    def payload(command, session:, code: 0)
      { "session_id" => session, "tool_input" => { "command" => command }, "tool_response" => { "exit_code" => code } }
    end

    # The candidates proposed after recording each [command, session] pair, in a fresh log.
    def recorded_candidates(*calls)
      Dir.mktmpdir do |dir|
        log = File.join(dir, "calls.jsonl")
        calls.each { |command, session| described_class.record(payload(command, session: session), log: log) }
        described_class.candidates(described_class.load_rows(log))
      end
    end

    it "proposes a shape seen in 3 calls across 2 sessions with success", :aggregate_failures do
      found = recorded_candidates(["hecks domain build a.bluebook", "s1"], ["hecks domain build b.bluebook", "s1"],
                                  ["hecks domain build c.bluebook", "s2"])
      expect(found.map { |c| c[:shape] }).to eq(["hecks domain build <arg>"])
      expect(found.first).to include(count: 3, sessions: 2, success: 1.0)
    end

    it "drops shapes that mostly fail" do
      Dir.mktmpdir do |dir|
        log = File.join(dir, "calls.jsonl")
        3.times { |i| described_class.record(payload("make x", session: "s#{i}", code: 1), log: log) }
        expect(described_class.candidates(described_class.load_rows(log))).to be_empty
      end
    end

    it "drops noise commands" do
      Dir.mktmpdir do |dir|
        log = File.join(dir, "calls.jsonl")
        3.times { |i| described_class.record(payload("ls foo", session: "s#{i}"), log: log) }
        expect(described_class.candidates(described_class.load_rows(log))).to be_empty
      end
    end

    it "never raises on a malformed payload" do
      expect { described_class.record({ "tool_input" => nil }, log: "/nonexistent/\0") }.not_to raise_error
    end
  end

  describe ".proposal" do
    def transfer_proposal
      candidate = { shape: "bundle exec rspec <arg>", count: 3, sessions: 2, success: 1.0 }
      described_class.proposal(candidate, aggregate: "Transfer")
    end

    it "renders a command block without the example text", :aggregate_failures do
      expect(transfer_proposal).to include('command "BundleExecRspec" do')
      expect(transfer_proposal).to include('goal "Run `bundle exec rspec <arg>`"')
      expect(transfer_proposal).to include('aggregate "Transfer"')
    end
  end
end
