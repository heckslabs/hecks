require "spec_helper"
require "tempfile"

# THE SHAPE THE OTHER `query_none_in_state_*_spec.rb` FILES DON'T COVER —
# every one of them (growth, aggregate_level_growth, heki) declares its
# target aggregate's state as a plain `attribute :state, ...`, never a
# real `lifecycle :field, ...`. Most aggregates in this codebase (and
# every aggregate `none_in_state` was actually written to answer
# questions about) use `lifecycle :status` instead, which is a real state
# MACHINE, not a bare attribute — and `Comparison#none_in_state?` used to
# hardcode `record.state[:state]`, silently reading `nil` off any
# lifecycle-backed record no matter what it actually held (`comparable
# (nil) != state` is true unconditionally, so `none_in_state` answered
# "not excluded" for every row, always). Found chasing
# `QualityControl::Bug::AwaitingClearance` against `QualityControl::
# Clearance` (`lifecycle :status`) in a since-superseded PR; kept here,
# independent of that domain, so the fix stays covered on its own merits.
#
# `meta_validation: false` -- same reason `query_none_in_state_growth_spec.rb`
# gives: what's under test is the comparator/interpreter pair, not the
# self-hosted grammar's own admission of the word.
RSpec.describe "none_in_state against a lifecycle-backed target" do
  def boot(source, hecksagon_name, &binds)
    file = Tempfile.new(["anti-join-lifecycle-", ".bluebook"])
    file.write(source)
    file.flush

    registry = Hecks::Runtime::Registry.new
    Hecks::Bluebook::MetaValidator.while_disabled do
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
        Hecks.hecksagon(hecksagon_name, &binds)
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(
      Hecks::Runtime::Dispatcher.new(registry)
    )
  ensure
    file&.close!
  end

  NONE_IN_STATE_LIFECYCLE_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "AntiJoinLifecycle" do
      aggregate "Claim" do
        identified_by :id

        value_object "ClaimId" do
          attribute :value, String
        end

        attribute :id, ClaimId

        lifecycle :status, default: "held" do
          transition "Release" => "released", from: "held"
        end

        command "File" do
          attribute :id, ClaimId
          emits "Filed"
        end

        command "Release" do
          reference_to Claim
          emits "Released"
        end
      end

      aggregate "Board" do
        identified_by :id

        value_object "BoardId" do
          attribute :value, String
        end

        attribute :id,          BoardId
        attribute :assignments, list_of(Assignment)

        entity "Assignment" do
          identified_by :claim_id

          attribute :claim_id, String

          query "Unclaimed" do
            where claim_id: { none_in_state: "Claim:held" }
          end
        end

        command "Open" do
          attribute :id, BoardId
          emits "Opened"
        end

        command "Assign" do
          reference_to Board
          attribute :claim_id, String
          sets :assignments, append: { claim_id: :claim_id }
          emits "Assigned"
        end
      end
    end
  BLUEBOOK

  def boot_anti_join_lifecycle
    boot(NONE_IN_STATE_LIFECYCLE_SOURCE, "AntiJoinLifecycle") do
      AntiJoinLifecycle::Claim.persisted_by("Memory")
      AntiJoinLifecycle::Board.persisted_by("Memory")
    end
  end

  it "reads the target's own declared lifecycle field, not a hardcoded :state key" do
    runtime = boot_anti_join_lifecycle
    runtime.dispatch("AntiJoinLifecycle::Claim.File", id: { value: "c1" })  # stays "held"
    runtime.dispatch("AntiJoinLifecycle::Claim.File", id: { value: "c2" })
    runtime.dispatch("AntiJoinLifecycle::Claim.Release", id: "c2")          # no longer "held"

    runtime.dispatch("AntiJoinLifecycle::Board.Open", id: { value: "b1" })
    runtime.dispatch("AntiJoinLifecycle::Board.Assign", id: "b1", claim_id: "c1")
    runtime.dispatch("AntiJoinLifecycle::Board.Assign", id: "b1", claim_id: "c2")
    # A claim that was never filed at all -- "no record in that state" reads
    # the same as "a record, but not in that state" -- same as the growth spec.
    runtime.dispatch("AntiJoinLifecycle::Board.Assign", id: "b1", claim_id: "nonexistent")

    rows = runtime.query("AntiJoinLifecycle::Board.Assignment.Unclaimed")

    # Before the fix, `record.state[:state]` read `nil` for EVERY row
    # (this target has no `:state` attribute at all, only `:status` via
    # `lifecycle`), so `c1` -- genuinely still "held" -- would have been
    # wrongly included alongside `c2` and `nonexistent`.
    expect(rows.map { |row| row[:claim_id] }).to contain_exactly("c2", "nonexistent")
  end
end
