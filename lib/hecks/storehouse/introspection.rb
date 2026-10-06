module Hecks
  module Storehouse
    # What a booted domain declares and has done: its domains, catalog, docs, validity, history and
    # behaviors. Extended onto `Storehouse`.
    module Introspection
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

        ok(domain: bluebook.name, aggregates: bluebook.aggregates.map { |aggregate| catalog_entry(aggregate) })
      rescue *refusal_classes => e
        refused(e)
      end

      # :nodoc:
      def catalog_entry(aggregate)
        { name:     aggregate.hecks_name,
          commands: aggregate.commands.map { |c| "#{Naming.snake(c.hecks_name)}!" }.sort,
          queries:  aggregate.queries.map { |q| Naming.snake(q.hecks_name) }.sort }
      end

      # One aggregate's (or the whole chapter's) full usage documentation — the
      # same document hecks docs renders for a human.
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
        runtime = Hecks.boot(confine!(domain, "domain"), install_doors: false)
        result  = { ok: true, domain: domain, valid: true }
        result[:findings] = model_findings(runtime) if deep
        result
      rescue StandardError => e
        { ok: false, domain: domain, valid: false, error: "#{e.class}: #{e.message}" }
      end

      # :nodoc:
      def model_findings(runtime)
        require_relative "../bluebook/model_check"
        findings = runtime.registry.bluebooks.values.flat_map { |bluebook| Bluebook::ModelCheck.call(bluebook) }
        findings.map { |f| { kind: f.kind, severity: f.severity, subject: f.subject, message: f.message } }
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
        repository.entries.map { |entry| { operation: entry.operation, id: entry.id, state: Doors::JsonDoor.materialize(entry.state) } }
      end

      # Runs a domain's hand-curated .behaviors examples and reports the results.
      #
      # @param target [String] a .behaviors file's path, or a directory to sweep
      # @return [Hash] :ok, :target, :files (each file's behaviors_file shape),
      #   :counts; or the refused shape
      # @raise [Runtime::NotFound] if target is nil or names no real file or directory
      def behaviors(target:)
        require_relative "../behaviors"
        raise Runtime::NotFound, "no such file or directory: #{target.inspect}" unless target && File.exist?(target)

        files, counts = File.directory?(target) ? sweep_behaviors(target) : single_behaviors(target)
        ok(target: target, files: files, counts: counts)
      rescue *refusal_classes => e
        refused(e)
      end

      # :nodoc:
      def sweep_behaviors(directory)
        sweep = Hecks::Behaviors.run_all(directory)
        [sweep.files.map { |file| behaviors_file(file) }, sweep.summary]
      end

      # :nodoc:
      def single_behaviors(file)
        result = Hecks::Behaviors.run(file)
        [[behaviors_file(result)], Hecks::Behaviors.summarize([result])]
      end

      # :nodoc:
      def behaviors_file(result)
        { path:        result.path,
          parse_error: result.parse_error,
          runs:        Array(result.runs).map { |run| run.to_h.slice(:description, :status, :message) } }
      end
    end
  end
end
