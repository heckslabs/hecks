require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses a `lifecycle :field, default: ... do transition ... end` block into a `Lifecycle`.
      class LifecycleBuilder
        GRAMMAR_CONTEXT = "Lifecycle".freeze

        include WordGate

        # @param field [Symbol, String] the attribute the state machine lives on, such as `:status`
        # @param default [String, Symbol] the state a new record starts in
        def initialize(field, default:)
          @field       = field
          @default     = default
          @transitions = []
        end

        # Records one transition row per command in `mapping`, all sharing its `from:` guard.
        #
        # Listed in `BOOTSTRAP_CALLS_FALLBACK` because syntax.bluebook uses it during boot.
        #
        # @param mapping [Hash{String, Symbol => String, Symbol, Array<String>}] command name to
        #   target state, as in `"Purchase" => "sold"`; the optional `:from` key holds the
        #   state, or Array of states, the transition applies from, and nil or absent means any
        # @return [Hash] the command-to-target pairs just recorded, `:from` removed
        def transition_impl(mapping)
          mapping = mapping.dup
          from    = mapping.delete(:from)

          mapping.each do |command, target|
            @transitions << [
              command.to_s,
              StateTransition.new(target: target, from: from)
            ]
          end
        end

        # Assembles the declared transitions into a `Lifecycle`, refusing an ambiguous table.
        #
        # @return [Bluebook::Lifecycle] the state machine: its field, default and transitions
        # @raise [Bluebook::DSL::Malformed] if two transitions for one command could both apply
        #   from the same state (C5.3); skipped while shadow-parsing frozen era text
        def build
          refuse_ambiguity!
          Lifecycle.new(field: @field, default: @default, transitions: @transitions)
        end

        # Evaluates a `lifecycle` block against a fresh builder and returns what it built.
        #
        # @param field [Symbol, String] the attribute the state machine lives on
        # @param default [String, Symbol] the state a new record starts in
        # @yield the lifecycle body of `transition` rows, evaluated with the builder as `self`
        # @return [Bluebook::Lifecycle] the built state machine
        # @raise [Bluebook::DSL::Malformed] if two transitions for one command overlap, or the
        #   block uses a word the `Lifecycle` grammar does not admit
        def self.build(field, default:, &block)
          builder = new(field, default: default)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        # C5.3 (docs/semantics/bluebook-semantics.md): overlapping `from:` sets for one command
        # are refused. Disjoint sets are legitimate. An undeclared `from:` state is left to
        # `hecks model_check`.
        def refuse_ambiguity!
          return if MetaValidator.shadow_parsing? # frozen era text is exempt

          @transitions.each_with_index do |(command, transition), index|
            earlier = earlier_overlap(command, transition, index)
            next unless earlier

            raise Malformed,
                  "lifecycle :#{@field} declares two transitions for #{command.inspect} from the same state " \
                  "(=> #{earlier.last.target.inspect} and => #{transition.target.inspect}) — which one fires " \
                  "would be declaration order; give them disjoint from: states"
          end
        end

        def earlier_overlap(command, transition, index)
          @transitions[0...index].find do |other_command, other|
            other_command == command && overlap?(other, transition)
          end
        end

        def overlap?(one, other)
          return true if one.from.nil? || other.from.nil?

          Array(one.from).map(&:to_s).intersect?(Array(other.from).map(&:to_s))
        end
      end
    end
  end
end
