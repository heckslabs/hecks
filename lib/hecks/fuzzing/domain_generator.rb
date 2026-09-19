require "fileutils"
require "json"
require_relative "form_census"

module Hecks
  module Fuzzing
    # **A small, valid bluebook, written from a seed** — so the QA loop can test
    # construct combinations nobody has hand-authored yet.
    #
    # The ledger's most productive moments were a new stress domain's first
    # sweep: `corrections` found four bugs, `referral_chain` four,
    # `tenant_ledger` two. Every one of those domains was written by hand,
    # one angle at a time, and `bin/qa_domain_novelty` exists precisely
    # because the bugs live where two declared forms meet on one aggregate
    # for the first time (`spec/combination_coverage_spec.rb`'s header).
    # This writes those meetings mechanically: a seed picks two
    # `FormCensus::FORMS` to force onto one aggregate, adds whatever other
    # aggregates those forms need (a reference target, a two-hop chain),
    # sprinkles extras (a lifecycle, a closed set, an entity, a query, a
    # policy, a role), and renders the whole thing as ordinary bluebook
    # source any runtime boots.
    #
    # **A blueprint, not source, is the unit**. `generate` answers a plain,
    # JSON-shaped Hash (string keys) — a small IR of its own — and `render`
    # turns it into source. That split is what makes a finding shrinkable
    # at the domain level: `shrink_candidates` removes one element at a time
    # (a query, a command, an entity, an aggregate, a given…) and `prune`
    # drops whatever that removal left dangling, using the explicit
    # `requires` tokens every dependent element carries. Nothing here
    # parses Ruby back.
    #
    # **Every generated domain is the same domain name** — `QaGenerated`, in a
    # `qa_generated/bluebook/qa_generated.bluebook` directory — because the
    # directory basename doubles as a Rust module and Cargo feature name
    # (`bin/project_rust`'s own landmine guard), and one fixed feature is
    # what lets `bin/qa_generated_domains --rust` rebuild incrementally.
    # Each domain is checked in its own child process for the same reason:
    # two different shapes under one constant name never share a process.
    module DomainGenerator
      DOMAIN_NAME = "QaGenerated".freeze
      DIRECTORY   = "qa_generated".freeze
      # `FORMS` — what this generator can build, defined at the bottom of
      # this module, beside the `Builder::FORM_STEPS` table it reads.

      # **No Rust-reserved snake names**. `Crate` was here first and every
      # domain holding it failed to compile under `--rust`: its snake form
      # is the keyword `crate`, which Rust cannot escape even as a raw
      # identifier, and the projection emits it as a module and field name
      # unguarded (`bin/project_rust` only guards the domain name). That is
      # a real finding, reported rather than generated into every run.
      AGGREGATE_NAMES = %w[Ticket Desk Parcel Venue Kiosk Hangar].freeze
      ENTITY_NAMES    = %w[Line Stamp].freeze
      CLOSED_SETS     = [%w[low high], %w[red amber green], %w[draft final]].freeze
      ROLES           = %w[Clerk Manager].freeze

      # Forms that need another aggregate to reference, and the ones that
      # need a two-hop chain ending in a lifecycle.
      REFERENCE_FORMS = %w[reference_attr revalued_reference].freeze
      CHAIN_FORMS     = %w[two_hop_given multi_hop_where].freeze

      module_function

      def generate(seed:, forms: nil)
        random = Random.new(seed)
        forms  = Array(forms || FORMS.sample(2, random: random)).map(&:to_s)
        unknown = forms - FORMS
        raise ArgumentError, "unknown form(s) #{unknown.join(', ')} — FormCensus::FORMS names #{FORMS.join(', ')}" if unknown.any?

        blueprint = Builder.new(random, forms).build
        prune(blueprint.merge("seed" => seed, "forms" => forms))
      end

      # `<root>/qa_generated/bluebook/qa_generated.bluebook`, plus the
      # blueprint beside the domain directory (never inside it — a stray
      # file under `bluebook/` would be loaded as a chapter).
      #
      # A blueprint carrying `"source"` is bluebook text someone else wrote
      # (`bin/qa_mine_combinations`' agent): it is adopted, not rendered,
      # and its empty `aggregates`/`policies` leave nothing to shrink.
      def write(blueprint, root)
        domain = File.join(root, DIRECTORY)
        FileUtils.rm_rf(domain)
        FileUtils.mkdir_p(File.join(domain, "bluebook"))
        text = blueprint["source"] ? adopt(blueprint["source"]) : render(blueprint)
        File.write(File.join(domain, "bluebook", "#{DIRECTORY}.bluebook"), text)
        File.write(File.join(root, "blueprint.json"), JSON.pretty_generate(blueprint))
        domain
      end

      # Renames an outside bluebook's own chapter to `QaGenerated`, the one
      # name the scratch crate and child processes are built around.
      def adopt(source)
        source.sub(/Hecks\.bluebook\s*\(?\s*(["'])[^"']+\1/) { "Hecks.bluebook #{DOMAIN_NAME.inspect}" }
      end

      # ── rendering ───────────────────────────────────────────────────

      def render(blueprint)
        out = []
        out << "# GENERATED by Hecks::Fuzzing::DomainGenerator — seed #{blueprint['seed']}, forms " \
               "#{blueprint['forms'].join(', ')}. Not hand-written; see bin/qa_generated_domains."
        out << "Hecks.bluebook #{DOMAIN_NAME.inspect} do"
        out << "  vision #{"A generated domain that puts #{blueprint['forms'].join(' and ')} together.".inspect}"
        out << ""
        out << "  core"
        blueprint["aggregates"].each { |aggregate| out.concat(render_aggregate(aggregate)) }
        blueprint["policies"].each { |policy| out.concat(render_policy(policy)) }
        out << "end"
        "#{out.join("\n")}\n"
      end

      def render_aggregate(aggregate)
        out = aggregate_header(aggregate)
        aggregate["attributes"].each { |attribute| out << "    #{render_attribute(attribute)}" }
        aggregate["references"].each { |target| out << "    reference_to #{target}" }
        aggregate["vos"].each { |name, vo| out.concat(render_value_object(name, vo, "    ")) }
        out.concat(render_lifecycle(aggregate["lifecycle"], "    ")) if aggregate["lifecycle"]
        aggregate["invariants"].each { |inv| out << "    invariant(#{inv['label'].inspect}) { #{inv['expr']} }" }
        aggregate["entities"].each { |entity| out.concat(render_entity(entity)) }
        aggregate["commands"].each { |command| out.concat(render_command(command, aggregate["name"], "    ")) }
        aggregate["queries"].each { |query| out.concat(render_query(query)) }
        out << "  end"
      end

      def aggregate_header(aggregate)
        ["", "  aggregate #{aggregate['name'].inspect} do",
         "    description #{"A generated #{aggregate['name'].downcase}.".inspect}", "",
         "    identified_by #{aggregate['identity'].map { |part| ":#{part}" }.join(', ')}"]
      end

      def render_entity(entity)
        out = ["", "    entity #{entity['name'].inspect} do",
               "      description #{"A generated #{entity['name'].downcase}.".inspect}"]
        out << "      identified_by #{entity['identity'].map { |part| ":#{part}" }.join(', ')}"
        entity["attributes"].each { |attribute| out << "      #{render_attribute(attribute)}" }
        out.concat(render_lifecycle(entity["lifecycle"], "      ")) if entity["lifecycle"]
        entity["commands"].each { |command| out.concat(render_command(command, nil, "      ")) }
        out << "    end"
      end

      def render_attribute(attribute)
        type = attribute["list"] ? "list_of(#{attribute['type']})" : attribute["type"]
        line = "attribute :#{attribute['name']}, #{type}"
        line += ", optional: true" if attribute["optional"]
        line += ", default: { value: #{attribute['default'].inspect} }" if attribute.key?("default")
        line
      end

      def render_value_object(name, value_object, indent)
        body =
          case value_object["kind"]
          when "string"
            ["attribute :value, String, pattern: '[^ \\t\\n\\r]'",
             "invariant(#{"a #{name} is not blank".inspect}) { !value.to_s.empty? }"]
          when "positive"
            ["attribute :value, Integer", "invariant(#{"a #{name} is positive".inspect}) { value.positive? }"]
          when "integer"
            ["attribute :value, Integer"]
          when "closed"
            ["attribute :value, String, one_of: #{value_object['members'].inspect}"]
          end
        ["", "#{indent}value_object #{name.inspect} do", *body.map { |line| "#{indent}  #{line}" }, "#{indent}end"]
      end

      def render_lifecycle(lifecycle, indent)
        out = ["", "#{indent}lifecycle :#{lifecycle['field']}, default: #{lifecycle['default'].inspect} do"]
        lifecycle["transitions"].each do |transition|
          from = transition["from"].size == 1 ? transition["from"].first.inspect : transition["from"].inspect
          out << "#{indent}  transition #{transition['command'].inspect} => #{transition['to'].inspect}, from: #{from}"
        end
        out << "#{indent}end"
      end

      def render_command(command, self_name, indent)
        out = ["", "#{indent}command #{command['name'].inspect} do"]
        out << "#{indent}  role #{command['role'].inspect}" if command["role"]
        out << "#{indent}  goal #{"#{command['name']} it".inspect}"
        out << "#{indent}  reference_to #{self_name}" if self_name && !command["creates"]
        command["references"].each { |target| out << "#{indent}  reference_to #{target}" }
        command["args"].each { |arg| out << "#{indent}  #{render_attribute(arg)}" }
        command["givens"].each { |given| out << "#{indent}  given(#{given['label'].inspect}) { #{given['expr']} }" }
        command["sets"].each { |set| out << "#{indent}  #{render_set(set)}" }
        command["emits"].each { |event| out << "#{indent}  emits #{event.inspect}" }
        out << "#{indent}end"
      end

      def render_set(set)
        return "sets :#{set['target']}, to: :#{set['to']}" if set["to"]
        return "sets :#{set['target']}, append: { #{set['append'].map { |k, v| "#{k}: :#{v}" }.join(', ')} }" if set["append"]

        "sets :#{set['target']}"
      end

      def render_query(query)
        out = ["", "    query #{query['name'].inspect} do", "      description #{"Generated #{query['name']}.".inspect}"]
        query["wheres"].each do |where|
          out << "      where(:#{where['field'].inspect} => #{where['value'].inspect})"
        end
        out << "      order_by :#{query['order_by']}"
        out << "    end"
      end

      def render_policy(policy)
        ["", "  policy #{policy['name'].inspect} do", "    on #{policy['on']}", "    trigger #{policy['trigger']}", "  end"]
      end

      # ── domain-level shrinking ──────────────────────────────────────

      # Every blueprint one removal smaller, each already pruned. Identity
      # attributes and creating commands are never offered: without them
      # there is no domain left to dispatch against.
      def shrink_candidates(blueprint)
        removals(blueprint).map { |path| prune(remove_at(blueprint, path)) }.uniq.reject { |candidate| candidate == blueprint }
      end

      def removals(blueprint)
        paths = blueprint["policies"].each_index.map { |i| ["policies", i] }
        blueprint["aggregates"].each_with_index do |aggregate, a|
          at = ["aggregates", a]
          paths << at if a.positive?
          %w[queries invariants entities references].each { |key| aggregate[key].each_index { |i| paths << [*at, key, i] } }
          paths << [*at, "lifecycle"] if aggregate["lifecycle"]
          aggregate["attributes"].each_with_index do |attribute, i|
            paths << [*at, "attributes", i] unless aggregate["identity"].include?(attribute["name"])
          end
          aggregate["commands"].each_with_index { |command, i| paths.concat(command_removals(command, [*at, "commands", i])) }
          paths.concat(entity_removals(aggregate, at))
        end
        paths
      end

      def entity_removals(aggregate, at)
        aggregate["entities"].each_with_index.flat_map do |entity, e|
          paths = entity["lifecycle"] ? [[*at, "entities", e, "lifecycle"]] : []
          paths + entity["commands"].each_index.map { |i| [*at, "entities", e, "commands", i] }
        end
      end

      def command_removals(command, at)
        paths = command["creates"] ? [] : [at]
        command["givens"].each_index { |g| paths << [*at, "givens", g] }
        paths << [*at, "role"] if command["role"]
        paths << [*at, "emits", command["emits"].size - 1] if command["emits"].size > 1
        paths
      end

      def remove_at(blueprint, path)
        copy = JSON.parse(JSON.generate(blueprint))
        *parents, last = path
        holder = parents.empty? ? copy : copy.dig(*parents)
        holder.is_a?(Array) ? holder.delete_at(last) : holder.delete(last)
        copy
      end

      # Drop whatever a removal left dangling, to a fixpoint. Every element
      # that depends on another carries `requires` — tokens naming exactly
      # what must still exist (`attribute:Ticket.score`, `lifecycle:Desk`,
      # `reference:Ticket->Desk`, `command:Ticket.Close`, …) — so this is
      # set arithmetic over those tokens, never a reading of the source.
      def prune(blueprint)
        current = JSON.parse(JSON.generate(blueprint))
        loop do
          available = tokens(current)
          before = JSON.generate(current)
          prune_once!(current, available)
          break if JSON.generate(current) == before
        end
        current
      end

      def prune_once!(blueprint, available)
        keep = ->(item) { Array(item["requires"]).all? { |token| available.include?(token) } }
        blueprint["policies"].select!(&keep)
        blueprint["aggregates"].each { |aggregate| prune_aggregate!(aggregate, available, keep) }
      end

      def prune_aggregate!(aggregate, available, keep)
        aggregate["references"].select! { |target| available.include?("aggregate:#{target}") }
        %w[attributes invariants entities].each { |key| aggregate[key].select!(&keep) }
        aggregate["queries"].each { |query| query["wheres"].select!(&keep) }
        aggregate["queries"].select! { |query| query["wheres"].any? }
        [aggregate, *aggregate["entities"]].each do |owner|
          prune_lifecycle!(owner, available)
          owner["commands"].each { |command| prune_command!(command, available) }
        end
      end

      def prune_lifecycle!(owner, available)
        return unless owner["lifecycle"]

        transitions = owner["lifecycle"]["transitions"]
        transitions.select! { |t| available.include?(t["requires"].first) }
        reachable = reachable_states(owner["lifecycle"]["default"], transitions)
        transitions.select! { |t| t["from"].any? { |state| reachable.include?(state) } }
        owner["lifecycle"] = nil if transitions.empty?
      end

      # **Every state a path from the default reaches**. A transition out of a
      # state nothing reaches can never fire, so a removal that orphans one
      # goes too: shrinking away `Close` used to leave `Reopen from closed`
      # behind — qa/stress_domains/generated_revalued_shape was promoted
      # that way, and bin/model_check reports it as a dead transition.
      def reachable_states(default, transitions)
        reachable = [default]
        loop do
          reached = transitions.select { |t| t["from"].any? { |state| reachable.include?(state) } }.map { |t| t["to"] }
          return reachable if (reached - reachable).empty?

          reachable |= reached
        end
      end

      def prune_command!(command, available)
        keep = ->(item) { Array(item["requires"]).all? { |token| available.include?(token) } }
        command["references"].select! { |target| available.include?("aggregate:#{target}") }
        %w[args givens sets].each { |key| command[key].select!(&keep) }
      end

      def tokens(blueprint)
        blueprint["aggregates"].each_with_object(Set.new) do |aggregate, set|
          name = aggregate["name"]
          set << "aggregate:#{name}"
          set << "lifecycle:#{name}" if aggregate["lifecycle"]
          aggregate["attributes"].each { |attribute| set << "attribute:#{name}.#{attribute['name']}" }
          aggregate["references"].each { |target| set << "reference:#{name}->#{target}" }
          aggregate["commands"].each do |command|
            set << "command:#{name}.#{command['name']}"
            command["references"].each { |target| set << "command_reference:#{name}.#{command['name']}->#{target}" }
            command["emits"].each { |event| set << "event:#{name}.#{event}" }
          end
          aggregate["entities"].each do |entity|
            set << "entity:#{name}.#{entity['name']}"
            set << "lifecycle:#{name}.#{entity['name']}" if entity["lifecycle"]
            entity["commands"].each { |command| set << "command:#{name}.#{entity['name']}.#{command['name']}" }
          end
        end
      end

      def snake(name) = name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase

      # ── building ────────────────────────────────────────────────────

      # One seeded pass: the aggregates the forms need, the forms forced
      # onto the first ("primary") aggregate, then extras everywhere.
      class Builder
        def initialize(random, forms)
          @random = random
          @forms  = forms
          @names  = AGGREGATE_NAMES.shuffle(random: random)
          @policies = []
        end

        def build
          chain = @forms.intersect?(CHAIN_FORMS)
          count = if chain then 3
                  elsif @forms.intersect?(REFERENCE_FORMS) then 2
                  else 1
                  end
          count += 1 if count < 3 && @random.rand < 0.3
          aggregates = @names.first(count).map { |name| base(name) }
          primary = aggregates.first

          link_chain(aggregates.first(3)) if chain
          @forms.each { |form| apply_form(form, primary, aggregates) }
          aggregates.each { |aggregate| extras(aggregate, aggregates) }
          { "aggregates" => aggregates, "policies" => @policies }
        end

        # One step per `FormCensus::FORMS` entry, each run against the
        # builder with the primary aggregate and every aggregate in play.
        FORM_STEPS = {
          "composite_id"       => ->(primary, _) { composite_id(primary) },
          "has_entity"         => ->(primary, _) { entity(primary) },
          "two_entities"       => ->(primary, _) { 2.times { entity(primary) } },
          "composite_piece"    => ->(primary, _) { entity(primary, composite: true) },
          "multi_emit"         => ->(primary, _) { creating(primary)["emits"] << "#{primary['name']}Logged" },
          "lifecycle"          => ->(primary, _) { lifecycle(primary) },
          "piece_lifecycle"    => ->(primary, _) { entity(primary, lifecycle: true) },
          "has_query"          => ->(primary, _) { query(primary) },
          "list_attr"          => ->(primary, _) { list_attr(primary) },
          "reference_attr"     => ->(primary, all) { reference_attr(primary, all[1]) },
          "closed_set"         => ->(primary, _) { closed_set(primary) },
          "has_default"        => ->(primary, _) { default_attr(primary) },
          "has_optional"       => ->(primary, _) { optional_arg(primary) },
          "two_hop_given"      => ->(primary, all) { two_hop_given(primary, all[1], all[2]) },
          "multi_hop_where"    => ->(primary, all) { multi_hop_where(primary, all[1], all[2]) },
          "revalued_reference" => ->(primary, all) { revalued_reference(primary, all[1]) }
        }.freeze

        private

        def chance?(probability) = @random.rand < probability

        def base(name)
          aggregate = { "name" => name, "identity" => ["code"], "vos" => {}, "attributes" => [], "references" => [],
                        "lifecycle" => nil, "invariants" => [], "entities" => [], "commands" => [], "queries" => [] }
          vo(aggregate, "#{name}Code", "string")
          aggregate["attributes"] << { "name" => "code", "type" => "#{name}Code" }
          aggregate["commands"] << { "name" => "Open", "creates" => true, "references" => [],
                                     "args" => [{ "name" => "code", "type" => "#{name}Code" }],
                                     "givens" => [], "sets" => [{ "target" => "code" }], "emits" => ["#{name}Opened"] }
          aggregate
        end

        def vo(aggregate, name, kind, members: nil)
          aggregate["vos"][name] ||= { "kind" => kind }.merge(members ? { "members" => members } : {})
        end

        def creating(aggregate) = aggregate["commands"].find { |command| command["creates"] }

        def command(aggregate, name, args: [], sets: [], givens: [], emits: nil)
          existing = aggregate["commands"].find { |candidate| candidate["name"] == name }
          return existing if existing

          entry = { "name" => name, "creates" => false, "references" => [], "args" => args, "givens" => givens,
                    "sets" => sets, "emits" => emits || ["#{aggregate['name']}#{past(name)}"] }
          aggregate["commands"] << entry
          entry
        end

        def past(verb) = verb.end_with?("e") ? "#{verb}d" : "#{verb}ed"

        # ── the forms ────────────────────────────────────────────────

        def apply_form(form, primary, aggregates) = instance_exec(primary, aggregates, &FORM_STEPS.fetch(form))

        def composite_id(aggregate)
          return if aggregate["identity"].size > 1

          name = aggregate["name"]
          vo(aggregate, "#{name}Branch", "string")
          vo(aggregate, "#{name}Number", "positive")
          aggregate["identity"] = %w[branch number]
          aggregate["attributes"].reject! { |attribute| attribute["name"] == "code" }
          aggregate["attributes"].unshift({ "name" => "branch", "type" => "#{name}Branch" },
                                          { "name" => "number", "type" => "#{name}Number" })
          open = creating(aggregate)
          open["args"] = [{ "name" => "branch", "type" => "#{name}Branch" }, { "name" => "number", "type" => "#{name}Number" }]
          open["sets"] = [{ "target" => "branch" }, { "target" => "number" }]
          aggregate["vos"].delete("#{name}Code")
        end

        def entity(aggregate, composite: false, lifecycle: false)
          taken = aggregate["entities"].map { |entity| entity["name"] }
          name  = (ENTITY_NAMES - taken).first
          return unless name

          owner  = aggregate["name"]
          list   = "#{name.downcase}s"
          parts  = composite ? %w[batch sequence] : ["sequence"]
          vo(aggregate, "#{name}Sequence", "positive")
          vo(aggregate, "#{name}Batch", "string") if composite
          vo(aggregate, "#{name}Label", "string")
          types = { "sequence" => "#{name}Sequence", "batch" => "#{name}Batch" }

          aggregate["attributes"] << { "name" => list, "type" => name, "list" => true, "requires" => ["entity:#{owner}.#{name}"] }
          # Event names are qualified by the owner aggregate, not just the
          # entity type — `ENTITY_NAMES` is a small pool (`Line`, `Stamp`)
          # shared across every aggregate in a domain, and `extras` can pick
          # the same entity name on a different aggregate than a form forced
          # it onto (composite there, plain here, or vice versa). Aggregate
          # names are always unique within one generated domain, so this is
          # the same qualification ordinary commands already get by default
          # (`"#{aggregate['name']}#{past(name)}"`) — without it, two
          # aggregates can both emit a bare "LineAdded" with different
          # shapes, which `validate_event_shapes!` correctly refuses.
          piece = { "name" => name, "identity" => parts, "requires" => [],
                    "attributes" => parts.map { |part| { "name" => part, "type" => types[part] } } +
                                    [{ "name" => "label", "type" => "#{name}Label", "optional" => true }],
                    "lifecycle" => nil,
                    "commands" => [{ "name" => "Label", "creates" => false, "references" => [],
                                     "args" => [{ "name" => "label", "type" => "#{name}Label" }], "givens" => [],
                                     "sets" => [{ "target" => "label" }], "emits" => ["#{owner}#{name}Labeled"] }] }
          if lifecycle || chance?(0.2)
            piece["commands"] << { "name" => "Settle", "creates" => false, "references" => [], "args" => [], "givens" => [],
                                   "sets" => [], "emits" => ["#{owner}#{name}Settled"] }
            piece["lifecycle"] = { "field" => "state", "default" => "pending",
                                   "transitions" => [{ "command" => "Settle", "to" => "settled", "from" => ["pending"],
                                                       "requires" => ["command:#{owner}.#{name}.Settle"] }] }
          end
          aggregate["entities"] << piece
          command(aggregate, "Add#{name}",
                  args:  parts.map { |part| { "name" => part, "type" => types[part] } },
                  sets:  [{ "target" => list, "append" => parts.to_h { |part| [part, part] },
                           "requires" => ["attribute:#{owner}.#{list}", "entity:#{owner}.#{name}"] }],
                  emits: ["#{owner}#{name}Added"])
        end

        def lifecycle(aggregate)
          return if aggregate["lifecycle"]

          name = aggregate["name"]
          command(aggregate, "Close")
          command(aggregate, "Reopen")
          aggregate["lifecycle"] = { "field" => "status", "default" => "open", "transitions" => [
            { "command" => "Close", "to" => "closed", "from" => ["open"], "requires" => ["command:#{name}.Close"] },
            { "command" => "Reopen", "to" => "open", "from" => ["closed"], "requires" => ["command:#{name}.Reopen"] }
          ] }
        end

        def query(aggregate)
          return if aggregate["queries"].any? { |query| query["name"] == "Listed" }

          name  = aggregate["name"]
          where = if aggregate["lifecycle"] || chance?(0.5)
                    lifecycle(aggregate)
                    { "field" => "status", "value" => "open", "requires" => ["lifecycle:#{name}"] }
                  else
                    members = closed_set(aggregate)
                    { "field" => "priority.value", "value" => members.first, "requires" => ["attribute:#{name}.priority"] }
                  end
          aggregate["queries"] << { "name" => "Listed", "wheres" => [where], "order_by" => aggregate["identity"].first }
        end

        def list_attr(aggregate)
          name = aggregate["name"]
          return if aggregate["attributes"].any? { |attribute| attribute["name"] == "tags" }

          vo(aggregate, "#{name}Tag", "string")
          aggregate["attributes"] << { "name" => "tags", "type" => "#{name}Tag", "list" => true }
          command(aggregate, "Retag", args: [{ "name" => "tags", "type" => "#{name}Tag", "list" => true }],
                                      sets: [{ "target" => "tags", "requires" => ["attribute:#{name}.tags"] }])
        end

        # Answers the closed set's members, so a query can filter on one.
        def closed_set(aggregate)
          name = aggregate["name"]
          existing = aggregate["vos"]["#{name}Priority"]
          return existing["members"] if existing

          members = CLOSED_SETS.sample(random: @random)
          vo(aggregate, "#{name}Priority", "closed", members: members)
          aggregate["attributes"] << { "name" => "priority", "type" => "#{name}Priority", "optional" => true }
          command(aggregate, "Prioritize", args: [{ "name" => "priority", "type" => "#{name}Priority" }],
                                           sets: [{ "target" => "priority", "requires" => ["attribute:#{name}.priority"] }])
          members
        end

        def default_attr(aggregate)
          name = aggregate["name"]
          return if aggregate["attributes"].any? { |attribute| attribute["name"] == "score" }

          vo(aggregate, "#{name}Score", "integer")
          aggregate["attributes"] << { "name" => "score", "type" => "#{name}Score", "default" => 0 }
          givens = []
          if chance?(0.5)
            givens << { "label" => "a score never drops", "expr" => "amount.value >= score.value",
                        "requires" => ["attribute:#{name}.score"] }
          end
          command(aggregate, "Rescore", args: [{ "name" => "amount", "type" => "#{name}Score" }], givens: givens,
                                        sets: [{ "target" => "score", "to" => "amount",
                                                 "requires" => ["attribute:#{name}.score"] }])
          return unless chance?(0.5)

          aggregate["invariants"] << { "label" => "a score is never negative", "expr" => "score.value >= 0",
                                       "requires" => ["attribute:#{name}.score"] }
        end

        def optional_arg(aggregate)
          name = aggregate["name"]
          return if aggregate["attributes"].any? { |attribute| attribute["name"] == "note" }

          vo(aggregate, "#{name}Note", "string")
          aggregate["attributes"] << { "name" => "note", "type" => "#{name}Note", "optional" => true }
          command(aggregate, "Annotate", args: [{ "name" => "note", "type" => "#{name}Note", "optional" => true }],
                                         sets: [{ "target" => "note", "requires" => ["attribute:#{name}.note"] }])
        end

        # An aggregate-level `reference_to`, set by the owner's own creating
        # command (`Member.Join`'s shape, qa/stress_domains/referral_chain).
        def reference_attr(owner, target)
          return unless target
          return if owner["references"].include?(target["name"])

          owner["references"] << target["name"]
          open = creating(owner)
          open["references"] << target["name"]
          open["sets"] << { "target"   => snake(target["name"]),
                            "requires" => ["reference:#{owner['name']}->#{target['name']}"] }
          return unless target["lifecycle"] && chance?(0.5)

          open["givens"] << { "label"    => "the #{snake(target['name'])} is open",
                              "expr"     => "#{snake(target['name'])}.status == \"open\"",
                              "requires" => ["lifecycle:#{target['name']}",
                                             "command_reference:#{owner['name']}.Open->#{target['name']}"] }
        end

        # primary -> middle -> root, root with a lifecycle.
        def link_chain(chain)
          primary, middle, root = chain
          lifecycle(root)
          reference_attr(middle, root)
          reference_attr(primary, middle)
        end

        def two_hop_given(primary, middle, root)
          return unless middle && root

          path = "#{snake(middle['name'])}.#{snake(root['name'])}.status"
          creating(primary)["givens"] << {
            "label" => "the #{snake(middle['name'])}'s #{snake(root['name'])} is open", "expr" => "#{path} == \"open\"",
            "requires" => ["lifecycle:#{root['name']}", "reference:#{middle['name']}->#{root['name']}",
                           "command_reference:#{primary['name']}.Open->#{middle['name']}"]
          }
        end

        def multi_hop_where(primary, middle, root)
          return unless middle && root

          field = "#{snake(middle['name'])}/#{snake(root['name'])}/status"
          primary["queries"] << {
            "name" => "ThroughOpen#{root['name']}", "order_by" => primary["identity"].first,
            "wheres" => [{ "field" => field, "value" => "open",
                           "requires" => ["lifecycle:#{root['name']}", "reference:#{middle['name']}->#{root['name']}",
                                          "reference:#{primary['name']}->#{middle['name']}"] }]
          }
        end

        # A command redeclaring the aggregate's own reference field under a
        # plain value object — `Referral.Reassign`'s shape (ADR 0037 F5).
        def revalued_reference(owner, target)
          return unless target

          reference_attr(owner, target)
          field = snake(target["name"])
          vo(owner, "#{target['name']}Handle", "string")
          requires = ["reference:#{owner['name']}->#{target['name']}"]
          command(owner, "Repoint", args: [{ "name" => field, "type" => "#{target['name']}Handle" }],
                                    sets: [{ "target" => field, "requires" => requires }])
        end

        # ── extras, on every aggregate ───────────────────────────────

        def extras(aggregate, aggregates)
          extra_shape(aggregate)
          extra_wiring(aggregate, aggregates)
        end

        def extra_shape(aggregate)
          lifecycle(aggregate) if chance?(0.4)
          closed_set(aggregate) if chance?(0.25)
          default_attr(aggregate) if chance?(0.25)
          optional_arg(aggregate) if chance?(0.25)
          entity(aggregate) if chance?(0.2)
          query(aggregate) if chance?(0.3)
          emits = creating(aggregate)["emits"]
          emits << "#{aggregate['name']}Logged" if chance?(0.15) && emits.size == 1
        end

        def extra_wiring(aggregate, aggregates)
          other = (aggregates - [aggregate]).sample(random: @random)
          reference_attr(aggregate, other) if other && chance?(0.15) && !creates_cycle?(aggregate, other, aggregates)
          aggregate["commands"].each { |command| command["role"] = ROLES.sample(random: @random) if chance?(0.3) }
          policy(aggregate) if aggregate["lifecycle"] && chance?(0.25)
        end

        def creates_cycle?(from, to, aggregates)
          seen = Set.new
          stack = [to["name"]]
          until stack.empty?
            name = stack.pop
            return true if name == from["name"]
            next unless seen.add?(name)

            stack.concat(aggregates.find { |aggregate| aggregate["name"] == name }["references"])
          end
          false
        end

        def policy(aggregate)
          name = aggregate["name"]
          event = creating(aggregate)["emits"].first
          @policies << { "name" => "On#{event}Close", "on" => "#{name}::#{event}", "trigger" => "#{name}::Close",
                         "requires" => ["event:#{name}.#{event}", "command:#{name}.Close", "lifecycle:#{name}"] }
        end

        def snake(name) = DomainGenerator.snake(name)
      end

      # **What this generator can build, not everything the census names**.
      # This read `FormCensus::FORMS.keys`, which quietly assumed the two
      # tables would always agree — and they stopped agreeing the moment
      # the census learned a form (`corrects`, `role_gated`) that
      # `Builder::FORM_STEPS` has no recipe for: `generate` raised
      # `KeyError` for any seed that happened to draw one. The census
      # measures what a domain has; this names what a generator can
      # write, and a form in the first without the second simply is not
      # generated — the rotation still meets it, and
      # `spec/combination_coverage_spec.rb`'s own `HELD_OUTSIDE_THE_GOLDENS`
      # names where. Kept honest by `spec/fuzzing/domain_generator_spec.rb`.
      FORMS = Builder::FORM_STEPS.keys.freeze
    end
  end
end
