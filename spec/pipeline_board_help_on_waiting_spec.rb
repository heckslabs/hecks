# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require "hecks/pipeline_board/adapters/pipeline_stages"
require_relative "support/help_wanted_looks"

# A board three hours after the looks' call for help opened, whose readers cannot answer but for
# the Tickets reader given and a jobs reader holding no session.
module HelpWaitingBoard
  SILENT = %i[github git journal fill disk boots trains integration].freeze

  def waiting
    readers = SILENT.to_h { |name| [name, Object.new] }.merge(tickets: tickets, jobs: Struct.new(:rows).new([]))
    Hecks::Adapters::PipelineStages.new(root: dir, settings: { readers: readers, now: -> { Time.utc(2026, 11, 20, 13) } })
                                   .state[:waiting_on_you]
  end
end

# A call for help reaches the owner by the board's Waiting-on-you reading and by nothing else: the
# board reads the open calls, the line leaves when the call closes, and raising one sends nothing.
RSpec.describe "HelpWanted on the Waiting-on-you reading" do
  include_context "with a stall watch tap"
  include HelpWantedLooks
  include HelpWaitingBoard

  let(:tickets) { Hecks::Adapters::PipelineTickets.new(registry: registry, settings: { work_items: [] }) }

  before { write_sources(ImpedimentLooks::STANDING) }

  it "sends nothing when the owner's call is raised: the one event is the call itself" do
    before = registry.event_log.size
    raise_help(HelpWantedLooks::HOLD, "owner")
    expect(registry.event_log.drop(before).map(&:name)).to eq(["HelpWantedRaised"])
  end

  it "puts the owner's call on the reading as one line, beside the sessions' count", :aggregate_failures do
    raise_help(HelpWantedLooks::HOLD, "owner")
    expect(waiting[:help].map { |row| row[:line] }).to eq(["needs you: Release the hold once its holder is confirmed dead., 3h"])
    expect(waiting).to include(count: 0, ids: [])
  end

  it "drops the line when the call closes" do
    raise_help(HelpWantedLooks::HOLD, "owner")
    release
    look("look-1")
    expect(tickets.open_help).to eq([])
  end
end
