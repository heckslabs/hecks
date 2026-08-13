require_relative "lambda/client"
require_relative "../../ports/query/in_memory"
require_relative "../../ports/persistence/remote_runtime"
require_relative "in_memory_ordering"
require_relative "../../runtime/instance"

module Hecksagain
  module Adapters
    # THE READ-SIDE HALF OF LAMBDA ROUTING — `persisted_by("Lambda")`'s
    # own adapter, resolved through the SAME `Ports::Persistence`
    # machinery `persisted_by("Postgres")`/`persisted_by("Memory")`
    # already use (`Runtime::Registry#repository`, `RepositoryFactory
    # .build`) — no new framework plumbing, just a new adapter class at
    # the name the existing lookup already expects. See
    # `Runtime::RemoteDispatcher` for the write-side half; the two
    # compose through one shared `Client` per domain rather than each
    # inventing its own AWS wiring.
    #
    # READ-ONLY, DELIBERATELY — `append`/`project` raise rather than
    # silently no-op. A write reaching this class would mean
    # `Runtime::CommandInterpreter` ran locally against a Lambda-routed
    # domain, which is exactly the bypass `Runtime::RemoteDispatcher`
    # exists to prevent (business-rule validation must happen in Rust
    # for these domains, not be pre-computed here against an
    # incomplete local view). A loud failure here is the correct
    # outcome, not a bug to route around.
    class Lambda
      include Ports::Persistence::RemoteRuntime

      attr_reader :aggregate

      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate
        domain = settings[:domain] || settings["domain"] || aggregate.name
        region = settings[:region] || settings["region"] || "us-east-1"
        # TWO DIFFERENT "domain"s, deliberately not conflated: `domain`
        # (this aggregate's OWN bluebook name — "Identity", "Governance")
        # only ever prefixes the instances lookup, since that's how
        # rust/host's own `Store::instances()` keys every record
        # (`registry.rb`'s own `"#{a[:domain_name]}::#{a[:name]}#"`
        # dump format, unchanged by which chapter attached it). The
        # FUNCTION to actually call is a different question: Governance
        # and Identity aggregates are compiled into the ATTACHING
        # domain's own Lambda (one merged `Store` per target — Phase 0's
        # framework-bluebook work), never a function of their own, so
        # `settings[:domain]` is the wrong signal for `Client.new`.
        # `root` is the boot's own directory (`Registry#root`, shared by
        # EVERY bluebook in one registry regardless of which one
        # attached it) — `File.basename(root)` reproduces the exact
        # same string `bin/project_deploy`'s own `stack_name` computes
        # from the domain PATH, so the two can never name two
        # different functions for the same deploy... on a LOCAL boot,
        # where `root` is a real project directory. Inside the deployed
        # Lambda itself `root` is ALWAYS `/var/task` (every Lambda's own
        # fixed code root, regardless of domain) — `File.basename` gives
        # "task", not the domain name, and invokes the wrong function
        # entirely. A real, live AccessDeniedException on
        # "hecksagain-task" caught this: invisible through every earlier
        # phase's own verify step, all run from a local boot, until
        # WebFunction became the first Ruby process to EVER make this
        # exact call from inside a deployed Lambda. `DOMAIN_NAME` (set
        # by bin/project_deploy's own WebFunction Environment) is the
        # real, unambiguous signal in that specific context; the
        # root-basename heuristic stays as the local-boot fallback,
        # unchanged.
        function_domain = ENV["DOMAIN_NAME"] || (root ? File.basename(root) : domain)
        @client = Client.new(domain: function_domain, region: region)
        @prefix = "#{domain}::#{aggregate.hecks_name}#"
      end

      def find(id)
        instances[id.to_s]
      end

      def all(order_by: nil, direction: :asc)
        InMemoryOrdering.ordered(instances.values, aggregate: @aggregate, order_by: order_by, direction: direction)
      end

      def count = instances.size

      def query(specification, args = {}, context: {})
        Ports::Query::InMemory.execute(instances.values, specification, args)
      end

      # `entries`/`append`/`project` — the append-only contract
      # `Ports::Persistence::AppendOnly` requires of every adapter
      # (raises at construction if any are missing). Answered by
      # `Ports::Persistence::RemoteRuntime`, included above: `entries` is
      # `[]` unconditionally (Lambda's own Postgres is already the
      # durable store — rust/host's rehydrate-and-replay journal, Phase
      # 1 — there is no local write-ahead log for `recover!` to replay),
      # `append`/`project` raise rather than silently no-op.

      private

      # RE-FETCHED EVERY CALL, deliberately NOT memoized across them —
      # this adapter itself is long-lived (one instance per aggregate,
      # held by the registry `RUNTIME = Hecks.boot(...)` builds ONCE
      # per Lambda web process — WebFunction's own top-level constant,
      # reused warm across every HTTP request that process serves, not
      # rebuilt per request the way a memoize-for-one-request comment
      # here used to assume). A real, live bug caught this: a mutation
      # dispatched fine (RemoteDispatcher always calls the dispatch
      # Lambda fresh) and the very next `.all` on the SAME warm
      # container kept returning the state from BEFORE that mutation,
      # forever, until the container cold-started — memoizing here
      # made every write invisible to every read on a warm container.
      # Keyed by bare id (the part after "Domain::Aggregate#"), not the
      # full "Domain::Aggregate#id" string — callers already know which
      # aggregate they're asking this instance about.
      def instances
        @client.read.fetch("instances", {}).filter_map { |key, state|
          next unless key.start_with?(@prefix)

          [key.delete_prefix(@prefix), build_instance(key.delete_prefix(@prefix), state)]
        }.to_h
      end

      # Lambda's own JSON response is already Ruby-decoded with STRING
      # keys (plain `JSON.parse`, no `symbolize_names:`) — every other
      # adapter's own `instance(row)` builder (Postgres, Sqlite) hands
      # `Runtime::Instance.new` a SYMBOL-keyed state hash instead. A
      # round trip through `JSON.generate`/`JSON.parse` is simpler and
      # safer than a hand-rolled deep-symbolize helper for what is not
      # a hot path.
      def build_instance(id, state)
        Runtime::Instance.new(aggregate: @aggregate, id: id, state: JSON.parse(JSON.generate(state), symbolize_names: true))
      end
    end
  end
end
