require "spec_helper"

# `for_binding`'s generic-settings fallback must apply only to the adapter the generic entry names.
# Otherwise Memory would read Heki's `persisted_by` entry and fail check_settings on `:dir`.
RSpec.describe "World#for_binding" do
  # Needs a Heki-bound and a Memory-bound aggregate under the same verb to reproduce the leak.
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
