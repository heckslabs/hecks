# Hecks::Parity::Fuzz::Generator
#
# Purpose: Generate a legal synthetic bluebook + command sequence
# from a u64 seed. Biased toward cascade shapes — singleton
# aggregates with Integer fields and `given` predicates, plus
# cross-aggregate policies — so the sleep-regression class surfaces
# ~1 in 20 seeds.
#
# The generator enforces legality (unique emits, policy on_event
# matching an existing emits, attrs referenced by givens declared,
# Create-prefix only for new self-referenced entities) rather than
# fuzzing random bytes. Near-legal candidates are rejection-sampled
# up to 20 attempts per seed.
#
# Seed 1 is reserved for a hand-tuned cascade shape that reproduces
# the sleep-regression. Must-catch gate against generator drift.
#
# Usage:
#   program = Hecks::Parity::Fuzz::Generator.generate(42)
#   program.bluebook       # String (the .bluebook source)
#   program.commands       # Array<{ aggregate:, command:, attrs: }>
#   program.name           # "FuzzSeed42"
#
# [antibody-exempt: differential fuzzer per i30 plan — closes the
# cascade-state-propagation parity gap; retires when fuzzer ports
# to bluebook-dispatched form via hecks-life run]

require_relative "generator/renderer"
require_relative "generator/seed_1"

