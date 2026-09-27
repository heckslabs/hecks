require "spec_helper"

# `trigger ..., with:` projects what a trigger is given instead of forwarding the whole event.
#
# On a `for_each` the row key is merged into the projection's source, so a trigger can name the
# row and send nothing else.
RSpec.describe "a policy's trigger projection" do
  # rubocop:disable-next Metrics/AbcSize
  # rubocop:disable-next Metrics/MethodLength
  def boot_projection
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "Projecting" do
        aggregate "Permit" do
          attribute :code,   Code
          attribute :holder, Holder
          attribute :note,   Note

          identified_by :code

          value_object("Code")   { attribute :value, String }
          value_object("Holder") { attribute :value, String }
          value_object("Note")   { attribute :text,  String }

          lifecycle :status, default: "valid" do
            transition "Revoke" => "revoked", from: "valid"
          end

          command "Grant" do
            attribute :code,   Code
            attribute :holder, Holder
            sets :code
            sets :holder
            sets :note, to: { text: "granted" }
            emits "PermitGranted"
          end

          # Takes only which permit, nothing about the alert that caused it.
          command "Revoke" do
            reference_to Permit
            emits "PermitRevoked"
          end

          # Takes the note the alert carried under a different name.
          command "Annotate" do
            reference_to Permit
            attribute :note, Note
            sets :note
            emits "PermitAnnotated"
          end

          query "ForHolder" do
            attribute :holder, Holder
            where(holder: :holder)
          end
        end

        aggregate "Breach" do
          attribute :ref,     Ref
          attribute :holder,  Holder
          attribute :summary, Summary

          identified_by :ref

          value_object("Ref")     { attribute :value, String }
          value_object("Holder")  { attribute :value, String }
          value_object("Summary") { attribute :text,  String }

          command "Report" do
            attribute :ref,     Ref
            attribute :holder,  Holder
            attribute :summary, Summary
            sets :ref
            sets :holder
            sets :summary
            emits "BreachReported"
          end
        end

        # `Revoke` declares no arguments and `BreachReported` carries three, so without
        # the projection every delivery is refused as UnknownArgument.
        policy "RevokeOnBreach" do
          on       "BreachReported"
          for_each "Permit.ForHolder"
          trigger  Permit::Revoke, with: { permit: :permit }
        end
      end

      Hecks.hecksagon("Projecting") do
        Projecting::Permit.persisted_by("Memory")
        Projecting::Breach.persisted_by("Memory")
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) do
    boot_projection.tap do |bound|
      bound.dispatch_flat("Projecting::Permit.Grant", code: { value: "p-1" }, holder: { value: "h-1" })
      bound.dispatch_flat("Projecting::Permit.Grant", code: { value: "p-2" }, holder: { value: "h-1" })
      bound.dispatch_flat("Projecting::Permit.Grant", code: { value: "p-3" }, holder: { value: "h-2" })
    end
  end

  def report(breach = "b-1", holder: "h-1")
    runtime.dispatch_flat("Projecting::Breach.Report", ref: { value: breach },
                     holder: { value: holder }, summary: { text: "took the van" })
  end

  it "gives a fan-out's trigger the row and nothing else" do
    report

    fan = runtime.reactions.select { |row| row[:policy] == "RevokeOnBreach" }
    expect(fan.map { |row| row[:for_row] }).to contain_exactly("p-1", "p-2")
    expect(fan).to all(include(delivered: true))

    expect(Projecting::Permit.find("p-1").status).to eq("revoked")
    expect(Projecting::Permit.find("p-2").status).to eq("revoked")
    expect(Projecting::Permit.find("p-3").status).to eq("valid")
  end

  # Pins the regression: if the event's fields reached `Revoke` the refusal would be
  # `UnknownArgument: Revoke does not declare holder, ref, summary`.
  it "keeps the event's own fields away from a trigger that never declared them" do
    report

    expect(runtime.reactions.filter_map { |row| row[:reason] }).to be_empty
  end

  it "renames a field on the way through" do
    runtime.registry.bluebook("Projecting").policies.first
           .instance_variable_set(:@trigger_command, "Permit.Annotate")
    runtime.registry.bluebook("Projecting").policies.first
           .instance_variable_set(:@with_spec, [[:permit, :permit], [:note, :summary]])

    report

    # `summary` on the breach is `note` on the permit: the target's name wins.
    expect(Projecting::Permit.find("p-1").note.to_h).to eq(text: "took the van")
  end

  it "still forwards the whole payload when no projection is declared" do
    runtime.registry.bluebook("Projecting").policies.first
           .instance_variable_set(:@with_spec, [])

    report

    reasons = runtime.reactions.filter_map { |row| row[:reason] }
    expect(reasons).to all(include("Revoke does not declare"))
  end
end
