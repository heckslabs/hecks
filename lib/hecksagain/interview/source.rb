require_relative "../naming"

module Hecksagain
  module Interview
    # RENDER A RECONSTRUCTED CHAPTER BACK INTO .bluebook SOURCE.
    #
    # There has never been one of these — the only existing source emitter,
    # `translation/scaffold/renderer.rb`, writes translation EDGES, a much
    # smaller language — so its house style is what this borrows: string
    # building, one method per construct, and AMBIGUITY EMITTED AS A
    # PARSE-REFUSING CONSTRUCT rather than a comment, so a file this
    # cannot fully spell can only boot into a refusal, never silently
    # claim more than it means.
    #
    # EVERY PIECE HERE WAS READ OFF A REAL RECONSTRUCTED DECLARATION, not
    # guessed from the IR class definitions — `Mutation#to_h`,
    # `Query#to_h`, a saga's own `with_spec`, a closed set's own
    # `members` shape, all inspected against banking/pizzas before this
    # was written. Two encodings for "this value is an argument
    # reference, not a literal" exist SIDE BY SIDE in the real IR and
    # this renderer honours both rather than picking one:
    #   - a mutation's own `append` fields: `value.to_s` for a Symbol
    #     (so "amount", no colon) vs `value.inspect` for anything else
    #     (so a real Ruby literal, already valid source text) — told
    #     apart here by whether the string reads as a bare identifier.
    #   - a saga dispatch's own `with_spec` pairs: an EXPLICIT leading
    #     colon (":source") marks an argument; anything else is already
    #     `.inspect`-formatted literal text. Different code wrote each
    #     one; this renderer does not try to unify them.
    module Source
      module_function

      # ── the chapter ─────────────────────────────────────────────────

      def render(declaration)
        lines = header(declaration)
        declaration[:aggregates].each { |aggregate| lines.concat(indent(aggregate_block(declaration, aggregate), 1)) }
        declaration[:read_models].each { |rm| lines.concat(indent(read_model_block(rm), 1)) }
        top_level_policies(declaration).each { |policy| lines.concat(indent(policy_block(policy), 1)) }
        declaration[:process_managers].each { |pm| lines.concat(indent(process_manager_block(pm), 1)) }
        lines << "end"
        "#{lines.join("\n")}\n"
      end

      def header(declaration)
        args = [declaration[:name].inspect]
        args << "version: #{declaration[:version].inspect}" if declaration[:version]
        lines = ["Hecks.bluebook #{args.join(', ')} do"]
        lines << "  vision #{declaration[:vision].inspect}" if declaration[:vision]
        lines << "  #{declaration[:classification]}" if declaration[:classification]
        lines
      end

      # POLICIES DECLARED ON AN AGGREGATE (`aggregate: "Account"`) render
      # INSIDE that aggregate's own block, below — this is only the ones
      # with no owning aggregate, declared at the chapter's own top level,
      # exactly matching where the source actually put each one.
      def top_level_policies(declaration)
        declaration[:policies].reject { |policy| policy[:aggregate] }
      end

      def policies_on(declaration, aggregate_name)
        declaration[:policies].select { |policy| policy[:aggregate] == aggregate_name }
      end

      # ── aggregate / entity (structurally identical past this point) ───

      def aggregate_block(declaration, aggregate)
        lines = ["", "aggregate #{aggregate[:name].inspect} do"]
        lines.concat(indent(construct_body(aggregate, entities: aggregate[:entities],
                                                       value_objects: aggregate[:value_objects],
                                                       policies: policies_on(declaration, aggregate[:name])), 1))
        lines << "end"
        lines
      end

      def entity_block(entity)
        lines = ["", "entity #{entity[:name].inspect} do"]
        lines.concat(indent(construct_body(entity, entities: [], value_objects: [], policies: []), 1))
        lines << "end"
        lines
      end

      # SHARED BY AGGREGATE AND ENTITY — description, identity, scalar
      # attributes, nested value objects, nested entities, lifecycle,
      # commands, queries, aggregate-scoped policies. An entity supplies
      # empty arrays for the three sections it cannot declare
      # (value_objects, entities, policies — entities.md's own six-word
      # inventory, half an aggregate's eleven).
      def construct_body(construct, entities:, value_objects:, policies:)
        lines = []
        lines << "description #{construct[:description].inspect}" if construct[:description]
        # AGGREGATE-ONLY — an `Entity#to_h` carries no `:provenance`
        # key at all, so `construct[:provenance]` reads nil for one and
        # this line is skipped without needing a separate entity path.
        lines << "provenance from: #{ruby_literal(construct[:provenance])}" if construct[:provenance]
        lines.concat(identified_by_lines(construct[:identified_by]))
        lines << "" if construct[:identified_by].any? || construct[:description]
        value_objects.each { |vo| lines.concat(value_object_block(vo)); lines << "" }
        lines.concat(attribute_lines(construct[:attributes]))
        lines << "" if construct[:attributes].any?
        entities.each { |entity| lines.concat(entity_block(entity)); lines << "" }
        if construct[:lifecycle]
          lines.concat(lifecycle_block(construct[:lifecycle]))
          lines << ""
        end
        construct[:commands].each { |command| lines.concat(command_block(command)); lines << "" }
        construct[:queries].each { |query| lines.concat(query_block(query)); lines << "" }
        policies.each { |policy| lines.concat(policy_block(policy)); lines << "" }
        lines.pop while lines.last == ""
        lines
      end

      # AN IDENTITY WITH NO PATHS IS `unresolved`, NOT SILENCE. A chapter
      # mid-interview commonly has one — `Aggregate.Seal` refuses that
      # very state — and `unresolved` is a real construct
      # (`bin/scaffold_translation`'s own idiom) that cannot parse, so a
      # file rendered before an aggregate is sealed can only boot into a
      # refusal, never quietly claim a shape it does not have.
      def identified_by_lines(paths)
        return ["identified_by { unresolved }"] if paths.empty?
        return ["identified_by { #{paths.first} }"] if paths.size == 1

        ["identified_by do"] + indent(paths, 1) + ["end"]
      end

      # A LIST OF `Attribute`-SHAPED HASHES, MIXING TWO REAL SHAPES —
      # used for an aggregate's/entity's own attributes AND a
      # command's/query's own arguments alike, because both mix the same
      # two things: an ordinary value-object-typed field, and a
      # cross-aggregate REFERENCE. `CommandBuilder` turns any
      # `reference_to` that does not target the command's own root into
      # exactly this shape (`OnboardingCase.Open`'s `reference_to
      # Customer, as: :customer` is a command ARGUMENT this way, not
      # just an aggregate head) — so the split has to happen here, not
      # only where aggregate-level attributes render.
      def attribute_lines(attributes) = attributes.map { |a| attribute_or_reference_line(a) }

      REFERENCE_TYPE = /\AReference<(?<target>.+)>\z/

      def attribute_or_reference_line(attribute)
        match = REFERENCE_TYPE.match(attribute[:type].to_s)
        return attribute_line(attribute) unless match

        reference_to_line(match[:target], attribute[:name])
      end

      # THE DEFAULT NAME A BARE `reference_to Target` MINTS IS DERIVED,
      # NOT STORED — `Naming.reference_key(Target) + "_id"`, the same
      # rule `CommandBuilder`/`AggregateBuilder` themselves apply. An
      # attribute whose own name already IS that derived default needs
      # no `as:` at all; anything else (`source`/`destination` on
      # Transfer, both `Reference<Account>`) is only reachable because an
      # explicit alias named it, so the alias has to be said again here
      # or the rendered file would mint the wrong argument name.
      def reference_to_line(target, attribute_name)
        default = "#{Naming.reference_key(target)}_id"
        return "reference_to #{target}" if attribute_name.to_s == default

        "reference_to #{target}, as: :#{attribute_name}"
      end

      def attribute_line(attribute)
        type = attribute[:list] ? "list_of(#{attribute[:type]})" : attribute[:type].to_s
        parts = ["attribute :#{attribute[:name]}, #{type}"]
        parts << "default: #{ruby_literal(attribute[:default])}" unless attribute[:default].nil?
        parts << "optional: true" if attribute[:optional]
        parts << "pattern: #{attribute[:pattern].inspect}" if attribute[:pattern]
        parts << "admits: #{attribute[:admits].inspect}" if attribute[:admits]
        parts.join(", ")
      end

      # ── value objects ──────────────────────────────────────────────

      def value_object_block(vo)
        lines = ["value_object #{vo[:name].inspect} do"]
        by_name = vo[:attributes].to_h { |a| [a[:name].to_s, a] }
        vo[:attributes].each { |a| lines << indent_one(attribute_line(a)) }
        lines << "" if vo[:attributes].any? && (vo[:invariants].any? || vo[:closed_set])
        vo[:invariants].each { |inv| lines << indent_one(rule_line("invariant", inv)) }
        lines << indent_one("") if vo[:invariants].any? && vo[:closed_set]
        lines.concat(indent(one_of_block(vo[:members], by_name), 1)) if vo[:closed_set]
        lines << "end"
        lines.reject { |l| l == indent_one("") }
      end

      def one_of_block(members, attributes_by_name)
        lines = ["one_of do"]
        members.each do |pairs|
          rendered = pairs.map { |field, value| "#{field}: #{member_value(value, attributes_by_name[field])}" }
          lines << indent_one("member #{rendered.join(', ')}")
        end
        lines << "end"
        lines
      end

      # A MEMBER'S OWN VALUE, TYPED AGAINST ITS FIELD'S DECLARED
      # ATTRIBUTE — `members` stores every value as text
      # (`retention_months: "84"`, matching how a closed set's rows are
      # held), and only the attribute's own declared type says whether
      # that text is a quoted String or a bare Integer in real source.
      def member_value(text, attribute)
        attribute && attribute[:type] == "Integer" ? Integer(text).to_s : text.inspect
      end

      # ── lifecycle ───────────────────────────────────────────────────

      def lifecycle_block(lifecycle)
        lines = ["lifecycle :#{lifecycle[:field]}, default: #{lifecycle[:default].inspect} do"]
        grouped_transitions(lifecycle[:transitions]).each do |command, (to_state, from_states)|
          from = from_states.compact
          clause = from.empty? ? "" : ", from: #{from.size == 1 ? from.first.inspect : from.inspect}"
          lines << indent_one("transition #{command.inspect} => #{to_state.inspect}#{clause}")
        end
        lines << "end"
        lines
      end

      # ONE COMMAND, ONE TARGET STATE, POSSIBLY SEVERAL SOURCE STATES —
      # `Close` reaches `"closed"` from BOTH `"active"` and `"suspended"`
      # as two separate rows in the reconstructed list; the source says
      # it once, `from: ["active", "suspended"]`. Grouped back here by
      # the command name, since every row for one command targets the
      # same state (a command has exactly one `=>` in real source).
      def grouped_transitions(transitions)
        transitions.each_with_object({}) do |row, grouped|
          grouped[row[:command]] ||= [row[:to_state], []]
          grouped[row[:command]][1] << row[:from_state]
        end
      end

      # ── commands ────────────────────────────────────────────────────

      def command_block(command)
        lines = ["command #{command[:name].inspect} do"]
        body = []
        body << "role #{command[:role].inspect}" if command[:role]
        body << "goal #{command[:goal].inspect}" if command[:goal]
        body << "" if command[:role] || command[:goal]
        body << reference_line(command[:references]) if command[:references]
        body.concat(attribute_lines(command[:attributes]))
        body << "" if command[:references] || command[:attributes].any?
        command[:givens].each { |g| body << rule_line("given", g) }
        command[:ensures].each { |e| body << rule_line("ensures", e) }
        body << "" if command[:givens].any? || command[:ensures].any?
        command[:mutations].each { |m| body << mutation_line(m) }
        body << "" if command[:mutations].any?
        command[:emits].each { |event| body << "emits #{event.inspect}" }
        body.pop while body.last == ""
        lines.concat(indent(body, 1))
        lines << "end"
        lines
      end

      # A COMMAND'S OWN SELF-REFERENCE — `references` names the type it
      # acts on (its own aggregate, or the entity's own owner for a
      # piece's verb), which is always `reference_to <ThatSameType>`
      # with no `as:` in the corpus this renders from. A creating
      # command carries no `references` at all and this is never called
      # for one.
      def reference_line(type_name) = "reference_to #{type_name}"

      def rule_line(word, rule) = "#{word}(#{rule[:description].inspect}) { #{rule[:canonical]} }"

      def mutation_line(mutation)
        target = mutation[:target]
        case mutation[:op]
        when :append
          fields = mutation[:fields].map { |field, value| "#{field}: #{append_field_value(value)}" }
          "sets :#{target}, append: { #{fields.join(', ')} }"
        when :set       then "sets :#{target}, to: #{mutation_source(mutation[:source])}"
        when :increment then "sets :#{target}, increment: #{mutation_source(mutation[:source])}"
        when :decrement then "sets :#{target}, decrement: #{mutation_source(mutation[:source])}"
        else
          # A MUTATION OP THIS RENDERER DOES NOT KNOW — refused, not
          # guessed. `sets` admits exactly `to:`/`append:`/`increment:`/
          # `decrement:` today (aggregate.bluebook's own vocabulary); a
          # fifth would need a real decision about its own syntax, not
          # an invented one.
          "unresolved :#{target}, op: #{mutation[:op].inspect}"
        end
      end

      def mutation_source(source)
        source[:kind] == "argument" ? ":#{source[:name]}" : ruby_literal(source[:value])
      end

      # AN APPEND FIELD'S OWN VALUE ARRIVES PRE-STRINGIFIED —
      # `Mutation#appended_fields` already ran `.to_s` (a Symbol source)
      # or `.inspect` (anything else) before this ever sees it, so there
      # is no `kind:` tag to read the way `mutation_source` has one. A
      # bare identifier-shaped string is what `.to_s` on a Symbol always
      # produces and `.inspect` on anything else never does (a String
      # literal always carries its own quotes, a Hash its own braces) —
      # measured against real reconstructed mutations (banking's
      # `direction: { value: "credit" }`), not assumed.
      def append_field_value(value)
        value.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/) ? ":#{value}" : value
      end

      # ── queries ─────────────────────────────────────────────────────

      def query_block(query)
        lines = ["query #{query[:name].inspect} do"]
        body = []
        body << "description #{query[:description].inspect}" if query[:description]
        body.concat(attribute_lines(query[:attributes]))
        body << "" if query[:attributes].any?
        body.concat(query_option_lines(query))
        body.pop while body.last == ""
        lines.concat(indent(body, 1))
        lines << "end"
        lines
      end

      # SHARED BY `query` AND `report` — both are
      # `QuerySpecification::Common::Options` underneath (query.rb /
      # read_model.rb), so both carry the identical where/order_by/
      # limit/offset/freshness/consistency/index_hints/authorization
      # set. A `report`'s own `reference_to`/`include` lines are NOT
      # part of this — those come from `aggregate_heads`, a shape a
      # plain `query` does not have at all.
      def query_option_lines(spec)
        lines = []
        Array(spec[:wheres]).each { |w| lines << where_line(w) }
        lines << order_by_line(spec[:order_by]) if spec[:order_by]
        lines << "limit #{spec[:limit][:value]}" if spec[:limit]
        lines << "offset #{spec[:offset][:value]}" if spec[:offset]
        lines << freshness_line(spec[:freshness]) if spec[:freshness]
        lines << "consistency :#{spec[:consistency][:mode]}" if spec[:consistency]
        lines.concat(index_hints_lines(spec[:index_hints])) if spec[:index_hints]
        lines << authorize_line(spec[:authorization]) if spec[:authorization]
        lines
      end

      # A WHERE'S OWN VALUE IS TEXT, SPELLED THREE WAYS — `:floor` (a
      # leading colon) is a caller argument, referenced the same
      # dotted-hop-safe way `mutation_source` reads its own `kind:`; text
      # that reads as a bare integer (banking's own `where(balance: {gt:
      # 1000})`) renders back bare, never quoted into a string that would
      # compare differently; anything else is the literal comparator
      # itself, held as its exact source string (banking's own
      # `in: "open,frozen"` is one comma-joined STRING in real source,
      # not an array — rendered back verbatim, never split).
      #
      # THE KEY ITSELF NEEDS TWO SPELLINGS TOO. A plain field takes the
      # ordinary `field: value` hash-shorthand Ruby already reads as a
      # symbol key; a DOTTED hop (`"customer.status"`) cannot use that
      # shorthand at all (`customer.status:` is not a legal Ruby
      # identifier) and needs the quoted-symbol/hash-rocket spelling
      # instead — `where(field => value)` with a BARE field name, which
      # this used to emit unconditionally, is invalid Ruby: `field` reads
      # as an undefined local, not the symbol `:field`.
      def where_line(where)
        value = where_value(where[:value])
        return "where(#{where[:field]}: #{value})" if where[:op] == "eq" && !where[:field].include?(".")
        return %(where(:"#{where[:field]}" => #{value})) if where[:op] == "eq"
        return "where(#{where[:field]}: { #{where[:op]}: #{value} })" unless where[:field].include?(".")

        %(where(:"#{where[:field]}" => { #{where[:op]}: #{value} }))
      end

      # `text` is ALREADY the literal comparator's exact source string —
      # this class's own header comment on `where_line` names it: a
      # string comparator's `where[:value]` carries its own quote marks
      # already (`where(status: "active")`'s argument is captured
      # VERBATIM by extraction, `"active"` complete with the quotes that
      # made it a string literal in the first place), not a bare Ruby
      # String this method still needs to quote. `text.inspect` here
      # used to wrap that already-quoted text in a SECOND layer of
      # quoting — `"active"` became `"\"active\""` — a round-trip bug
      # no existing corpus member happened to exercise until banking's
      # own string-valued wheres (`Customer.Suspended`'s `where(standing:
      # "good")`, among many) went through this path for real.
      def where_value(text)
        return text if text.start_with?(":")
        return text if text.match?(/\A-?\d+\z/)

        text
      end

      # `symbol_literal`, NOT bare interpolation — a dotted field path
      # (`position.value`, a nested value-object field, the ordinary shape
      # for anything but a bare identity scalar) rendered as `:#{field}`
      # produces `:position.value`, which Ruby parses as a METHOD CALL on
      # the symbol literal `:position` — `undefined method 'value' for
      # an instance of Symbol` the first time this ever ran against a
      # real `order_by` on a nested field. The corpus render-gate never
      # caught it because no existing corpus member orders by anything
      # but a bare scalar.
      def order_by_line(order_by)
        direction = order_by[:direction] == "desc" ? ", :desc" : ""
        "order_by #{symbol_literal(order_by[:field])}#{direction}"
      end

      def freshness_line(freshness)
        "freshness :#{freshness[:mode]}#{freshness[:max_age] ? ", max_age: #{freshness[:max_age]}" : ''}"
      end

      def index_hints_lines(hints) = hints.map { |hint| "use_index :#{hint[:name]}" }

      def authorize_line(authorization)
        tenant = authorization[:tenant] ? ", tenant: :#{authorization[:tenant]}" : ""
        "authorize :#{authorization[:policy]}#{tenant}"
      end

      # ── policies / read models / sagas ─────────────────────────────

      def policy_block(policy)
        lines = ["policy #{policy[:name].inspect} do"]
        body = ["on      #{policy[:on_event].inspect}", "trigger #{policy[:trigger_command].inspect}"]
        body << "across  #{policy[:target_domain].inspect}" if policy[:target_domain]
        lines.concat(indent(body, 1))
        lines << "end"
        lines
      end

      # `aggregate_heads` CARRIES THE REFERENCE TARGET TOO — its own row
      # (`many: false`, matching `reference_target`) alongside every
      # `include`d aggregate (`many: true`) — the exact set
      # `report "CustomerPortfolio"`'s `reference_to Customer` +
      # six `include`s reconstructs into. Rendered back the same way:
      # the reference row becomes `reference_to`, everything else an
      # `include`, in the order the heads were declared.
      def read_model_block(rm)
        lines = ["", "report #{rm[:name].inspect} do"]
        body = []
        body << "description #{rm[:description].inspect}" if rm[:description]
        # `reference_to` NAMES the root; it does not by itself include
        # it — the reference target still needs its own `include`
        # alongside every other head, exactly the redundant-looking pair
        # the real corpus writes (`reference_to Customer` THEN
        # `include Customer`, both, confirmed against banking's own
        # `CustomerPortfolio`). Skipping the "already covered" include
        # was the bug this comment replaces: the reloaded report's own
        # `aggregate_heads` came back missing its first row entirely.
        # ROOTLESS reports (ConsoleSettings' own Styles/Curated) declare
        # NO reference_to at all — bulk reads with no root record, every
        # head arriving through `include` alone. A bare `reference_to `
        # with nothing after it (rm[:reference_target] rendered nil)
        # isn't just wrong, it's not even valid DSL — the builder raises
        # on a missing positional argument.
        body << "reference_to #{rm[:reference_target]}" if rm[:reference_target]
        Array(rm[:aggregate_heads]).each { |head| body << "include #{head[:aggregate]}" }
        body << "group_by #{Array(rm[:group_by]).map { |g| symbol_literal(g[:field]) }.join(', ')}" if Array(rm[:group_by]).any?
        # `count`/`median` are `group_by`'s own two siblings — see
        # `seal_aggregation` (read_model_builder.rb) for why a read
        # model never carries more than one of the three, so rendering
        # both unconditionally (rather than picking one) is safe.
        body << "count" if rm[:count]
        body << "median #{symbol_literal(rm[:median_field])}" if rm[:median_field]
        body << "" if body.any?
        body.concat(query_option_lines(rm))
        body.pop while body.last == ""
        lines.concat(indent(body, 1))
        lines << "end"
        lines
      end

      def process_manager_block(pm)
        lines = ["", "process_manager #{pm[:name].inspect} do"]
        body = ["correlates_by #{symbol_literal(pm[:correlates_by])}",
                "starts_on #{pm[:starts_on].inspect}", "ends_on   #{pm[:ends_on].inspect}", ""]
        pm[:states].each { |state| body << "state #{state.inspect}" }
        body << ""
        pm[:handlers].each { |handler| body.concat(handler_block(handler)); body << "" }
        body.pop while body.last == ""
        lines.concat(indent(body, 1))
        lines << "end"
        lines
      end

      # `event_type` "refused" IS THE SYMBOL `:refused`, not a string — a
      # saga's own compensation leg, keyed differently in real source
      # (`on :refused, transition: {...}`) from every other handler
      # (`on "EventName", transition: {...}`), and the two are not
      # interchangeable: `"refused"` would be an event nothing emits.
      def handler_block(handler)
        event = handler[:event_type] == "refused" ? ":refused" : handler[:event_type].inspect
        lines = ["on #{event}, transition: { #{handler[:from_state].inspect} => #{handler[:to_state].inspect} } do"]
        handler[:dispatches].each { |d| lines << indent_one(dispatch_line(d)) }
        lines << "end"
        lines
      end

      def dispatch_line(dispatch)
        pairs = dispatch[:with_spec].map { |key, value| "#{key}: #{dispatch_value(value)}" }
        "dispatch #{dispatch[:command_name].inspect}, with: { #{pairs.join(', ')} }"
      end

      # A DISPATCH'S OWN `with:` VALUE CARRIES AN EXPLICIT MARKER a
      # mutation's append fields do not: a leading colon (`":source"`)
      # means "read this off the correlation/payload", stripped here
      # for the bare `:source` Ruby needs; anything else is already
      # `.inspect`-formatted literal text (`"{:text=>\"transfer out\"}"`)
      # and goes through verbatim.
      def dispatch_value(value) = value.start_with?(":") ? value : value

      # A SYMBOL LITERAL, quoted the moment its text is not a bare Ruby
      # identifier. Measured, not assumed: `:reference.value` parses as
      # `(:reference).value` — a method call ON the symbol `:reference`,
      # not the single dotted symbol `:"reference.value"` this meant —
      # and every `correlates_by` in the real corpus is exactly this
      # dotted shape, so an unquoted render broke on the very first
      # process manager it ever tried (caught loading the rendered
      # output back, not by inspection).
      def symbol_literal(text) = text.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*[?!]?\z/) ? ":#{text}" : %(:"#{text}")

      # ── shared: literal Ruby, indentation ──────────────────────────

      # ANY RAW RUBY VALUE -> ITS OWN SOURCE TEXT — used only where the
      # reconstructed IR hands back a real object rather than
      # already-`.inspect`ed text (a `then_set ..., to: { value: "good" }`
      # literal source, an attribute's own `default:`). Recurses for a
      # Hash so a nested literal (`{ value: "good" }`) renders with the
      # same `key: value` spelling the rest of this file uses, not
      # `Hash#inspect`'s own `=>` form.
      def ruby_literal(value)
        case value
        when Hash  then "{ #{value.map { |k, v| "#{k}: #{ruby_literal(v)}" }.join(', ')} }"
        when Array then "[#{value.map { |v| ruby_literal(v) }.join(', ')}]"
        when nil   then "nil"
        else value.inspect
        end
      end

      def indent(lines, depth) = lines.map { |line| line.empty? ? line : ("  " * depth) + line }
      def indent_one(line) = line.empty? ? line : "  #{line}"
    end
  end
end
