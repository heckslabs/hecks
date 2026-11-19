# frozen_string_literal: true

require "spec_helper"
require "json"
require "hecks/hecks/adapters/claude_agents"

# A dispatched session the Tickets world scrubs starts with its GitHub, AWS, 1Password, SSH and
# git credentials blanked or redirected, and with deny rules on the files and commands that print
# one; a session the world does not scrub starts exactly as before.
RSpec.describe Hecks::Adapters::CredentialScrub do
  let(:block) { described_class.onto({ "env" => { "HECKS_CALLER" => "coder:r1" } }, home: "/h") }

  it "keeps the session's own variables" do
    expect(block["env"]["HECKS_CALLER"]).to eq("coder:r1")
  end

  it "blanks every token variable" do
    expect(block["env"].values_at(*described_class::BLANK)).to all(eq(""))
  end

  it "points gh, AWS and git away from their logins", :aggregate_failures do
    expect(block["env"]).to include("GH_CONFIG_DIR" => "/h/#{described_class::GH_CONFIG}",
                                    "AWS_SHARED_CREDENTIALS_FILE" => File::NULL, "GIT_CONFIG_VALUE_0" => "")
    expect(block["env"]).to include("GIT_CONFIG_KEY_0" => "credential.helper", "GIT_CONFIG_COUNT" => "1")
  end

  it "denies the credential files and the commands that print a secret" do
    expect(block["permissions"]["deny"]).to include("Read(~/.aws/**)", "Bash(security:*)", "Bash(gh auth token:*)")
  end

  describe Hecks::Adapters::Dispatching::CredentialSetting do
    def setting(declared)
      world = Struct.new(:declared) { def for_verb(verb) = verb == "session_credentials" ? declared : nil }.new(declared)
      described_class.new(Struct.new(:tickets) { def world(name) = name == "Tickets" ? tickets : nil }.new(world))
    end

    it "scrubs none when the verb is undeclared" do
      expect(setting(nil).scrub?("coder")).to be(false)
    end

    it "scrubs none when the world turns it off" do
      expect(setting({ scrub: false, keep: [] }).scrub?("coder")).to be(false)
    end

    it "scrubs a role the world does not keep" do
      expect(setting({ scrub: true, keep: %w[orchestrator] }).scrub?("coder")).to be(true)
    end

    it "keeps a role the world keeps" do
      expect(setting({ scrub: true, keep: %w[orchestrator] }).scrub?("orchestrator")).to be(false)
    end

    it "names a run with no agent the default" do
      expect(setting({ scrub: true, keep: %w[default] }).scrub?(nil)).to be(false)
    end
  end

  describe Hecks::Adapters::SessionLine do
    let(:held) { { run: "r1", agent: "coder", brief: "build it" } }
    let(:scrub) { Struct.new(:on) { def scrub?(_agent) = on } }

    def settings_of(line)
      words = line.arguments(held, { "HECKS_CALLER" => "coder:r1" })
      JSON.parse(words[words.index("--settings") + 1])
    end

    it "carries the deny rules for a scrubbed role" do
      line = described_class.new(command: "claude", nice: [], credentials: scrub.new(true))
      expect(settings_of(line).dig("permissions", "deny")).to eq(Hecks::Adapters::CredentialScrub::DENY)
    end

    it "carries only the caller for a kept role" do
      line = described_class.new(command: "claude", nice: [], credentials: scrub.new(false))
      expect(settings_of(line)).to eq("env" => { "HECKS_CALLER" => "coder:r1" })
    end

    it "keeps every session's credentials when nothing is said" do
      expect(settings_of(described_class.new(command: "claude", nice: []))).to eq("env" => { "HECKS_CALLER" => "coder:r1" })
    end
  end
end
