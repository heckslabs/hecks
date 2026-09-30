require "spec_helper"
require "tempfile"

# none_in_state against a `lifecycle :status` target, not a plain `state` attribute.
# meta_validation is off so the comparator/interpreter pair is tested, not grammar admission.
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
    runtime.dispatch_flat("AntiJoinLifecycle::Claim.File", id: { value: "c1" })  # stays "held"
    runtime.dispatch_flat("AntiJoinLifecycle::Claim.File", id: { value: "c2" })
    runtime.dispatch_flat("AntiJoinLifecycle::Claim.Release", id: "c2")          # leaves "held"

    runtime.dispatch_flat("AntiJoinLifecycle::Board.Open", id: { value: "b1" })
    runtime.dispatch_flat("AntiJoinLifecycle::Board.Assign", id: "b1", claim_id: "c1")
    runtime.dispatch_flat("AntiJoinLifecycle::Board.Assign", id: "b1", claim_id: "c2")
    runtime.dispatch_flat("AntiJoinLifecycle::Board.Assign", id: "b1", claim_id: "nonexistent")

    rows = runtime.query("AntiJoinLifecycle::Board.Assignment.Unclaimed")

    # The target has no `:state` attribute, only `:status` via `lifecycle`; a bare
    # `record.state[:state]` read would wrongly include c1 (still held).
    expect(rows.map { |row| row[:claim_id] }).to contain_exactly("c2", "nonexistent")
  end
end
