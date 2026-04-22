# Hecks::Parity::Fuzz::Generator::Seed1
#
# Purpose: hand-tuned cascade-regression shape that reproduces the
# sleep-regression class. A singleton Counter with an integer
# threshold `given`, a second Gate aggregate whose emission fires a
# policy that triggers the gated Counter command. If the runtime
# resets Counter's state on the policy-triggered dispatch (the
# next_id bug fixed in state_resolver.rb), the given sees (0, 0)
# instead of (2, 8) and routes the wrong branch — fuzzer catches
# the divergence.
#
# Seed 1 is the must-catch gate against generator regressions.
#
# [antibody-exempt: differential fuzzer per i30 plan — retires when
# fuzzer ports to bluebook-dispatched form via hecks-life run]

module Hecks
  module Parity
    module Fuzz
      module Generator
        module Seed1
          module_function

          # Shape notes:
          #   - Counter is a singleton (non-self-ref commands).
          #   - CreateCounter sets `total` (declared as input attribute,
          #     so auto-input-copy on first create sets state.total to
          #     the passed value — no mutation collision because there's
          #     no then_set on `total`).
          #   - AccumulateCounter has a `given` on value < total and
          #     increments value. Ruby's next_id fix keeps the singleton
          #     record alive across dispatches, so value advances 0→1→2
          #     and then policy-cascades from each Gate.OpenGate event.
          #   - Gate.OpenGate is policy-triggered (no input attribute),
          #     with then_set :opened, increment: 1. Two OpenGate events
          #     yield opened=2 on both runtimes.
          #
          # Before the `next_id` fix, Ruby would mint a fresh Counter
          # id on each dispatch, resetting value to 0 with defaults-only
          # (no total) — the given would then see (0, nil) and fail, or
          # pass against a freshly-created (0, 0) where neither side
          # matches the other's state.
          BLUEBOOK = <<~BLUEBOOK
            Hecks.bluebook "FuzzSeed1", version: "2026.04.22.1" do
              vision "Seed 1 — hand-tuned cascade regression (sleep-class)."

              aggregate "Counter", "Accumulates pulses" do
                attribute :value, Integer
                attribute :total, Integer

                command "CreateCounter" do
                  role "System"
                  attribute :total, Integer
                  emits "CounterCreated"
                end

                command "AccumulateCounter" do
                  role "System"
                  given("value below total") { value < total }
                  then_set :value, increment: 1
                  emits "CounterAccumulated"
                end
              end

              aggregate "Gate", "Fires on creation" do
                attribute :opened, Integer

                command "OpenGate" do
                  role "System"
                  then_set :opened, increment: 1
                  emits "GateOpened"
                end
              end

              policy "Cascade" do
                on "GateOpened"
                trigger "AccumulateCounter"
              end
            end
          BLUEBOOK

          COMMANDS = [
            { aggregate: "Counter", command: "CreateCounter",     attrs: { "total" => 8 } },
            { aggregate: "Counter", command: "AccumulateCounter", attrs: {} },
            { aggregate: "Counter", command: "AccumulateCounter", attrs: {} },
            { aggregate: "Gate",    command: "OpenGate",          attrs: {} },
            { aggregate: "Gate",    command: "OpenGate",          attrs: {} },
          ].freeze

          def program
            Program.new(name: "FuzzSeed1", bluebook: BLUEBOOK, commands: COMMANDS.map(&:dup), seed: 1)
          end
        end
      end
    end
  end
end
