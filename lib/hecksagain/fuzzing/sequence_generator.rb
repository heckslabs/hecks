require "fileutils"
require "set"
require "tmpdir"
require_relative "invalid_value_generator"
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

      # How often a payload is deliberately the wrong shape. Low, because a
      # refused step reaches no new state and a sequence of them is SILENT.
      MALFORMED_ARGUMENT_PROBABILITY = 0.12

      # How strongly an unexercised verb is preferred over one this sequence has
      # already dispatched. Random picking revisits the same handful of verbs and
      # leaves whole commands untouched for a whole run — which is the same
      # "reached no interesting state" problem the SILENT count reports, seen from
      # the generating end rather than the scoring end.
      UNEXERCISED_WEIGHT = 4

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
        @exercised        = Set.new
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
          queries: queries, entity_queries: entity_queries, populators: populators(runtime),
          # Which aggregates this corpus can actually make one of — the ones
          # `satisfiable?` is entitled to wait for.
          creatable: creating.map { |entry| entry[:aggregate].hecks_name }.to_set }
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

        @exercised << entry[:verb]
        entry[:query] ? build_query_step(runtime, entry) : build_command_step(runtime, catalog, entry)
      end

      def pick(catalog)
        rest = catalog[:queries].dup
        catalog[:instance].each { |entry| rest << entry if actionable?(catalog, entry) }
        catalog[:entity_commands].each { |entry| rest << entry if actionable?(catalog, entry) }
        catalog[:entity_queries].each { |entry| rest << entry if @known_ids[entry[:aggregate].hecks_name].any? }

        makers = catalog[:creating].select { |entry| satisfiable?(catalog, entry) }
        pool   = rest + makers.flat_map { |entry| [entry] * creating_weight(rest.size) }

        steer(pool).sample(random: @random)
      end

      # WHILE THERE IS NOTHING TO FIND, MAKING SOMETHING IS THE ONLY USEFUL MOVE.
      #
      # A flat weight is right once the domain has records in it, and badly
      # wrong before: banking declares ten queries, and from an empty store
      # exactly ONE creating command is satisfiable — Customer.Register, the
      # verb the whole cascade waits on. Two entries against ten left runs
      # spending their entire budget querying a store nothing had been written
      # to ; one seed answered ten empty queries in a row and emitted nothing
      # at all.
      #
      # So while nothing exists, creation matches everything else put together.
      # After that the ordinary weight applies and the run gets on with
      # exercising what it made.
      def creating_weight(rest_size)
        return CREATING_WEIGHT if @known_ids.each_value.any?(&:any?)

        [rest_size, CREATING_WEIGHT].max
      end

      def actionable?(catalog, entry)
        @known_ids[entry[:aggregate].hecks_name].any? && satisfiable?(catalog, entry)
      end

      # A COMMAND THAT REFERENCES NOTHING THAT EXISTS CANNOT SUCCEED, so it is
      # not offered until something does.
      #
      # `ValueGenerator.reference_value` has no real id to hand over when its
      # pool is empty, so it mints `missing-…` and the dispatch is refused
      # before it starts — a guaranteed waste of a step, and worse, one that
      # never fills the pool it was waiting on. Banking cascades from it:
      # Account.Open needs a Customer, ATMCard.Issue needs an Account,
      # Transfer.Request needs two, so a run that opened with the wrong verb
      # spent its whole budget being refused.
      #
      # This is the rule instance commands already follow — `known_ids.any?` —
      # applied to what a command REFERENCES rather than to what it acts on.
      # A target no creating command in this corpus can make (a cross-domain
      # reference, which `CommandRules#resolve_references` skips anyway) is
      # exempt, or the whole domain would starve waiting for it.
      def satisfiable?(catalog, entry)
        entry[:command].attributes.select(&:reference?).all? do |attribute|
          target = attribute.type.target_name.to_s
          !catalog[:creatable].include?(target) || @known_ids[target].any?
        end
      end

      # Coverage-guided rather than uniformly random : a verb this sequence has
      # not dispatched yet is weighted up, so a run spends its budget on the
      # commands it has not reached instead of re-rolling the ones it has. The
      # eligibility rules above still decide what is POSSIBLE — this only decides
      # what is likely, so a verb gated behind state it does not have yet stays
      # out of the pool entirely rather than being preferred forever.
      def steer(pool)
        fresh = pool.reject { |entry| @exercised.include?(entry[:verb]) }
        return pool if fresh.empty?

        pool + (fresh * UNEXERCISED_WEIGHT)
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
        args = attributes.each_with_object({}) do |attribute, built|
          # List-typed direct command arguments have no example in this repo's
          # domains today — every list is populated via a per-element append
          # command instead (docs/porting/behavior-notes.md). Skipped rather
          # than guessed at.
          next if attribute.list?

          built[attribute.name.to_s] = ValueGenerator.value_for(attribute, aggregate, random: @random, known_ids: @known_ids)
        end

        malform(args, attributes, aggregate)
      end

      # ONE MALFORMATION AT A TIME, and usually none. A step whose payload is
      # wrong in three ways only ever proves which check runs first ; wrong in
      # exactly one way names the check that fired. And the rate stays low on
      # purpose — a corrupted step is almost always refused, a sequence of
      # refusals reaches no state at all, and bin/fuzz already counts those as
      # SILENT rather than scoring them.
      def malform(args, attributes, aggregate)
        return args if args.empty? || @random.rand >= MALFORMED_ARGUMENT_PROBABILITY

        case @random.rand(3)
        when 0 then corrupt_one(args, attributes, aggregate)
        when 1 then drop_one(args, aggregate)
        else        args.merge([InvalidValueGenerator.undeclared_argument(random: @random)].to_h)
        end
      end

      # NEVER THE IDENTITY. A creating command with no id auto-mints one, and the
      # two runtimes mint differently by design — Ruby a random hex, Rust a
      # counter — so dropping it manufactures a disagreement that says nothing
      # about either runtime's behaviour. Every step in the hand-written corpus
      # supplies an id for the same reason. Whether an auto-minted id OUGHT to
      # agree is a real question, but it is not one a payload fuzzer can ask.
      def drop_one(args, aggregate)
        identity  = (aggregate.identified_by || :id).to_s
        droppable = args.keys - [identity, "id"]
        return args if droppable.empty?

        args.reject { |name, _| name == droppable.sample(random: @random) }
      end

      def corrupt_one(args, attributes, aggregate)
        named = attributes.reject(&:list?).select { |attribute| args.key?(attribute.name.to_s) }
        return args if named.empty?

        attribute = named.sample(random: @random)
        args.merge(attribute.name.to_s => InvalidValueGenerator.corrupt(attribute, aggregate, random: @random))
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

      # A step the runtime declines is not a generator failure — it simply did
      # not take effect, so nothing is recorded and the sequence carries on. The
      # step still goes into the corpus, because a REFUSAL IS AN ANSWER and the
      # two runtimes have to word it identically.
      #
      # EvaluationError sits alongside the declared refusals deliberately : a
      # payload the interpreter cannot read is the domain declining it, and
      # bin/run already records exactly those in a corpus's refusals —
      # `positive? expects a number, got "lots"` is one of banking's. Anything
      # else still propagates and fails spec/fuzzing, which is what says the
      # generator built a step that breaks the interpreter for reasons that have
      # nothing to do with a cross-runtime disagreement.
      def safe_call
        yield
      rescue *Hecksagain::Runtime::DOMAIN_REFUSALS, Hecksagain::Bluebook::Expression::EvaluationError
        nil
      end
    end
  end
end
