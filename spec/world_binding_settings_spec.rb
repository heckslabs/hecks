require "spec_helper"

# `World#for_binding`'s generic-settings fallback used to answer for ANY
# adapter bound under the same verb, not just the one the generic entry
# actually names. A hecksagon binding two aggregates to two different
# adapters under one verb (one to Heki, one to Memory) sent Memory's own
# settings lookup down Heki's generic `persisted_by` entry — Memory then
# failed `check_settings` with "Memory does not declare :dir", a setting
# that was never its own. Fixed in `Behaviour::World#for_binding`
# (lib/hecks/bluebook/behaviour/hexagon.rb) to only fall back to the
# generic entry when its own `settings[:adapter]` matches the adapter being
# asked about.
RSpec.describe "World#for_binding" do
  # The inline domain (two aggregates, two adapters under one hecksagon)
  # IS the regression fixture — it needs both a Heki-bound and a
  # Memory-bound sibling under the same verb to reproduce the exact
  # generic-settings leak this pins shut.
  # rubocop:disable-next RSpec/ExampleLength
  it "answers {} for an adapter the world configured nothing for, even when a sibling adapter under the same verb has settings" do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook("Deciderate") do
        supporting
        aggregate "Game" do
          identified_by :label
          attribute :label, GameLabel
          value_object "GameLabel" do
            attribute :value, String
          end
          command "Start" do
            attribute :label, GameLabel
            emits "GameStarted"
          end
        end
        aggregate "Bubble" do
          identified_by :label
          attribute :label, BubbleLabel
          value_object "BubbleLabel" do
            attribute :value, String
          end
          command "Pop" do
            attribute :label, BubbleLabel
            emits "BubblePopped"
          end
        end
      end

      Hecks.hecksagon("Deciderate") do
        Deciderate::Game.persisted_by("Heki")
        Deciderate::Bubble.persisted_by("Memory")
      end

      Hecks.world("Deciderate") do
        persisted_by("Heki") do
          dir :default
        end
      end
    end

    world = registry.world("Deciderate")

    expect(world.for_binding("persisted_by", "Heki")).to include(adapter: "Heki")
    expect(world.for_binding("persisted_by", "Memory")).to eq({})
  end
end
