require "spec_helper"
require "hecks/hecks/adapters/session_lookup"
require "hecks/hecks/adapters/claude_session_listing"
require "hecks/hecks/adapters/shell"

# Whether a run's session is gone, which retires the run. A session started seconds ago is not in
# the listing yet and has written no job state, and a session that stays listed must not cost a
# listing on every beat.
RSpec.describe "finding out whether a session is gone" do
  let(:now) { Time.utc(2026, 11, 9, 12, 0, 0) }
  let(:clock) { { at: now } }

  describe Hecks::Adapters::SessionLookup do
    let(:listing) { instance_double(Hecks::Adapters::ClaudeSessionListing, find: nil) }
    let(:lookup) { described_class.new(listing, grace: -> { 120 }, now: -> { clock[:at] }) }

    def held(started_ago, run: "r")
      { run: { value: run }, session: { value: "abc123" }, started_at: { value: (now - started_ago).iso8601 } }
    end

    def listed(state = "working") = allow(listing).to(receive(:find).and_return({ "state" => state }))

    it "keeps a run started 10 seconds ago whose session is not listed yet", :aggregate_failures do
      answer = lookup.call(held(10))

      expect(answer[:listed]).to be(true)
      expect(answer[:note]).to include("not listed yet; it started 10s ago")
    end

    it "takes a run started 300 seconds ago whose session is not listed for gone" do
      expect(lookup.call(held(300))[:listed]).to be(false)
    end

    it "takes a run with no start time for gone, as every run was before the time was recorded" do
      expect(lookup.call(held(300).merge(started_at: nil))[:listed]).to be(false)
    end

    it "answers a listed session as listed whatever its age", :aggregate_failures do
      listed
      answer = lookup.call(held(900))

      expect(answer[:listed]).to be(true)
      expect(answer[:state]).to eq("working")
    end

    it "does not look a listed session up again within the throttle" do
      listed
      lookup.call(held(900))
      clock[:at] = now + 60
      lookup.call(held(900))

      expect(listing).to have_received(:find).once
    end

    it "looks a listed session up again once the throttle has passed" do
      listed
      lookup.call(held(900))
      clock[:at] = now + described_class::THROTTLE + 1
      lookup.call(held(900))

      expect(listing).to have_received(:find).twice
    end
  end

  # One `claude agents` listing is shared by the runs of a sweep.
  describe Hecks::Adapters::ClaudeSessionListing do
    let(:shell) { instance_double(Hecks::Adapters::Shell, capture: answered) }
    let(:listing) { described_class.new("claude", shell: shell, now: -> { clock[:at] }) }

    def answered
      Hecks::Adapters::Shell::Result.new([{ "id" => "aaa111", "state" => "working" }].to_json, "",
                                         Struct.new(:success?, :exitstatus).new(true, 0))
    end

    it "lists once for several runs whose sessions it shows", :aggregate_failures do
      2.times { expect(listing.find("aaa111")["state"]).to eq("working") }

      expect(shell).to have_received(:capture).once
    end

    it "looks again for a session the kept listing lacks, once the kept listing is no longer fresh" do
      listing.find("aaa111")
      clock[:at] = now + described_class::FRESH + 1
      listing.find("gone99")

      expect(shell).to have_received(:capture).twice
    end

    it "believes a listing read a moment ago about a session it lacks" do
      listing.find("aaa111")
      listing.find("gone99")

      expect(shell).to have_received(:capture).once
    end

    it "reads again once the kept listing has expired" do
      listing.find("aaa111")
      clock[:at] = now + described_class::TTL + 1
      listing.find("aaa111")

      expect(shell).to have_received(:capture).twice
    end
  end
end
