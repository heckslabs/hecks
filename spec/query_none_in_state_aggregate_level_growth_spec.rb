require "spec_helper"
require "tmpdir"
require_relative "support/inline_bluebook_boot"

# Pins none_in_state on an aggregate-level query against a Memory- and a Heki-backed aggregate.
# Ports::Query::InMemory#holds? once lacked the case and excluded every row, and Heki#query must
# pass `context:` through or the comparator answers true for every row.
RSpec.describe "none_in_state on an ordinary AGGREGATE-level query" do
  include InlineBluebookBoot

  # `%<domain>s` is the chapter name, which differs per adapter so the two never share a constant.
  ANTI_JOIN_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "%<domain>s" do
      aggregate "Claim" do
        identified_by :id

        value_object "ClaimId" do
          attribute :value, String
        end

        value_object "ClaimState" do
          attribute :value, String, default: "held"
        end

        attribute :id,    ClaimId
        attribute :state, ClaimState

        command "File" do
          attribute :id, ClaimId
          emits "Filed"
        end

        command "Release" do
          reference_to Claim
          sets :state, to: { value: "released" }
        end
      end

      aggregate "Board" do
        identified_by :id

        value_object "BoardId" do
          attribute :value, String
        end

        attribute :id,       BoardId
        attribute :claim_id, String

        command "Open" do
          attribute :id,       BoardId
          attribute :claim_id, String
          emits "Opened"
        end

        query "Unclaimed" do
          where claim_id: { none_in_state: "Claim:held" }
        end
      end
    end
  BLUEBOOK

  HEKI_ADAPTER = File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/heki.adapter")

  # Claims c1 and c2 (c2 released), and boards b1, b2 and b3 pointing at c1, c2 and a claim that is
  # not there.
  def seed_claims_and_boards(runtime, domain)
    runtime.dispatch_flat("#{domain}::Claim.File", id: { value: "c1" })
    runtime.dispatch_flat("#{domain}::Claim.File", id: { value: "c2" })
    runtime.dispatch_flat("#{domain}::Claim.Release", id: "c2")
    runtime.dispatch_flat("#{domain}::Board.Open", id: { value: "b1" }, claim_id: "c1")
    runtime.dispatch_flat("#{domain}::Board.Open", id: { value: "b2" }, claim_id: "c2")
    runtime.dispatch_flat("#{domain}::Board.Open", id: { value: "b3" }, claim_id: "nonexistent")
  end

  { "Memory" => [], "Heki" => [HEKI_ADAPTER] }.each do |adapter, adapter_files|
    context "with a #{adapter}-backed aggregate" do
      let(:domain) { "AggregateAntiJoin#{adapter}Growth" }

      scratch_directory :dir, "hecks-none-in-state-"

      def boot_anti_join(adapter, adapter_files)
        chapter = domain
        boot(format(ANTI_JOIN_SOURCE, domain: chapter), chapter, root: @dir, adapters: adapter_files) do
          Object.const_get(chapter)::Claim.persisted_by(adapter)
          Object.const_get(chapter)::Board.persisted_by(adapter)
        end
      end

      it "excludes an aggregate-level row whose claim IS in the named state, and keeps the rest" do
        runtime = boot_anti_join(adapter, adapter_files)
        seed_claims_and_boards(runtime, domain)

        rows = runtime.query("#{domain}::Board.Unclaimed")

        expect(rows.map { |row| row[:id] }).to contain_exactly("b2", "b3")
      end
    end
  end
end