module Hecks
  module Parity
    module Fuzz
      Program = Struct.new(:name, :bluebook, :commands, :seed, keyword_init: true) unless defined?(Program)

      module Generator
        module_function

        TYPE_ALPHABET = [
          [:int,       "Integer"],
          [:str,       "String"],
          [:float,     "Float"],
          [:bool,      "Boolean"],
          [:list_str,  "list_of(String)"],
          [:list_int,  "list_of(Integer)"],
        ].freeze

        CREATE_PREFIXES  = %w[Create Add Place Register Open].freeze
        NON_CREATE_VERBS = %w[Update Set Bump Accumulate Mark Note Record Report Tag].freeze
        LIFECYCLE_STATES = %w[draft pending active paused done cancelled].freeze

        SEED_1 = 1

        class LegalityError < StandardError; end

        def generate(seed)
          return Seed1.program if seed == SEED_1
          rng = Random.new(seed)
          attempts = 0
          begin
            attempts += 1
            raise "generator could not produce a legal program in 20 attempts for seed=#{seed}" if attempts > 20
            build_program(rng, seed)
          rescue LegalityError
            retry
          end
        end

        def build_program(rng, seed)
          n_aggregates = rng.rand(1..3)
          aggregates = (1..n_aggregates).map { |i| build_aggregate(rng, i) }
          policies = build_policies(rng, aggregates)
          check_legality(aggregates, policies)
          name = "FuzzSeed#{seed}"
          bluebook = Renderer.render_bluebook(name, aggregates, policies)
          commands = build_command_sequence(rng, aggregates, policies)
          Program.new(name: name, bluebook: bluebook, commands: commands, seed: seed)
        end

        def build_aggregate(rng, index)
          agg_name = "Agg#{index}"
          n_attrs = rng.rand(2..5)
          attrs = (1..n_attrs).map { |k| build_attribute(rng, k) }
          # Lifecycles are excluded from v1: Rust enforces `from:`
          # guards strictly, Ruby doesn't, and the resulting
          # divergence dominates signal. Re-enable in v2 by driving
          # the command sequence off lifecycle state (never emit the
          # same transition command twice in a row).
          lifecycle = nil
          n_cmds = rng.rand(1..4)
          cmds = (1..n_cmds).map { |k| build_command(rng, agg_name, attrs, k) }
          cmds[0] = promote_to_create(cmds[0])
          { name: agg_name, attrs: attrs, commands: cmds, lifecycle: lifecycle }
        end

        def build_attribute(rng, index)
          type_key, type_src = TYPE_ALPHABET[rng.rand(TYPE_ALPHABET.size)]
          { name: "field#{index}", type_key: type_key, type_src: type_src }
        end

        def build_lifecycle(rng)
          n_states = rng.rand(2..4)
          picks = LIFECYCLE_STATES.shuffle(random: rng).first(n_states)
          { field: "status", default: picks.first, states: picks, transitions: [] }
        end

        # Wire non-Create commands to successive state pairs. Create
        # commands are deliberately left off the lifecycle so the
        # program can issue multiple Creates without tripping a
        # from-state violation (Rust enforces, Ruby doesn't — that's
        # a real divergence, but not the class this fuzzer targets).
        def build_transitions(cmds, states)
          result = []
          non_create = cmds.reject { |c| CREATE_PREFIXES.any? { |p| c[:name].start_with?(p) } }
          (0...[non_create.size, states.size - 1].min).each do |i|
            result << { command: non_create[i][:name], from: states[i], to: states[i + 1] }
          end
          result
        end

        def build_command(rng, agg_name, attrs, index)
          verb = (index == 1) ? CREATE_PREFIXES.sample(random: rng) : NON_CREATE_VERBS.sample(random: rng)
          cmd_name = "#{verb}#{agg_name}Thing#{index}"
          emits = "#{verb}#{agg_name}#{index}Event"
          self_ref = CREATE_PREFIXES.any? { |p| cmd_name.start_with?(p) } ? false : (rng.rand < 0.5)
          # Pick mutation attrs from integer fields, *then* pick given
          # attrs from the leftover integers (disjoint from mutations).
          # The same attribute appearing in both is a known runtime
          # divergence (auto-input-copy on create overwrites the
          # mutation) and is excluded from fuzzer shapes by construction.
          mutation_attrs = pick_mutation_attrs(rng, attrs)
          given_attrs = pick_given_attrs(rng, attrs - mutation_attrs)
          {
            name: cmd_name,
            verb: verb,
            emits: emits,
            self_ref: self_ref,
            given_attrs: given_attrs,
            mutation_attrs: mutation_attrs,
            owning_aggregate: agg_name,
          }
        end

        def promote_to_create(cmd)
          return cmd if CREATE_PREFIXES.any? { |p| cmd[:name].start_with?(p) }
          new_verb = "Create"
          old_verb = cmd[:verb]
          cmd.merge(
            name: cmd[:name].sub(old_verb, new_verb),
            verb: new_verb,
            emits: cmd[:emits].sub(old_verb, new_verb),
            self_ref: false,
          )
        end

        def pick_given_attrs(rng, attrs)
          ints = attrs.select { |a| a[:type_key] == :int }
          return [] if ints.empty? || rng.rand < 0.4
          [ints.sample(random: rng)]
        end

        def pick_mutation_attrs(rng, attrs)
          attrs.select { |a| a[:type_key] == :int }.sample(2, random: rng)
        end

        def build_policies(rng, aggregates)
          return [] if aggregates.size < 2
          n = rng.rand(0..2)
          return [] if n.zero?
          events = aggregates.flat_map { |a| a[:commands].map { |c| c[:emits] } }
          policies = []
          n.times do |i|
            source_event = events.sample(random: rng)
            target_agg   = aggregates.sample(random: rng)
            candidates = target_agg[:commands].reject { |c| c[:self_ref] }
            next if candidates.empty?
            trigger = candidates.sample(random: rng)
            policies << {
              name: "Policy#{i}_#{source_event}_to_#{trigger[:name]}",
              on_event: source_event,
              trigger: trigger[:name],
              target_agg: target_agg[:name],
            }
          end
          policies
        end

        def check_legality(aggregates, policies)
          emits = aggregates.flat_map { |a| a[:commands].map { |c| c[:emits] } }
          raise LegalityError, "duplicate emits" if emits.size != emits.uniq.size
          policies.each do |p|
            raise LegalityError, "policy on_event not emitted: #{p[:on_event]}" unless emits.include?(p[:on_event])
          end
        end

        def build_command_sequence(rng, aggregates, _policies)
          steps = []
          aggregates.each do |agg|
            create = agg[:commands].find { |c| CREATE_PREFIXES.any? { |p| c[:name].start_with?(p) } }
            next unless create
            steps << step_for(rng, agg, create)
          end
          n_extra = rng.rand(2..5)
          n_extra.times do
            agg = aggregates.sample(random: rng)
            cmd = agg[:commands].reject { |c| c[:self_ref] }.sample(random: rng)
            next unless cmd
            steps << step_for(rng, agg, cmd)
          end
          steps
        end

        def step_for(rng, _agg, cmd)
          # Mutation attrs aren't declared as input anymore, so steps
          # carry no attrs by default. If a future generator shape
          # needs non-mutation inputs (e.g. self-ref ids), they go
          # here.
          _ = rng
          { aggregate: _agg[:name], command: cmd[:name], attrs: {} }
        end

      end
    end
  end
end
