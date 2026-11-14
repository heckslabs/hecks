require "spec_helper"
require "hecks/hecks/adapters/session_lookup"
require "hecks/hecks/adapters/run_gone"
require "hecks/hecks/adapters/run_activity"
require "hecks/hecks/adapters/claude_session_listing"
require "hecks/hecks/adapters/dispatching"
require "hecks/runtime/reaction_notice"

# Whether the listing shows a session stopped or not at all, which the settle asks before it
# asks a run to retire.
RSpec.describe Hecks::Adapters::ClaudeSessionListing do
  let(:shell) { instance_double(Hecks::Adapters::Shell) }
  let(:listing) { described_class.new("claude", shell: shell) }

  def lists(*entries)
    out = JSON.generate(entries.map { |id, state| { "id" => id, "state" => state } })
    allow(shell).to receive(:capture).and_return(Struct.new(:out, :err, :ok?).new(out, "", true))
  end

  it "calls a stopped session quiet and a working or missing one as the world reads them", :aggregate_failures do
    lists(%w[a stopped], %w[b working], %w[c blocked])

    expect([listing.quiet?("a"), listing.quiet?("b"), listing.quiet?("c"), listing.quiet?("z")]).to eq([true, false, false, true])
  end
end
