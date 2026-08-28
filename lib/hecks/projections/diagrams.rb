require_relative "../projector"

module Hecks
  module Projections
    # A DOMAIN'S OWN SHAPE, PROJECTED AS MERMAID DIAGRAMS — the same
    # trick `Projections::Reference`/`DocsProjector` already play for
    # prose, one level further: a diagram generated FROM the
    # declaration can't drift from it the way a hand-drawn one
    # inevitably does, because there is no second copy to forget to
    # update.
    #
    # MERMAID, NOT GRAPHVIZ (the two considered) — every diagram type
    # below has a Mermaid form purpose-built for exactly what the
    # underlying construct already is (a `lifecycle` IS a state
    # machine, `has_many`/`belongs_to` already speaks in cardinality,
    # `emits`/`trigger` already IS a directed graph), and the output is
    # plain text that renders natively wherever this project's own docs
    # already live — GitHub markdown, this repo's generated docs, Claude
    # Artifacts — with no build step and no external binary. Graphviz's
    # DOT format needs an actual render step (a `dot` binary, or a WASM
    # port) to become anything viewable, which is a real dependency this
    # repository's own discipline (see rust/parser's Cargo.toml: "no
    # dependency earns its way past std") would rather not take just to
    # draw a diagram.
    #
    # FOUR DIAGRAM KINDS, one file each per domain except lifecycles
    # (one per lifecycle-bearing construct, since that's how a reader
    # actually reaches for it — looking at ONE aggregate's states, not
    # every aggregate's at once):
    #
    #   <Name>_lifecycle.mmd  stateDiagram-v2  one per lifecycle
    #   relationships.mmd     erDiagram        the whole domain's has_many/
    #                                          has_one/belongs_to/reference_to
    #   dispatch.mmd          flowchart        the whole domain's command
    #                                          emits -> policy trigger chains
    #   roles.mmd             flowchart        every role that issues a
    #                                          command, wired to every
    #                                          command it issues
    #   ports.mmd             flowchart        every port operation, which
    #                                          aggregate exposes it, which
    #                                          aggregate it routes to: (if
    #                                          any), and what it emits
    #   read_models.mmd       flowchart        every read_model, and every
    #                                          aggregate it's assembled
    #                                          from — the read-side
    #                                          complement to relationships.mmd
    #   <Name>_surface.mmd    flowchart        one per aggregate/entity that
    #                                          declares at least one command
    #                                          or query — everything you can
    #                                          DO to it and ASK about it,
    #                                          AND what each command WRITES,
    #                                          in one place
    #   <Name>_saga.mmd       stateDiagram-v2  one per process_manager —
    #                                          its own states, and what
    #                                          each transition dispatches
    #                                          elsewhere in the domain
    #   frameworks.mmd        flowchart        every OTHER domain this one
    #                                          depends on — a shared
    #                                          framework it `uses_framework`,
    #                                          or a domain a policy reaches
    #                                          `across` — the one diagram
    #                                          here that looks OUTWARD past
    #                                          this domain's own boundary
    #
    # CONSTRUCT NAMES (aggregate/entity/command/event) ARE USED BARE,
    # UNSANITIZED, as Mermaid node/entity ids — safe because this
    # language's own word grammar only ever admits simple CamelCase/
    # snake_case identifiers there (confirmed: no space or punctuation
    # appears in any real aggregate/command/event name across the corpus
    # this projects from). A `role:` STRING IS FREE TEXT, though — the
    # real corpus already has "Back office"/"Vault officer"/"Branch
    # clerk" — so `roles.mmd` is the one diagram here that sanitizes a
    # name into an id (`role_id`) while keeping the real string as the
    # node's own displayed label.
    module Diagrams
      extend Hecks::Projector::Target

      projects_as :diagrams, emits: :files

      module_function

      def call(bluebook:, options: {})
        files = {}

        holders_with_lifecycle(bluebook).each do |holder|
          files["#{holder.hecks_name}_lifecycle.mmd"] = lifecycle_diagram(bluebook, holder)
        end

        if (diagram = relationship_diagram(bluebook))
          files["relationships.mmd"] = diagram
        end

        if (diagram = dispatch_diagram(bluebook))
          files["dispatch.mmd"] = diagram
        end

        if (diagram = roles_diagram(bluebook))
          files["roles.mmd"] = diagram
        end

        if (diagram = ports_diagram(bluebook))
          files["ports.mmd"] = diagram
        end

        if (diagram = read_model_diagram(bluebook))
          files["read_models.mmd"] = diagram
        end

        holders(bluebook).each do |holder|
          next if holder.commands.empty? && holder.queries.empty?

          files["#{holder.hecks_name}_surface.mmd"] = surface_diagram(bluebook, holder)
        end

        bluebook.process_managers.each do |saga|
          files["#{saga.hecks_name}_saga.mmd"] = saga_diagram(bluebook, saga)
        end

        if (diagram = frameworks_diagram(bluebook, options[:hecksagon]))
          files["frameworks.mmd"] = diagram
        end

        files
      end

      # ── shared ────────────────────────────────────────────────────────

      # AN ENTITY CAN CARRY ITS OWN LIFECYCLE, RELATIONSHIP, OR COMMAND
      # TOO — its own `lifecycle`/`reference_to`/`command` block,
      # addressed through its holding aggregate the same way
      # `DocsProjector` already treats an aggregate and its entities
      # alike. Walking both here means a domain's entity gaining any of
      # these needs no change to this file.
      def holders(bluebook)
        bluebook.aggregates.flat_map { |aggregate| [aggregate, *aggregate.entities] }
      end

      def holders_with_lifecycle(bluebook) = holders(bluebook).select(&:lifecycle)

      # `chapter_name` DRIVES THE RE-RUN HINT ALWAYS — that's the one
      # argument `bin/project_diagrams` actually takes, regardless of
      # which single aggregate/entity `subject` happens to name. Passing
      # the wrong one here once already produced a real, committed
      # `Order_lifecycle.mmd` telling a reader to run
      # `bin/project_diagrams <domain-path> Order` — a chapter name
      # Hecks.boot has never heard of.
      def header(chapter_name, subject)
        <<~HEADER
          %% GENERATED by bin/project_diagrams from #{subject} — DO NOT EDIT BY HAND.
          %% Re-run `bin/project_diagrams <domain-path> #{chapter_name}` after any change.
        HEADER
      end

      # ── lifecycle -> stateDiagram-v2 ─────────────────────────────────

      def lifecycle_diagram(bluebook, holder)
        lifecycle = holder.lifecycle
        edges = lifecycle.transitions.flat_map do |command_name, transition|
          Array(transition.from).map { |from_state| "    #{from_state} --> #{transition.target}: #{command_name}" }
        end

        subject = "#{holder.hecks_name}'s own declared lifecycle (field: #{lifecycle.field})"
        <<~MERMAID
          #{header(bluebook.name, subject)}stateDiagram-v2
              [*] --> #{lifecycle.default}
          #{edges.join("\n")}
        MERMAID
      end

      # ── relationships -> erDiagram ───────────────────────────────────

      # STANDARD CROW'S-FOOT READING, the same convention every ORM's own
      # ERD generator (Rails' erd gem included) already uses:
      # `has_many`/`has_one` are read from the OWNING side — one Holder
      # relates to many/one Target. `belongs_to`/`reference_to` are read
      # from the TARGET's side instead — one Target can be pointed at by
      # MANY Holders — because a bare reference carries no promise about
      # how many holders point back at it; "many" is the honest default
      # absent a declared uniqueness rule this language doesn't expose.
      # `optional?` only ever softens the side that can genuinely be
      # absent (a nilable reference, an empty has_one) — never the
      # crow's-foot "many" marker, which is a structural fact independent
      # of any one instance's optionality.
      def relationship_diagram(bluebook)
        edges = holders(bluebook).flat_map do |holder|
          holder.attributes.select(&:reference?).map { |attribute| relationship_edge(holder, attribute) }
        end
        return nil if edges.empty?

        subject = "#{bluebook.name}'s own declared reference_to/belongs_to/has_many/has_one attributes"
        "#{header(bluebook.name, subject)}erDiagram\n#{edges.join("\n")}\n"
      end

      def relationship_edge(holder, attribute)
        target = attribute.type.target_name
        case attribute.relationship
        when "has_many"
          %(    #{holder.hecks_name} ||--o{ #{target} : "#{attribute.name}")
        when "has_one"
          %(    #{holder.hecks_name} ||--#{attribute.optional? ? 'o|' : '||'} #{target} : "#{attribute.name}")
        when "belongs_to", "reference_to"
          %(    #{target} #{attribute.optional? ? '|o' : '||'}--o{ #{holder.hecks_name} : "#{attribute.name}")
        end
      end

      # ── dispatch -> flowchart ─────────────────────────────────────────

      # A COMMAND NODE, STADIUM-SHAPED (`(["..."])`); AN EVENT NODE,
      # HEXAGONAL (`{{"..."}}`) — one visual vocabulary for "a thing
      # someone does" versus "a fact that happened", matching the
      # language's own verb/event distinction. Command ids are qualified
      # by their owning aggregate (`cmd_Order_Purchase`) since two
      # aggregates may share a command name; event ids are bare
      # (`evt_PizzaCreated`) since an event is this domain's own
      # addressing key, the same way `policy.on_event` reaches it.
      def dispatch_diagram(bluebook)
        lines = []

        holders(bluebook).each do |holder|
          holder.commands.each do |command|
            command.emits.each { |event| lines << emits_edge(holder, command, event) }
          end
        end

        bluebook.policies.each { |policy| lines << trigger_edge(policy) }

        lines.compact!
        return nil if lines.empty?

        subject = "#{bluebook.name}'s own declared commands' emits and policies' on/trigger"
        "#{header(bluebook.name, subject)}flowchart LR\n#{lines.uniq.join("\n")}\n"
      end

      def emits_edge(holder, command, event)
        %(    #{command_node(holder.hecks_name, command.hecks_name)} -->|emits| #{event_node(event)})
      end

      # `on_event` IS SOMETIMES AGGREGATE-QUALIFIED
      # (`"Account.AccountFrozen"`) AND SOMETIMES BARE
      # (`"CustomerSuspended"`) in the real corpus — `emits` never is,
      # so this always matches against the bare tail, the same
      # normalization a reader has to do by eye today.
      #
      # A TRIGGER CROSSING INTO ANOTHER DOMAIN (`policy.target_domain`)
      # still draws — the target command just has no incoming `emits`
      # edge of its own here, which honestly shows "dispatch continues
      # elsewhere" rather than silently dropping the edge. The label
      # names which domain, so that's not a dead end on the page either.
      def trigger_edge(policy)
        bare_event = policy.on_event.to_s.split(".").last
        aggregate_name, command_name = policy.trigger_command.to_s.split(".", 2)
        label = policy.target_domain ? "triggers in #{policy.target_domain}" : "triggers"
        %(    #{event_node(bare_event)} -->|#{label}| #{command_node(aggregate_name, command_name)})
      end

      def command_node(aggregate_name, command_name)
        %(cmd_#{aggregate_name}_#{command_name}(["#{aggregate_name}.#{command_name}"]))
      end

      def event_node(event_name) = %(evt_#{event_name}{{"#{event_name}"}})

      # ── roles -> flowchart ────────────────────────────────────────────

      # WHO ISSUES WHAT, ACROSS THE WHOLE DOMAIN — data no existing
      # projection draws at all today (the reference pages' own
      # `command_entry` only ever prints a command's role as a single
      # line of prose, never assembled across commands). A command with
      # no declared `role` draws nothing — there is no fact to state.
      # Circle-shaped so a role reads as "who" beside `dispatch.mmd`'s
      # stadium ("what someone does") and hexagon ("what happened").
      def roles_diagram(bluebook)
        lines = holders(bluebook).flat_map do |holder|
          holder.commands.select(&:role).map { |command| role_edge(holder, command) }
        end
        return nil if lines.empty?

        subject = "#{bluebook.name}'s own declared command roles"
        "#{header(bluebook.name, subject)}flowchart LR\n#{lines.uniq.join("\n")}\n"
      end

      def role_edge(holder, command)
        %(    #{role_node(command.role)} -->|issues| #{command_node(holder.hecks_name, command.hecks_name)})
      end

      def role_node(role_name) = %(#{role_id(role_name)}((#{role_name})))

      # A ROLE NAME IS FREE TEXT ("Back office", "Vault officer") —
      # unlike every other name this file uses as a bare id, this one
      # has to be sanitized to become a legal Mermaid identifier. The
      # real string still appears as the node's own label
      # (`role_node`); only the id is mangled.
      def role_id(role_name) = "role_#{role_name.to_s.gsub(/[^A-Za-z0-9]+/, '_')}"

      # ── ports -> flowchart ───────────────────────────────────────────

      # A PORT OPERATION IS A BOUNDARY TRANSLATION, NOT A VERB OR A FACT —
      # its own reference page says so plainly ("the builder behind it
      # defines no `given` or `sets`, so an operation cannot read
      # aggregate state or mutate a record itself"), so it gets a third
      # shape, a trapezoid, beside `dispatch.mmd`'s stadium/hexagon
      # vocabulary. An aggregate drawn as a `to:` target is a cylinder —
      # state landing somewhere, the same reason a data store gets one
      # in an ordinary flowchart.
      #
      # TWO EDGE KINDS PER OPERATION: a dotted "exposes" edge from the
      # aggregate the port hangs off (always present — a port always
      # belongs to exactly one aggregate), and a solid "to:" edge to
      # whichever aggregate the operation itself names as its receiver
      # (present only when `to:` is declared — PR #351's own real
      # addition; before it, this data didn't exist to draw at all).
      # `emits` reuses `dispatch.mmd`'s own `event_node` unchanged — the
      # same fact, reached from a different direction.
      #
      # `bluebook.aggregates`, NOT the shared `holders` — unlike a
      # lifecycle/relationship/command, a port belongs to an AGGREGATE
      # only; an entity has no `ports` method at all (confirmed: calling
      # it raises, it isn't just always empty), so walking entities here
      # the way every other diagram in this file does would crash on
      # the first entity-bearing domain.
      def ports_diagram(bluebook)
        lines = bluebook.aggregates.flat_map do |holder|
          holder.ports.flat_map { |port| port.operations.map { |operation| port_edges(holder, port, operation) } }
        end.flatten

        return nil if lines.empty?

        subject = "#{bluebook.name}'s own declared port operations (which aggregate exposes each, its to:, and its emits)"
        "#{header(bluebook.name, subject)}flowchart LR\n#{lines.uniq.join("\n")}\n"
      end

      def port_edges(holder, port, operation)
        op = port_operation_node(holder.hecks_name, port.name, operation.hecks_name)
        edges = ["    #{holder.hecks_name}[(#{holder.hecks_name})] -.->|exposes| #{op}"]
        edges << "    #{op} -->|to: #{operation.to}| #{operation.to}[(#{operation.to})]" if operation.to
        operation.emits.each { |event| edges << "    #{op} -->|emits| #{event_node(event)}" }
        edges
      end

      def port_operation_node(aggregate_name, port_name, operation_name)
        id = "op_#{aggregate_name}_#{port_name}_#{operation_name}"
        %(#{id}[/"#{port_name}.#{operation_name}"/])
      end

      # ── read models -> flowchart ─────────────────────────────────────

      # THE READ-SIDE COMPLEMENT TO `relationships.mmd` — that diagram
      # shows how aggregates reference each other for WRITES
      # (`has_many`/`belongs_to`/`reference_to`); this shows how a
      # `read_model` ASSEMBLES data for READS, from
      # `aggregate_heads` — the same list `where`/`group_by`/`order_by`
      # all operate over, and the one fact every read_model has
      # regardless of whether it's rooted (`reference_target`) or
      # gathers heads with no root at all (a rootless read model, real
      # in the corpus: `AccountsByKind`).
      #
      # A READ MODEL IS A SUBROUTINE SHAPE (`[[...]]`, "a predefined
      # process") — a fourth shape, beside `ports.mmd`'s trapezoid and
      # `dispatch.mmd`'s stadium/hexagon: not a verb, not a fact, not a
      # boundary translation, but a standing, reusable view. Every
      # aggregate it draws from is a cylinder — the same "state lands
      # somewhere" shape `ports.mmd`'s `to:` target already uses, and
      # the same bare id, so an aggregate feeding several read_models
      # (real in banking: `Account` feeds four) merges into one node
      # across the whole diagram.
      #
      # THE LABEL NAMES THE SHAPE OF THE ANSWER, NOT JUST THE NAME —
      # `(count)`/`(median: field)` for the two real aggregations in the
      # corpus, nothing appended for an ordinary row-returning
      # read_model. Still MVP scope: `where`/`group_by`/`order_by`
      # aren't drawn at all yet — real facts, not invented, just not
      # this diagram's job yet.
      def read_model_diagram(bluebook)
        lines = bluebook.read_models.flat_map { |read_model| read_model_edges(read_model) }
        return nil if lines.empty?

        subject = "#{bluebook.name}'s own declared read_models and the aggregates each is assembled from"
        "#{header(bluebook.name, subject)}flowchart LR\n#{lines.uniq.join("\n")}\n"
      end

      def read_model_edges(read_model)
        shape = read_model.to_h
        node = %(rm_#{shape[:name]}[["#{read_model_label(shape)}"]])
        Array(shape[:aggregate_heads]).map do |head|
          # QUOTED, NOT BARE — an edge label containing `[` or `]`
          # (`accounts[]`, marking the "many" side) breaks Mermaid's own
          # `|label|` parser outright if left unquoted: it reads the
          # `[` as the START OF A NEW NODE SHAPE mid-label, not text.
          # Confirmed live against the real parser before this quoting
          # existed — every OTHER edge label in this file happens to be
          # a bare word or already-quoted string, so this is the one
          # spot that needed it.
          label = head[:many] ? "#{head[:as]}[]" : head[:as]
          %(    #{head[:aggregate]}[(#{head[:aggregate]})] -->|"#{label}"| #{node})
        end
      end

      def read_model_label(shape)
        return "#{shape[:name]} (count)" if shape[:count]
        return "#{shape[:name]} (median: #{shape[:median_field]})" if shape[:median_field]

        shape[:name]
      end

      # ── surface -> flowchart ─────────────────────────────────────────

      # "WHAT CAN I DO TO THIS, WHAT CAN I ASK ABOUT IT" — one file per
      # holder, unlike every other diagram here: `dispatch.mmd` already
      # shows a command's own onward reaction chain, but never an
      # aggregate's own FULL command/query menu in one place, and
      # `roles.mmd` shows who issues a command without saying what else
      # that same aggregate answers. This is the one diagram meant to
      # be read starting from the aggregate, not from a verb or a fact.
      #
      # A QUERY IS A DIAMOND — a fifth shape, beside `dispatch.mmd`'s
      # stadium/hexagon, `ports.mmd`'s trapezoid, and `read_models.mmd`'s
      # subroutine: a question with an answer, not a verb that changes
      # anything. Command edges are solid ("does"); query edges are
      # dotted ("asks") — the same solid/dotted split `ports.mmd`
      # already uses for "routes to:" versus "exposes".
      #
      # A WRITE TARGET IS A PLAIN RECTANGLE — a sixth shape, the first
      # here with no special bracket at all: an attribute is the
      # smallest, most passive thing this vocabulary names, a single
      # field living INSIDE the cylinder rather than a bounded thing of
      # its own. `command.mutations` (`sets`/`increment`/`decrement`/
      # `append`) was invisible everywhere before this — not just in a
      # diagram, in ANY projection, including the prose ones — despite
      # being the single densest fact in the whole IR (53 real
      # mutations across pizzas + banking). `dispatch.mmd` draws what a
      # command EMITS; this draws what it WRITES, the other half of
      # "what actually happens" a command never showed before.
      #
      # THE SAME ATTRIBUTE NODE MERGES ACROSS COMMANDS — real in
      # banking: `Account.Credit` and `Account.Debit` both point at the
      # same `balance` node, the same "one node, several incoming
      # edges" merge `read_models.mmd` already does for an aggregate
      # fed by several read_models.
      #
      # THE LABEL NAMES THE REAL SOURCE, NOT JUST THE VERB — an
      # increment/decrement/set almost always takes its value from an
      # argument, but not always the SAME-NAMED one: real in banking,
      # `Account.Credit`'s own `balance` is incremented by its
      # `amount` argument, and `LedgerEntry.Amend`'s own `amount` is
      # incremented by its `adjustment` argument. A literal source
      # (pizzas' own `Order.Purchase` sets `status` to the literal
      # `"sold"`, not an argument at all) is named as verbatim as
      # every other fact in this file. `append`'s own fields carry no
      # single source at all — its own field NAMES are the fact worth
      # stating (real: `Order.AddTopping` appends `name, amount`).
      def surface_diagram(bluebook, holder)
        lines = holder.commands.map { |command| "    #{holder.hecks_name}[(#{holder.hecks_name})] -->|does| #{command_node(holder.hecks_name, command.hecks_name)}" }
        lines += holder.commands.flat_map { |command| command.mutations.map { |mutation| mutation_edge(holder, command, mutation) } }
        lines += holder.queries.map { |query| "    #{holder.hecks_name}[(#{holder.hecks_name})] -.->|asks| #{query_node(holder.hecks_name, query.hecks_name)}" }

        subject = "#{holder.hecks_name}'s own declared commands (and what each writes) and queries"
        "#{header(bluebook.name, subject)}flowchart LR\n#{lines.uniq.join("\n")}\n"
      end

      def query_node(aggregate_name, query_name)
        %(qry_#{aggregate_name}_#{query_name}{"#{aggregate_name}.#{query_name}"})
      end

      def mutation_edge(holder, command, mutation)
        shape = mutation.to_h
        label = mutation_label(shape)
        target = attribute_node(holder.hecks_name, shape[:target])
        %(    #{command_node(holder.hecks_name, command.hecks_name)} -->|"#{label}"| #{target})
      end

      def mutation_label(shape)
        verb = "#{shape[:op]}s"
        # `fields:` (not `source:`) IS the multi-binding shape
        # (`Mutation#to_h`'s own `[:append, :delegate, :corrects]`
        # branch) — checked by the KEY'S PRESENCE, not by re-listing
        # which ops use it a second time here, the same lesson
        # `Change.op`'s own `admits: Vocabulary::MutationOp` already
        # drew (command.bluebook's own comment): a second list of "the
        # ops that mean multi-binding" is exactly the kind of copy that
        # drifts — `:delegate` already carried this shape with nothing
        # here reading it correctly, caught only once `:corrects` gave
        # banking's own real diagrams a fields:-shaped mutation to
        # actually render.
        detail = shape[:fields] ? shape[:fields].keys.join(", ") : mutation_source_detail(shape[:source])
        "#{verb}: #{detail}"
      end

      # A LITERAL VALUE CAN CONTAIN A DOUBLE QUOTE OF ITS OWN — real in
      # banking: `Customer.Reinstate` sets `standing` to a rendered
      # value-object literal, `{:value=>"good"}`, whose own embedded `"`
      # broke this label's outer `|"..."|` quoting outright (caught by
      # running the real generated output through mermaid.parse(), not
      # by eye — the same way `read_models.mmd`'s own unquoted `[]` bug
      # was caught). Swapped for a single quote here rather than
      # escaped, the same "state it, don't invent it, just make it
      # legal Mermaid" trade `read_models.mmd`'s own quoting fix made.
      def mutation_source_detail(source)
        case source[:kind]
        when "literal"  then "'#{source[:value].to_s.tr('"', "'")}'"
        when "argument" then source[:name]
        else source[:kind] # a source kind this file has no real corpus example of yet — named, not hidden
        end
      end

      def attribute_node(holder_name, attribute_name)
        %(attr_#{holder_name}_#{attribute_name}[#{attribute_name}])
      end

      # ── sagas -> stateDiagram-v2 ─────────────────────────────────────

      # A SAGA HAS A LIFECYCLE TOO — the same `stateDiagram-v2` shape
      # `lifecycle_diagram` already draws, one file per process_manager
      # the same way lifecycle is one file per lifecycle-bearing holder.
      # What's different is the label: a lifecycle's own edge is labeled
      # by the COMMAND that causes it (an aggregate transitions because
      # something was DONE to it); a saga's edge is labeled by the EVENT
      # that causes it (a saga advances because something HAPPENED,
      # possibly nowhere near the saga itself) — the same command/event
      # split `dispatch.mmd`'s own stadium/hexagon vocabulary already
      # draws, here spent on which noun labels a stateDiagram-v2 edge
      # instead.
      #
      # THE LABEL ALSO NAMES WHAT THE TRANSITION DISPATCHES — a fact no
      # existing diagram states for a saga at all: a lifecycle's own
      # edge only ever names the one command that caused it; a saga's
      # edge can fire several commands at once (real in banking:
      # Settlement's own AccountDebited handler dispatches both
      # Transfer.Debited and Account.Credit). Confirmed real in the
      # corpus: no saga dispatch ever declares a `to:`/`target_domain`
      # of its own (unlike a policy's `across`) — every command a saga
      # fires lands inside its own bluebook chapter, so this never needs
      # `dispatch.mmd`'s own "triggers in X" cross-domain label.
      #
      # THE COMPENSATING LEG READS LIKE ANY OTHER — its own trigger is
      # the literal string "refused" (`ProcessManager::REFUSED`, this
      # language's own Trigger vocabulary), not invented text: a
      # dispatch declined is exactly as real a cause of a state
      # transition as an event announced, and the diagram states it
      # exactly as verbatim as every other edge here does.
      def saga_diagram(bluebook, saga)
        edges = saga.handlers.map { |handler| saga_edge(handler, saga) }

        subject = "#{saga.hecks_name}'s own declared states and what each transition dispatches " \
                  "(starts on #{saga.starts_on}, ends on #{saga.ends_on})"
        <<~MERMAID
          #{header(bluebook.name, subject)}stateDiagram-v2
              [*] --> #{saga.states.first}
          #{edges.join("\n")}
        MERMAID
      end

      # THE REFUSED EDGE'S OWN DISPATCH LIST IS PARTLY DERIVED NOW —
      # per-dispatch saga compensation (`compensates`) moved a saga's own
      # compensating dispatches OFF the hand-written `on :refused` leg
      # and onto whichever forward dispatch each one undoes, so
      # `handler.dispatches` alone would render an EMPTY compensating
      # edge for any saga using it — accurate to the DECLARATION, wrong
      # about what the runtime actually does at refusal (it derives and
      # fires every declared `compensates`, newest first). `saga` is
      # passed through for exactly this — only the REFUSED handler needs
      # it, every other edge's own `handler.dispatches` already says
      # everything real about it.
      def saga_edge(handler, saga)
        label = handler.event_type
        # DERIVED FIRST, then the hand-written body — the same order
        # `SagaInterpreter#unwind` actually runs them in (every
        # completed leg's own `compensates` before this leg's own
        # hand-written dispatches), not declaration order on the page.
        dispatched = handler.event_type == Bluebook::ProcessManager::REFUSED ? derived_compensations(saga) : []
        dispatched += handler.dispatches.map(&:command_name)
        label += " / dispatches #{dispatched.join(', ')}" unless dispatched.empty?

        "    #{handler.from_state} --> #{handler.to_state}: #{label}"
      end

      # Every `compensates` any forward dispatch in this saga declares,
      # declaration order — the same commands `SagaInterpreter#unwind`
      # derives and fires (newest-first, at actual refusal time; this
      # diagram states them in declaration order, since it draws the
      # saga's own shape, not one instance's own runtime history).
      def derived_compensations(saga)
        saga.handlers.flat_map { |handler| handler.dispatches.filter_map { |dispatch| dispatch.compensates&.command_name } }
      end

      # ── frameworks -> flowchart ─────────────────────────────────────

      # EVERY OTHER DIAGRAM IN THIS FILE STAYS INSIDE ONE DOMAIN'S OWN
      # BOUNDARY — this is the one that steps outside it. A real domain
      # depends on another domain's own aggregates in exactly two ways:
      # `uses_framework "X"` in its `.hecksagon` (`Hecksagon#framework_
      # members`), which loads X's whole bluebook into THIS registry,
      # unconditionally, the moment this domain boots; or a policy's own
      # `across "X"` (`Policy#target_domain`), which only reaches X when
      # the policy's declared event actually fires. Same underlying
      # fact `dispatch.mmd`'s own `trigger_edge` already draws from the
      # command's side ("triggers in X") — this draws it again from the
      # DOMAIN's side, next to the structural `uses_framework` fact
      # `dispatch.mmd` never sees at all (that lives in the `.hecksagon`,
      # which no other diagram here is handed).
      #
      # NEITHER THIS DOMAIN NOR EACH DEPENDENCY GETS THE holders() TREATMENT
      # — a whole domain is drawn as ONE cylinder, the same "a bounded,
      # addressable thing" shape every other diagram here already spends
      # on a single aggregate, just scaled up one level: a domain is a
      # bigger box the same kind of box lives inside.
      #
      # DOTTED FOR `attaches`, SOLID FOR `reaches across` — the reverse
      # of which fact is "always true" between the two: attaching a
      # framework is a standing declaration, true every time this domain
      # boots, so it gets the same dotted "this always belongs" treatment
      # `ports.mmd` gives an aggregate's own `-.->|exposes|` edge.
      # Reaching across only happens when a real policy actually fires —
      # the same solid edge `dispatch.mmd`'s own `trigger_edge` already
      # draws for the identical fact, kept solid here so the same
      # relationship reads the same way in both diagrams.
      #
      # `options[:hecksagon]` IS THE ONE DIAGRAM IN THIS FILE THAT NEEDS
      # MORE THAN `bluebook` — `framework_members` lives on the
      # `Hecksagon`, a sibling IR object `bin/project_diagrams` already
      # has in hand (`registry.hecksagon(chapter_name)`) but `bluebook`
      # itself carries no reference to. No hecksagon handed in (an older
      # caller, or a spec that doesn't care) just means no frameworks.mmd
      # — same "nothing to state" skip every other diagram here already
      # takes when its own underlying data is empty.
      def frameworks_diagram(bluebook, hecksagon)
        return nil unless hecksagon

        lines = hecksagon.framework_members.map { |name| domain_edge(bluebook.name, "attaches", name, dotted: true) }
        lines += bluebook.policies.filter_map(&:target_domain).uniq
                         .map { |name| domain_edge(bluebook.name, "reaches across", name, dotted: false) }
        return nil if lines.empty?

        subject = "#{bluebook.name}'s own declared uses_framework and cross-domain policy targets"
        "#{header(bluebook.name, subject)}flowchart LR\n#{lines.uniq.join("\n")}\n"
      end

      def domain_edge(from, label, to, dotted:)
        arrow = dotted ? "-.->" : "-->"
        %(    #{from}[(#{from})] #{arrow}|#{label}| #{to}[(#{to})])
      end
    end
  end
end
