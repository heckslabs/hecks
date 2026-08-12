require_relative "synthesizer"
require "tmpdir"
require "fileutils"

module Hecksagain
  class Bluebook
    # BOOTS A REAL BLUEBOOK AND ACTUALLY DISPATCHES AGAINST IT — the
    # sibling `bin/model_check` never had: that tool proves a bluebook
    # is STRUCTURALLY sound (no dead states, no unreachable transitions)
    # without ever running a single command; this proves it WORKS,
    # catching exactly the class of bug static analysis structurally
    # cannot see. Built and proved inside `bin/interview`'s own `smoke`
    # command, where it first found two real bugs — a lifecycle field
    # colliding with an explicit attribute, and a non-creating command
    # missing `Command.ActsOn` — that reloaded clean, checked clean,
    # and only broke once something actually dispatched against them.
    #
    # SYNTHESIZED ARGS, NEVER RANDOM (`Synthesizer`) — a String becomes
    # a fixed marker, a closed set uses its own first admitted member, a
    # reference reuses whatever this same run already minted for that
    # target. ONE call per declared command, ONE call per declared
    # report, per created root; every failure is collected and reported
    # together rather than stopping at the first.
    #
    # WHAT THIS CANNOT CATCH: a call that dispatches cleanly but answers
    # WRONG — the read-model join bug this exact tool's own first user
    # hit is the textbook case, a query that silently returned an empty
    # array rather than raising. Smoke-testing proves nothing crashes;
    # it does not prove the answer is the right one.
    #
    # A FAILURE HERE IS NOT NECESSARILY A DOMAIN BUG, either — it may
    # just be `Synthesizer`'s own naive values (0, an empty list,
    # "smoke-test") not satisfying a real invariant this simple
    # generator was never built to reason about (a positive amount, a
    # non-empty topping list, an email pattern). Confirmed against
    # Banking and Pizzas: both real domains, both showing exactly that
    # class of failure, neither one an actual bug. Building a
    # synthesizer that respects arbitrary declared invariants is real
    # constraint-aware generation — a separate, larger tool than this.
    module SmokeTest
      Failure = Struct.new(:domain, :aggregate, :command, :error, keyword_init: true) do
        def to_s = "#{domain}::#{aggregate}.#{command}: #{error}"
      end

      module_function

      # `dir` is any real, bootable hecksagain app directory — a saved
      # domain, or a throwaway one a caller rendered into a temp dir
      # for exactly this purpose. Plain `Hecksagain.boot`, not
      # `Router.boot` — proven all night, and it works against a
      # domain with framework-attached chapters (`uses_framework
      # "Governance"`, say) that `Router.boot` refuses outright: those
      # chapters carry no `.world` of their own, which `Router`'s
      # per-domain realm resolution requires and a plain boot never
      # did. Reports are reachable the identical way regardless of
      # boot path — `dispatcher.query("Domain.report_name", **args)`
      # is the SAME `Dispatcher#query` either boot hands back; Router
      # was never actually required for this, only its OWN namespace
      # SUGAR (`Domain.report_name(...)` as a bare method call) was.
      #
      # NEVER BOOTS `dir`'S OWN REAL BINDINGS — measured, not a
      # precaution taken on spec: pointed at `examples/pizzas` (a real,
      # persistent store carrying real accumulated records), a
      # synthesized `CreatePizza` collided with an actual pre-existing
      # record literally named "smoke-test" — a coincidence this time,
      # data pollution the next. `isolate!` copies only the `.bluebook`
      # (and `.world`, for its realm) into a throwaway directory and
      # deliberately leaves the real `.hecksagon` behind — with none
      # present, `Ports::Persistence::BindingPolicy.default_binding`
      # binds every aggregate to Memory on its own, no settings needed.
      # Whatever `dir` is really bound to in production is never
      # touched.
      # `install_facade: false` — this only ever dispatches by FQN string
      # (below), so it never needs the `Widget::Item.Add(...)` Ruby
      # sugar `Hecksagain.boot` installs by default. Skipping it matters
      # here specifically: that sugar lands as a BARE global constant on
      # `Object` per domain and per aggregate name, with no scoping and
      # no cleanup — and this tool boots throwaway domains under
      # whatever generic names the caller's `.bluebook` happens to use
      # ("Widget", "Item", "Tag" in this tool's own specs). Installing
      # the facade would leak those names into the rest of the process —
      # measured, not hypothetical: it once left a stale `Widget` constant
      # that corrupted an unrelated spec's own unrelated use of the same
      # bare name.
      def call(dir)
        Dir.mktmpdir("hecksagain-smoke-") do |scratch|
          isolate!(dir, scratch)
          dispatcher = Hecksagain.boot(scratch, install_facade: false)
          domain     = dispatcher.registry.bluebooks.keys.first
          next [] unless domain

          smoke_domain(dispatcher, domain)
        end
      end

      # ONLY THE `.bluebook`, NEVER `.world` EITHER — a real world's own
      # settings (`persisted_by("Heki") { dir "..." }`) are keyed to the
      # REAL adapter it names, not to Memory; copied verbatim, they
      # apply to the wrong binding and refuse with a `WiringError`
      # ("Memory does not declare :dir") — measured, not assumed, the
      # first time this ran against Banking. A plain `Hecksagain.boot`
      # needs no realm to address anything (unlike `Router.boot`), so
      # leaving the world out entirely is the correct minimal isolation,
      # not a workaround. `translations/*.bluebook` also deliberately
      # excluded — those are earlier, superseded versions of the same
      # domain; smoke-testing the current declaration is the point, not
      # its whole history.
      def isolate!(dir, scratch)
        source = Adapters::Folder.new.bluebook_directory(dir)
        target = File.join(scratch, "bluebook")
        FileUtils.mkdir_p(target)
        Dir.glob(File.join(source, "*.bluebook")).each { |file| FileUtils.cp(file, target) }
      end

      # AGGREGATES WALKED IN DECLARATION ORDER, on purpose — so whatever
      # a LATER aggregate's own shape needs from an EARLIER one (a
      # `TripItem` needing a real `PackingItem`, say) already exists by
      # the time that aggregate's own turn comes, the same reason
      # `Synthesizer#args_for`'s `created` map is threaded through in
      # this same order.
      def smoke_domain(dispatcher, domain)
        chapter = dispatcher.registry.bluebook(domain)
        return [] unless chapter

        created  = {}
        failures = []

        chapter.aggregates.each do |aggregate|
          creating, noncreating = aggregate.commands.partition(&:creates?)

          creating.each do |command|
            args = Synthesizer.args_for(chapter, aggregate, command, created)
            begin
              result = dispatcher.dispatch("#{domain}::#{aggregate.name}.#{command.hecks_name}", **args)
              created[aggregate.name] = result.instance.id
            rescue StandardError => e
              failures << Failure.new(domain: domain, aggregate: aggregate.name, command: command.hecks_name,
                                       error: "#{e.class}: #{e.message}")
              next
            end

            noncreating.each do |nc_command|
              nc_args = Synthesizer.args_for(chapter, aggregate, nc_command, created).merge(id: created[aggregate.name])
              dispatcher.dispatch("#{domain}::#{aggregate.name}.#{nc_command.hecks_name}", **nc_args)
            rescue StandardError => e
              failures << Failure.new(domain: domain, aggregate: aggregate.name, command: nc_command.hecks_name,
                                       error: "#{e.class}: #{e.message}")
            end
          end
        end

        chapter.read_models.each do |model|
          root_id = created[model.reference_target]
          next unless root_id # nothing was created for this root — nothing to smoke-test yet, not a failure

          dispatcher.query("#{domain}.#{model.query_name}", model.reference_name => root_id)
        rescue StandardError => e
          failures << Failure.new(domain: domain, aggregate: model.name, command: "report(#{model.name})",
                                   error: "#{e.class}: #{e.message}")
        end

        failures
      end
    end
  end
end
