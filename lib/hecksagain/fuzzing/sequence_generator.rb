require "fileutils"
require "tmpdir"
require_relative "value_generator"

module Hecksagain
  module Fuzzing
    # A random-but-valid sequence of dispatches and queries, in the exact
    # `{name, note, steps}` shape `spec/parity/*.json` already uses — so it can
    # run through `bin/parity` completely unchanged. Boots a throwaway copy of
    # the domain and DISPATCHES each candidate step for real as it builds the
    # sequence (not just synthesizing plausible-looking JSON) : the only way to
    # know whether a step actually reached a new state, or which id an
    # auto-minted entity landed on, is to run it and watch what happened.
    #
    # Single-call fuzzing mostly misses the bugs this project has actually
    # found — they needed STATE first (a saga leg acting on a transfer that
    # already exists, a reference pointing at a customer already registered).
    # So this tracks what it has created as it goes, the same way
    # spec/banking_state_machine_spec.rb's hand-written generator does, and
    # weights later steps toward acting on what already exists.
    class SequenceGenerator
      # Creating commands are always eligible ; weighting them heavier (not
      # exclusively — a domain with only one or two aggregates would starve
      # everything else) makes a sequence reach an actionable state sooner
      # instead of spending its early budget refusing "acts on nothing yet."
      CREATING_WEIGHT = 2

      def self.generate(domain_path, seed:, steps:)
        new(domain_path, seed: seed, steps: steps).call
      end

      def initialize(domain_path, seed:, steps:)
        @domain_path      = domain_path
        @seed             = seed
        @step_count       = steps
        @random           = Random.new(seed)
        @known_ids        = Hash.new { |h, k| h[k] = [] }
        @entity_known_ids = Hash.new { |h, k| h[k] = [] }
      end

      def call
        Dir.mktmpdir("hecksagain-fuzz") do |tmp|
          copy = File.join(tmp, File.basename(@domain_path))
          FileUtils.cp_r(@domain_path, copy)
          # Real leftover data from ordinary use (bin/parity's own runs,
          # bin/console, whatever) lives under the example's data/ — copied
          # along with everything else. A generator that boots against it
          # starts from state its own known_ids tracking doesn't know about,
          # which is exactly the silent-contamination bug bin/parity's own
          # `run_domain` already guards against the same way : reset before
          # boot, every time.
          FileUtils.rm_rf(File.join(copy, "data"))
          runtime = Hecks.boot(copy)
          catalog = build_catalog(runtime)
          Array.new(@step_count) { attempt_step(runtime, catalog) }.compact
        end
      end

      private

      def build_catalog(runtime)
        creating, instance, entity_commands, queries, entity_queries = [], [], [], [], []

        runtime.registry.bluebooks.each do |domain_name, bluebook|
          bluebook.aggregates.each do |aggregate|
            aggregate.commands.each do |command|
              entry = { verb: "#{domain_name}::#{aggregate.hecks_name}.#{command.hecks_name}",
                        command: command, aggregate: aggregate }
              (command.creates? ? creating : instance) << entry
            end
            aggregate.queries.each do |query|
              queries << { verb: "#{domain_name}::#{aggregate.hecks_name}.#{query.name}",
                           query: query, aggregate: aggregate }
            end
            aggregate.entities.each do |entity|
              entity.commands.each do |command|
                entity_commands << { verb: "#{domain_name}::#{aggregate.hecks_name}.#{entity.hecks_name}.#{command.hecks_name}",
                                     command: command, aggregate: aggregate, entity: entity }
              end
              entity.queries.each do |query|
                entity_queries << { verb: "#{domain_name}::#{aggregate.hecks_name}.#{entity.hecks_name}.#{query.name}",
                                    query: query, aggregate: aggregate, entity: entity }
              end
            end
          end
        end

        { creating: creating, instance: instance, entity_commands: entity_commands,
          queries: queries, entity_queries: entity_queries, populators: populators(runtime) }
      end

      # Which command, on which aggregate, appends to which entity list — so a
      # successful dispatch can predict the identity the element it just added
      # landed on. Entity#identified_by is filled by `Array(current).size + 1`
      # (CommandInterpreter#entity_element) when the append's own field
      # mapping doesn't already assign it — the common case, predicted here.
      # A domain whose append explicitly assigns identity through a mapped
      # argument is covered too, without guessing: whatever value THIS
      # generator supplied for that argument at dispatch time IS the
      # identity, and gets recorded directly (see `record_outcome`).
      def populators(runtime)
        runtime.registry.bluebooks.each_value.flat_map do |bluebook|
          bluebook.aggregates.flat_map do |aggregate|
            aggregate.commands.filter_map do |command|
              append = command.mutations.find { |mutation| mutation.op == :append }
              next unless append

              list_attribute = aggregate.attribute(append.target)
              next unless list_attribute&.list?

              entity = aggregate.entities.find { |candidate| candidate.hecks_name == list_attribute.type.to_s }
              next unless entity

              identity_field = entity.identified_by
              mapped = identity_field && append.source[identity_field]
              { command: command, aggregate: aggregate, entity: entity,
                identity_field: identity_field, identity_argument: mapped.is_a?(Symbol) ? mapped : nil }
            end
          end
        end
      end

      def attempt_step(runtime, catalog)
        entry = pick(catalog)
        return nil unless entry

        entry[:query] ? build_query_step(runtime, entry) : build_command_step(runtime, catalog, entry)
      end

      def pick(catalog)
        pool = []
        catalog[:creating].each { |entry| CREATING_WEIGHT.times { pool << entry } }
        pool.concat(catalog[:queries])
        catalog[:instance].each { |entry| pool << entry if @known_ids[entry[:aggregate].hecks_name].any? }
        catalog[:entity_commands].each { |entry| pool << entry if @known_ids[entry[:aggregate].hecks_name].any? }
        catalog[:entity_queries].each { |entry| pool << entry if @known_ids[entry[:aggregate].hecks_name].any? }
        pool.sample(random: @random)
      end

      def build_query_step(runtime, entry)
        args = args_for(entry[:query].attributes, entry[:aggregate])
        safe_call { runtime.query(entry[:verb], **symbolize(args)) }
        { "query" => entry[:verb], "args" => args }
      end

      def build_command_step(runtime, catalog, entry)
        args = args_for(entry[:command].attributes, entry[:aggregate])
        add_identity!(args, entry)

        outcome = safe_call { runtime.dispatch(entry[:verb], **symbolize(args)) }
        record_outcome(catalog, entry, args) if outcome
        { "verb" => entry[:verb], "args" => args }
      end

      def args_for(attributes, aggregate)
        attributes.each_with_object({}) do |attribute, args|
          # List-typed direct command arguments have no example in this repo's
          # domains today — every list is populated via a per-element append
          # command instead (docs/porting/behavior-notes.md). Skipped rather
          # than guessed at.
          next if attribute.list?

          args[attribute.name.to_s] = ValueGenerator.value_for(attribute, aggregate, random: @random, known_ids: @known_ids)
        end
      end

      def add_identity!(args, entry)
        aggregate = entry[:aggregate]
        parent_key = (aggregate.identified_by || :id).to_s

        if entry[:entity]
          parent_scalar = pick_known(aggregate.hecks_name)
          args[parent_key] = identity_shaped(aggregate, aggregate.identified_by, parent_scalar, aggregate)
          entity_key = (entry[:entity].identified_by || :id).to_s
          entity_scalar = pick_entity_known(aggregate.hecks_name, entry[:entity].hecks_name, parent_scalar)
          args[entity_key] = identity_shaped(entry[:entity], entry[:entity].identified_by, entity_scalar, aggregate)
        elsif entry[:command].creates?
          args[parent_key] ||= identity_shaped(aggregate, aggregate.identified_by, ValueGenerator.random_id(@random), aggregate)
        else
          scalar = pick_known(aggregate.hecks_name)
          args[parent_key] = identity_shaped(aggregate, aggregate.identified_by, scalar, aggregate)
        end
      end

      # A bare scalar id, shaped to match whatever `construct` itself
      # declares that identity field as. `Account::LedgerEntry` is addressed
      # by `sequence`, and `sequence` is declared as a value-object-typed
      # attribute (`LedgerSequence`), not a plain identifier — a fuzz run
      # that skipped this wrapping and dispatched a bare `"1"` is exactly
      # what surfaced a real cross-runtime gap (Ruby refuses a bare scalar
      # against a value-object-typed identity with TypeMismatch ; Rust
      # accepts it and answers NotFound instead — same input, two different
      # refusals). Left as a bare scalar when the construct declares no such
      # attribute at all — the default `:id` case, which really is untyped.
      def identity_shaped(construct, key, scalar, aggregate)
        return scalar unless key

        attribute = construct.attribute(key)
        return scalar unless attribute

        value_object = aggregate.value_object(attribute.type.to_s)
        return scalar unless value_object

        field = value_object.attributes.first
        return scalar unless field

        { field.name.to_s => coerce_scalar(field.type.to_s, scalar) }
      end

      def coerce_scalar(type_name, scalar)
        case type_name
        when "Integer" then scalar.to_i
        when "Float"   then scalar.to_f
        else scalar.to_s
        end
      end

      def record_outcome(catalog, entry, args)
        aggregate = entry[:aggregate]
        parent_key = (aggregate.identified_by || :id).to_s
        parent_scalar = ValueGenerator.scalar_of(args[parent_key])

        @known_ids[aggregate.hecks_name] << parent_scalar if entry[:entity].nil? && entry[:command].creates?

        populator = catalog[:populators].find { |p| p[:command].equal?(entry[:command]) && p[:aggregate].equal?(aggregate) }
        return unless populator

        key = "#{aggregate.hecks_name}.#{populator[:entity].hecks_name}##{parent_scalar}"

        # The auto-minted case (CommandInterpreter#entity_element): the
        # element just landed at count-so-far + 1. The explicit case: this
        # generator itself supplied whatever value sits at
        # args[identity_argument] — no guessing needed, it's read straight
        # back.
        new_id =
          if populator[:identity_argument]
            ValueGenerator.scalar_of(args[populator[:identity_argument].to_s])
          else
            (@entity_known_ids[key].size + 1).to_s
          end
        @entity_known_ids[key] << new_id
      end

      def pick_known(name)
        pool = @known_ids[name]
        return ValueGenerator.random_id(@random) if pool.empty? || @random.rand < ValueGenerator::INVALID_REFERENCE_PROBABILITY

        pool.sample(random: @random)
      end

      def pick_entity_known(aggregate_name, entity_name, parent_id)
        pool = @entity_known_ids["#{aggregate_name}.#{entity_name}##{parent_id}"]
        return ValueGenerator.random_id(@random) if pool.empty? || @random.rand < ValueGenerator::INVALID_REFERENCE_PROBABILITY

        pool.sample(random: @random)
      end

      def symbolize(args) = args.transform_keys(&:to_sym)

      def safe_call
        yield
      rescue *Hecksagain::Runtime::DOMAIN_REFUSALS
        nil
      end
    end
  end
end
