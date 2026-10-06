require "digest"
require "json"
require "fileutils"
require "time"
require_relative "cache_dir"
require_relative "doors/command_request"
require_relative "doors/json_door"
require_relative "naming"
require_relative "projector"
require_relative "runtime/errors"
require_relative "storehouse/callers"
require_relative "storehouse/audit"
require_relative "storehouse/dispatching"
require_relative "storehouse/querying"
require_relative "storehouse/introspection"

module Hecks
  # Dispatch/query/state and introspection over one booted domain, pure
  # beyond its own JSONL audit log — booting stays the caller's job.
  #
  # The tools are in `Dispatching`, `Querying`, `Introspection` and `Audit`, extended onto this
  # module; what is here is what they share: the boot root, the alias table, and the checks on who
  # is calling.
  module Storehouse
    # Optional on dispatch/query; omitted, source is recorded as nil rather
    # than guessed.
    SOURCE_TAGS = %w[process-manager operator hook sidequest-agent cascade daemon].freeze

    # The root every domain path resolves under; HECKS_STOREHOUSE_ROOT widens it.
    # Hecks.boot Kernel.loads Ruby files here, so an unconfined path is
    # arbitrary code execution, not just a wrong-directory mistake.
    BOOT_ROOT = File.expand_path(ENV["HECKS_STOREHOUSE_ROOT"] || File.expand_path("../..", __dir__))

    # One dispatch or query call: the booted domain, what it is asked, and who is asking.
    Request = Struct.new(:runtime, :bluebook, :name, :summary, :args, :source, :dry_run, :role, :actor_id,
                         keyword_init: true)

    extend Callers
    extend Audit
    extend Dispatching
    extend Querying
    extend Introspection

    module_function

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
                                 "known: #{bluebook.aggregates.map(&:hecks_name).sort.join(", ")}"
    end

    # The alias table CliRunner resolves against, for one bluebook.
    # :nodoc:
    def cli_for(bluebook) = Projector.call(:cli, bluebook: bluebook, options: { program: "mcp" })

    # The same alias table CliRunner resolves against, kept here so dispatch
    # and query never drift from what a human typing hecks run sees.
    # :nodoc:
    def resolve!(cli, name, asking:)
      pool = asking ? cli[:questions] : cli[:commands]
      key  = cli[:names][asking ? :question : :command][name]
      spec = pool[key]
      return spec if spec

      known = cli[:names][asking ? :question : :command].keys.sort.join(", ")
      raise Runtime::NotFound, "no such #{asking ? "query" : "command"}: #{name.inspect} — known: #{known}"
    end

    # A fingerprint of a domain directory: every file's relative path, size and modification time.
    # Equal fingerprints mean no file was added, removed, resized or rewritten between two looks.
    #
    # @param path [String] the domain directory
    # @return [String] a hex SHA-256
    def fingerprint(path)
      files = Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).sort.select { |file| File.file?(file) }
      state = files.map do |file|
        stat = File.stat(file)
        "#{file.delete_prefix(path)}\0#{stat.size}\0#{stat.mtime.to_f}"
      end
      Digest::SHA256.hexdigest(state.join("\n"))
    end

    # The qualified verb each command name resolves to, by the alias map `dispatch` resolves
    # through; nil for a name that resolves to no command.
    #
    # @param runtime [Runtime::Dispatcher] the booted domain
    # @param names [Array<String, nil>] short or qualified command names
    # @return [Array<String, nil>] one verb or nil per name, in order
    def verbs_for(runtime, names)
      cli = cli_for(bluebook_for(runtime))
      names.map do |name|
        resolve!(cli, name.to_s, asking: false)[:command]
      rescue Runtime::NotFound
        nil
      end
    end

    # Runs one audited tool call: the block's outcome, or the refusal it raised, is written to the
    # audit log under `tool`, and the outcome answered without its `:verb`.
    #
    # @param request [Request] the call, its `bluebook` set
    # @param tool [String] what the audit line calls the call
    # @yieldreturn [Hash] the call's outcome
    # :nodoc:
    def audited(request, tool)
      outcome = yield
      record!(request.bluebook.name, tool: tool, verb: outcome[:verb], outcome: outcome, **audit_fields(request))
      outcome.except(:verb)
    rescue *refusal_classes => e
      outcome = refused(e, summary: request.summary)
      record!(request.bluebook&.name, tool: tool, outcome: outcome, **audit_fields(request))
      outcome
    end

    # :nodoc:
    def audit_fields(request) = request.to_h.slice(:summary, :source, :role, :actor_id)

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
