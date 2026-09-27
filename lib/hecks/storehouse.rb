require "json"
require "fileutils"
require "time"
require_relative "cache_dir"
require_relative "facade/command_request"
require_relative "facade/json_door"
require_relative "naming"
require_relative "projector"
require_relative "runtime/errors"

module Hecks
  # Dispatch/query/state and introspection over one booted domain, pure
  # beyond its own JSONL audit log — booting stays the caller's job.
  module Storehouse
    module_function

    # Optional on dispatch/query; omitted, source is recorded as nil rather
    # than guessed.
    SOURCE_TAGS = %w[process-manager operator hook sidequest-agent cascade daemon].freeze

    # Kept under Hecks::CacheDir, not the domain directory (part of the domain's
    # own state) or the gem directory (read-only once installed).
    # :nodoc:
    def log_root = Hecks::CacheDir.path("storehouse")

    # The root every domain path resolves under; HECKS_STOREHOUSE_ROOT widens it.
    # Hecks.boot Kernel.loads Ruby files here, so an unconfined path is
    # arbitrary code execution, not just a wrong-directory mistake.
    BOOT_ROOT = File.expand_path(ENV["HECKS_STOREHOUSE_ROOT"] || File.expand_path("../..", __dir__))

    # Refuses a path outside BOOT_ROOT rather than silently clamping it — a
    # stray relative path and a deliberate escape both deserve a clear refusal.
    # :nodoc:
    def confine!(path, label)
      resolved = File.expand_path(path.to_s, BOOT_ROOT)
      return resolved if resolved == BOOT_ROOT || resolved.start_with?("#{BOOT_ROOT}#{File::SEPARATOR}")

      raise Runtime::TypeMismatch,
            "#{label}: #{path.inspect} resolves outside #{BOOT_ROOT} — this bus only boots domains under its " \
            "own root (HECKS_STOREHOUSE_ROOT to widen it)"
    end

    # The one bluebook this runtime booted; every whole-domain door assumes
    # the same one-bluebook-per-boot shape.
    # :nodoc:
    def bluebook_for(runtime)
      runtime.registry.bluebooks.values.first or
        raise Runtime::NotFound, "this boot loaded no bluebook"
    end

    # :nodoc:
    def aggregate_ir!(bluebook, name)
      bluebook.aggregate(name) or
        raise Runtime::NotFound, "#{bluebook.name} declares no aggregate named #{name.inspect} — " \
                                 "known: #{bluebook.aggregates.map(&:hecks_name).sort.join(', ')}"
    end

    # The same alias table CliRunner resolves against, kept here so dispatch
    # and query never drift from what a human typing bin/run sees.
    # :nodoc:
    def resolve!(cli, name, asking:)
      pool = asking ? cli[:questions] : cli[:verbs]
      key  = cli[:names][asking ? :question : :command][name]
      spec = pool[key]
      return spec if spec

      known = cli[:names][asking ? :question : :command].keys.sort.join(", ")
      raise Runtime::NotFound, "no such #{asking ? 'query' : 'command'}: #{name.inspect} — known: #{known}"
    end

    # Required on dispatch/query/state: what makes an audit row legible later.
    # :nodoc:
    def require_summary!(summary)
      return unless summary.nil? || summary.to_s.strip.empty?

      raise Runtime::TypeMismatch,
            "a one-line summary: is required on dispatch/query/state — it is what makes an audit row legible later"
    end

    # :nodoc:
    def valid_source!(source)
      return if source.nil? || SOURCE_TAGS.include?(source.to_s)

      raise Runtime::TypeMismatch, "source: #{source.inspect} is not one of #{SOURCE_TAGS.join(', ')}"
    end

    # actor_id without role would silently bind nothing rather than a real
    # caller — refusing here beats a caller thinking it identified itself.
    # :nodoc:
    def valid_caller!(role, actor_id)
      return unless actor_id && role.nil?

      raise Runtime::TypeMismatch, "actor_id: requires role: too — a caller names WHO through WHICH role they hold"
    end

    # Binds role/actor_id for the block's duration via Hecks.as_caller; role: nil
    # runs the block unbound (query's own authorization does not depend on it).
    # :nodoc:
    def with_caller(role, actor_id, &block)
      return block.call if role.nil?

      Hecks.as_caller(role: role, actor_id: actor_id, &block)
    end

    # A caller who omits role: would otherwise reach a role-gated command
    # unchecked (refuse_role_mismatch no-ops with no bound caller) — refuse here instead.
    # :nodoc:
    def require_caller_for_role_gated!(spec, role)
      return unless spec[:role_gated] && role.nil?

      raise Runtime::Unauthorized,
            "#{spec[:verb]} requires role: #{spec[:role].inspect} — this command is role-gated and no caller " \
            "(role:/actor_id:) is bound; dispatching it unbound is refused, not silently unchecked"
    end

    # dry_run? (Runtime::Dispatcher) only understands the pre-envelope flat
    # args shape; this is the one door back into it from dispatch's own envelope.
    # :nodoc:
    def flatten_legacy(envelope, receiver, legacy_receiver)
      facts = envelope[:with] || {}
      return facts unless envelope.key?(:to)

      route = envelope[:to]
      case receiver
      when :aggregate then facts.merge(legacy_receiver.to_sym => route)
      when :entity
        facts.merge(legacy_receiver.fetch(:aggregate).to_sym => route[:aggregate],
                    legacy_receiver.fetch(:entity).to_sym    => route[:entity])
      else facts
      end
    end

    # :nodoc:
    def log_path(domain_name)
      File.join(log_root, "#{domain_name.to_s.gsub(/[^A-Za-z0-9_-]/, '_')}.jsonl")
    end

    # Never fails a real call because its own audit log couldn't be written —
    # a full disk silences follow, not the dispatch/query/state call itself.
    # :nodoc:
    def record!(domain_name, tool:, summary:, source:, outcome:, verb: nil, role: nil, actor_id: nil)
      return unless domain_name

      entry = { time: Time.now.utc.iso8601, tool: tool, verb: verb, summary: summary, source: source,
                role: role, actor_id: actor_id,
                ok: outcome[:ok], id: outcome[:id], error: outcome[:error], events: outcome[:events] }.compact
      FileUtils.mkdir_p(log_root)
      File.open(log_path(domain_name), "a") { |f| f.puts(JSON.generate(entry)) }
    rescue StandardError
      nil
    end

    # Issues a command, or previews it with dry_run: true.
    #
    # @param runtime [Runtime::Registry] the booted domain to dispatch against
    # @param command [String, Symbol] the command name, bare or qualified
    # @param summary [String] a one-line audit summary; required
    # @param args [Hash] the command's arguments, JSON-shaped
    # @param source [String, Symbol, nil] a SOURCE_TAGS tag naming who is calling
    # @param dry_run [Boolean] true previews; a false would_succeed is not a failure
    # @param role [String, Symbol, nil] the caller's bound role, or nil to run unbound
    # @param actor_id [String, nil] the caller's identity; requires role:
    # @return [Hash] :ok plus :id/:state/:events (real) or :would_succeed/:error
    #   (dry run); or the refused shape
    def dispatch(runtime:, command:, summary:, args: {}, source: nil, dry_run: false, role: nil, actor_id: nil)
      bluebook = bluebook_for(runtime)
      tool     = dry_run ? "dry_run" : "dispatch"
      outcome  = perform_dispatch(runtime, bluebook, command, summary, args, source, dry_run, role, actor_id)

      record!(bluebook.name, tool: tool, verb: outcome[:verb], summary: summary, source: source,
              outcome: outcome, role: role, actor_id: actor_id)
      outcome.except(:verb)
    rescue *refusal_classes => e
      outcome = refused(e, summary: summary)
      record!(bluebook&.name, tool: tool, summary: summary, source: source, outcome: outcome,
              role: role, actor_id: actor_id)
      outcome
    end

    # :nodoc:
    def perform_dispatch(runtime, bluebook, command, summary, args, source, dry_run, role, actor_id)
      require_summary!(summary)
      valid_source!(source)
      valid_caller!(role, actor_id)
      cli      = Projector.call(:cli, bluebook: bluebook, options: { program: "mcp" })
      spec     = resolve!(cli, command, asking: false)
      require_caller_for_role_gated!(spec, role)
      envelope = Facade::CommandRequest.normalize(Facade::JsonDoor.deep_symbolize(args),
                                                  receiver:        spec[:receiver],
                                                  legacy_receiver: spec[:legacy_receiver])

      result = with_caller(role, actor_id) do
        dry_run ? dry_run_outcome(runtime, spec, envelope, summary: summary) : real_dispatch(runtime, spec, envelope, summary)
      end
      result.merge(verb: spec[:verb])
    end

    # :nodoc:
    def real_dispatch(runtime, spec, envelope, summary)
      result = runtime.dispatch_flat(spec[:verb], envelope)
      ok(summary: summary,
         id:      result.id,
         state:   result.state.nil? ? nil : Facade::JsonDoor.materialize(result.state),
         events:  result.events.map { |event| { name: event.name, payload: Facade::JsonDoor.materialize(event.payload) } })
    end

    # :nodoc:
    def dry_run_outcome(runtime, spec, envelope, summary:)
      flat = flatten_legacy(envelope, spec[:receiver], spec[:legacy_receiver])
      runtime.dry_run?(spec[:verb], **flat)
      ok(summary: summary, would_succeed: true)
    rescue Runtime::WiringError, *Runtime::DOMAIN_REFUSALS => e
      ok(summary: summary, would_succeed: false, error: e.message)
    end

    # Dispatches a sequence of commands as one call, through dispatch itself —
    # same audit log line per step. Runs every step even after an earlier one
    # refuses, since a later step naming a since-refused record will refuse
    # honestly on its own account.
    #
    # @param runtime [Runtime::Registry] the booted domain to dispatch against
    # @param steps [Array<Hash>] each step's command/args, JSON-shaped
    # @param summary [String] a one-line audit summary; required
    # @param source [String, Symbol, nil] a SOURCE_TAGS tag naming who is calling
    # @param role [String, Symbol, nil] the caller's bound role, or nil to run unbound
    # @param actor_id [String, nil] the caller's identity; requires role:
    # @return [Hash] :ok (true only if every step's own :ok was true), :results
    def dispatch_batch(runtime:, steps:, summary:, source: nil, role: nil, actor_id: nil)
      require_summary!(summary)
      results = Array(steps).map do |raw|
        step = Facade::JsonDoor.deep_symbolize(raw)
        dispatch(runtime: runtime, command: step[:command], args: step[:args] || {},
                 summary: summary, source: source, role: role, actor_id: actor_id)
      end
      { ok: results.all? { |r| r[:ok] }, summary: summary, results: results }
    rescue *refusal_classes => e
      refused(e, summary: summary)
    end

    # Answers one declared query.
    #
    # @param runtime [Runtime::Registry] the booted domain to query
    # @param question [String, Symbol] the query name, bare or qualified
    # @param summary [String] a one-line audit summary; required
    # @param args [Hash] the query's arguments, JSON-shaped
    # @param source [String, Symbol, nil] a SOURCE_TAGS tag naming who is calling
    # @param role [String, Symbol, nil] the caller's bound role, or nil to run unbound
    # @param actor_id [String, nil] the caller's identity; requires role:
    # @return [Hash] :ok and :rows (each JSON-safe); or the refused shape
    def query(runtime:, question:, summary:, args: {}, source: nil, role: nil, actor_id: nil)
      bluebook = bluebook_for(runtime)
      outcome  = perform_query(bluebook, runtime, question, summary, args, source, role, actor_id)

      record!(bluebook.name, tool: "query", verb: outcome[:verb], summary: summary, source: source,
              outcome: outcome, role: role, actor_id: actor_id)
      outcome.except(:verb)
    rescue *refusal_classes => e
      outcome = refused(e, summary: summary)
      record!(bluebook&.name, tool: "query", summary: summary, source: source, outcome: outcome,
              role: role, actor_id: actor_id)
      outcome
    end

    # :nodoc:
    def perform_query(bluebook, runtime, question, summary, args, source, role, actor_id)
      require_summary!(summary)
      valid_source!(source)
      valid_caller!(role, actor_id)
      cli  = Projector.call(:cli, bluebook: bluebook, options: { program: "mcp" })
      spec = resolve!(cli, question, asking: true)
      rows = with_caller(role, actor_id) { runtime.query(spec[:verb], **Facade::JsonDoor.deep_symbolize(args)) }

      ok(summary: summary, rows: rows.map { |row| Facade::JsonDoor.materialize(row) }).merge(verb: spec[:verb])
    end

    # Reads one aggregate's stored records directly, bypassing any declared
    # query — id: answers one record, omitted answers every record.
    #
    # @param runtime [Runtime::Registry] the booted domain to read
    # @param aggregate [String, Symbol] the aggregate's declared name
    # @param summary [String] a one-line audit summary; required
    # @param id [String, Object, nil] one record's identity, or nil for every record
    # @param source [String, Symbol, nil] a SOURCE_TAGS tag naming who is calling
    # @return [Hash] :ok and, with id:, :record; without it, :count/:records; or refused
    def state(runtime:, aggregate:, summary:, id: nil, source: nil)
      bluebook = bluebook_for(runtime)
      outcome  = perform_state(runtime, bluebook, aggregate, summary, id)

      record!(bluebook.name, tool: "state", summary: summary, source: source, outcome: outcome)
      outcome
    rescue *refusal_classes => e
      outcome = refused(e, summary: summary)
      record!(bluebook&.name, tool: "state", summary: summary, source: source, outcome: outcome)
      outcome
    end

    # :nodoc:
    def perform_state(runtime, bluebook, aggregate, summary, id)
      require_summary!(summary)
      ir         = aggregate_ir!(bluebook, aggregate)
      repository = runtime.registry.repository(bluebook.name, ir)

      if id
        instance = repository.find(id) or
          raise Runtime::NotFound, "no #{ir.hecks_name} found for id #{id.inspect}"
        ok(summary: summary, record: Facade::JsonDoor.materialize(instance.to_h))
      else
        records = repository.all.map { |instance| Facade::JsonDoor.materialize(instance.to_h) }
        ok(summary: summary, count: records.length, records: records)
      end
    end

    # Lists every domain directory found under a root (discovered, not typed).
    #
    # @param under [String] the directory to search, relative to BOOT_ROOT
    # @return [Hash] :ok, :under, :domains (each path relative to BOOT_ROOT,
    #   sorted); :domains is [] when under does not exist
    # @raise [Runtime::TypeMismatch] if under resolves outside BOOT_ROOT
    def domains(under: "examples")
      root = confine!(under, "under")
      return ok(under: under, domains: []) unless Dir.exist?(root)

      folder = Adapters::Folder.new
      found  = Dir.children(root).sort.select { |name| folder.domain?(File.join(root, name)) }

      ok(under: under, domains: found.map { |name| File.join(under, name) })
    end

    # Lists a domain's aggregates and their command/query names, snake_cased
    # exactly as dispatch/query want them.
    #
    # @param runtime [Runtime::Registry] the booted domain to describe
    # @return [Hash] :ok, :domain, :aggregates (each {name:, commands:, queries:},
    #   command names suffixed !); or the refused shape
    def catalog(runtime:)
      bluebook = bluebook_for(runtime)

      ok(domain:     bluebook.name,
         aggregates: bluebook.aggregates.map do |aggregate|
           { name:     aggregate.hecks_name,
             commands: aggregate.commands.map { |c| "#{Naming.snake(c.hecks_name)}!" }.sort,
             queries:  aggregate.queries.map { |q| Naming.snake(q.hecks_name) }.sort }
         end)
    rescue *refusal_classes => e
      refused(e)
    end

    # One aggregate's (or the whole chapter's) full usage documentation — the
    # same document bin/docs renders for a human.
    #
    # @param runtime [Runtime::Registry] the booted domain to describe
    # @param aggregate [String, Symbol, nil] one aggregate's name, or nil for the
    #   whole chapter
    # @return [Hash] :ok, :domain, :docs; or the refused shape
    # @raise [Runtime::NotFound] if aggregate names no known aggregate
    def describe(runtime:, aggregate: nil)
      bluebook = bluebook_for(runtime)
      options  = aggregate ? { aggregate: aggregate_ir!(bluebook, aggregate).hecks_name } : {}

      ok(domain: bluebook.name, docs: Projector.call(:docs, bluebook: bluebook, options: options))
    rescue *refusal_classes => e
      refused(e)
    end

    # Boots a domain and reports whether its wiring is sound; deep: true also
    # runs Bluebook::ModelCheck past wiring, into logic. Boots for itself,
    # unlike every other tool here, since a domain that failed to boot has
    # no runtime to hand in — any boot failure answers the question, not just
    # WiringError.
    #
    # @param domain [String] the domain's directory path, relative to BOOT_ROOT
    # @param deep [Boolean] also run Bluebook::ModelCheck past wiring, into logic
    # @return [Hash] {ok: true, domain:, valid: true} plus :findings when deep;
    #   {ok: false, domain:, valid: false, error:} if the boot itself failed
    def validate(domain:, deep: false)
      runtime = Hecks.boot(confine!(domain, "domain"), install_facade: false)
      result  = { ok: true, domain: domain, valid: true }

      if deep
        require_relative "bluebook/model_check"
        findings = runtime.registry.bluebooks.values.flat_map { |bluebook| Bluebook::ModelCheck.call(bluebook) }
        result[:findings] = findings.map { |f| { kind: f.kind, severity: f.severity, subject: f.subject, message: f.message } }
      end

      result
    rescue StandardError => e
      { ok: false, domain: domain, valid: false, error: "#{e.class}: #{e.message}" }
    end

    # The full write history, not just the current head — every operation that
    # ever touched each aggregate, off its repository's own append-only entries.
    #
    # @param runtime [Runtime::Registry] the booted domain to read
    # @return [Hash] :ok, :domain, :history (each aggregate's storage name
    #   mapped to its journal_entries); or the refused shape
    def history(runtime:)
      bluebook = bluebook_for(runtime)
      entries  = bluebook.aggregates.each_with_object({}) do |aggregate, all|
        repository = runtime.registry.repository(bluebook.name, aggregate)
        all[aggregate.storage_name] = journal_entries(repository)
      end

      ok(domain: bluebook.name, history: entries)
    rescue *refusal_classes => e
      refused(e)
    end

    # :nodoc:
    def journal_entries(repository)
      repository.entries.map { |entry| { operation: entry.operation, id: entry.id, state: Facade::JsonDoor.materialize(entry.state) } }
    end

    # Runs a domain's hand-curated .behaviors examples and reports the results.
    #
    # @param target [String] a .behaviors file's path, or a directory to sweep
    # @return [Hash] :ok, :target, :files (each file's behaviors_file shape),
    #   :counts; or the refused shape
    # @raise [Runtime::NotFound] if target is nil or names no real file or directory
    def behaviors(target:)
      require_relative "behaviors"
      raise Runtime::NotFound, "no such file or directory: #{target.inspect}" unless target && File.exist?(target)

      if File.directory?(target)
        sweep = Hecks::Behaviors.run_all(target)
        ok(target: target, files: sweep.files.map { |file| behaviors_file(file) }, counts: sweep.summary)
      else
        result = Hecks::Behaviors.run(target)
        ok(target: target, files: [behaviors_file(result)], counts: Hecks::Behaviors.summarize([result]))
      end
    rescue *refusal_classes => e
      refused(e)
    end

    # :nodoc:
    def behaviors_file(result)
      { path:        result.path,
        parse_error: result.parse_error,
        runs:        Array(result.runs).map { |run| { description: run.description, status: run.status, message: run.message } } }
    end

    # Tails this bus's own dispatch/query/state audit log — a pull-based
    # substitute for a push subscription, since a stdio door answers one
    # request at a time with no channel to push through.
    #
    # @param runtime [Runtime::Registry] the booted domain to tail
    # @param limit [Integer, #to_i] how many recent log entries to return
    # @return [Hash] :ok, :domain, :entries; or the refused shape
    def follow(runtime:, limit: 20)
      bluebook = bluebook_for(runtime)
      entries  = log_lines(bluebook.name).last([limit.to_i, 1].max)

      ok(domain: bluebook.name, entries: entries)
    rescue *refusal_classes => e
      refused(e)
    end

    # :nodoc:
    def log_lines(domain_name)
      path = log_path(domain_name)
      return [] unless File.exist?(path)

      File.readlines(path).map { |line| JSON.parse(line, symbolize_names: true) }
    end

    # What actually happened, with payloads, to one aggregate or record — read
    # off this bus's own audit log (a dispatch's announced events), not a full
    # event-sourcing replay. aggregate: narrows the search; id: (requires
    # aggregate:) narrows further to one record.
    #
    # @param runtime [Runtime::Registry] the booted domain to search
    # @param aggregate [String, Symbol, nil] narrows the search to one aggregate
    # @param id [String, Object, nil] narrows further to one record; requires aggregate
    # @param limit [Integer, #to_i, nil] how many recent matching events to
    #   return; nil returns every one found
    # @return [Hash] :ok, :domain, :events; or the refused shape
    # @raise [Runtime::TypeMismatch] if id is given without aggregate
    def events(runtime:, aggregate: nil, id: nil, limit: nil)
      raise Runtime::TypeMismatch, "id: requires aggregate: too — an id alone is not unique across aggregates" if id && !aggregate

      bluebook = bluebook_for(runtime)
      fqn      = aggregate ? "#{bluebook.name}::#{aggregate_ir!(bluebook, aggregate).hecks_name}" : nil

      found = log_lines(bluebook.name).filter_map { |entry| entry_events(entry, fqn, id) }.flatten(1)
      found = found.last(limit.to_i) if limit

      ok(domain: bluebook.name, events: found)
    rescue *refusal_classes => e
      refused(e)
    end

    # :nodoc:
    def entry_events(entry, fqn, id)
      return unless entry[:tool] == "dispatch" && entry[:ok] && entry[:events]
      return if fqn && !entry[:verb].to_s.start_with?("#{fqn}.")
      return if id && entry[:id] != id

      entry[:events].map { |event| event.merge(time: entry[:time], verb: entry[:verb], id: entry[:id]) }
    end

    # Runtime::WiringError is included alongside the true domain refusals: a
    # bus caller sees an honest refusal here too, not a crash, even though a
    # wiring defect isn't a rule the caller broke.
    # :nodoc:
    def refusal_classes = [Runtime::NotFound, Runtime::TypeMismatch, Runtime::WiringError, *Runtime::DOMAIN_REFUSALS]

    # :nodoc:
    def ok(**fields) = { ok: true }.merge(fields)

    # The domain's own refusal text travels verbatim; this only wraps it
    # consistently, rather than letting a stack trace reach the caller.
    # :nodoc:
    def refused(error, summary: nil) = { ok: false, summary: summary, error: error.message }
  end
end
