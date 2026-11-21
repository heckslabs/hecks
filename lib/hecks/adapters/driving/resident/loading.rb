require "hecks/adapters/driving/resident/crowd"
require "hecks/adapters/driving/resident/persistence_guard"

module Hecks
  module Adapters
    module Driving
      module Resident
        # What a resident does before it serves: load the code and the Hecks domain, remember the
        # fingerprint of what it loaded, read its settings from the Hecks world, and later load
        # what its children found missing. It binds no adapter and opens no store.
        module Loading
          # The Hecks domain a checkout's launcher boots, relative to the checkout.
          DOMAIN = "lib/hecks/hecks".freeze
          # Environments loaded at start: none named, and the Memory default of the launcher's
          # own commands.
          ENVIRONMENTS = [nil, "memory"].freeze
          # Variables the loading tools read before the code can say which it reads: a line that
          # differs on one is not served. The `HECKS_*`, `CARGO_*` and `PG*` variables the code
          # reads while it loads are added as they are seen (`EnvTrace`).
          LOADED_WITH = %w[HOME XDG_CACHE_HOME BUNDLE_GEMFILE RUBYOPT RUBYLIB GEM_HOME GEM_PATH
                           HECKS_NO_USAGE_CACHE HECKS_ENGINE].freeze
          # Variables the code reads while it loads that a line may still differ on, because the
          # resident loads once per value: `HECKS_ENVIRONMENT` picks the loaded domain
          # (`ENVIRONMENTS`, and one more per value a line brings, named to the resident), so it
          # never refuses a line.
          PER_LINE = %w[HECKS_ENVIRONMENT].freeze
          # The world's defaults when it declares no `resident` line. `line_seconds` is how long a
          # line may run before the resident ends it ({LineLimit}).
          DEFAULTS = { idle_seconds: 600.0, worktree_idle_seconds: 120.0, max_residents: Crowd::DEFAULT_CAP.to_f,
                       ready_wait_ms: 400.0, workers: 8.0,
                       line_seconds: 1800.0 }.freeze

          private

          def prepare
            # First registered, so last run: after every handler a line registers, a child ends.
            at_exit { Worker.leave if defined?(::Hecks::Adapters::Driving::Resident::CHILD) }
            @start_env = ENV.to_h
            @fingerprint = Fingerprint.new(@root).tap(&:mark!)
            EnvTrace.tracing { load_everything }
            note_environment
            @settings = settings
            Crowd.remember(@settings[:max_residents])
            Paths.remember("ready_wait_ms", @settings[:ready_wait_ms])
            @crowded = standing >= @settings[:max_residents]
            guard_persistence
          end

          # Reads what the local hecksagons bind to SQLite and judges the domain loaded with no
          # environment named, before the first line.
          def guard_persistence
            @persistence_declared = PersistenceGuard.declared(File.join(@root, DOMAIN))
            persistence_refusal(ENVIRONMENTS.first)
          end

          # Judges the Hecks domain loaded under an environment once, and again after {learn}
          # loads more. An environment the resident has not loaded has no gap: its line's child
          # loads the domain from the files as they are.
          #
          # @param environment [String, nil] the line's `HECKS_ENVIRONMENT`
          # @return [String, nil] the refusal that names the first aggregate the checkout's local
          #   hecksagon binds to SQLite that the loaded domain does not keep there, or says its
          #   stores could not be read ({PersistenceGuard}); nil when the line may be served
          def persistence_refusal(environment)
            key = PersistenceGuard.environment(environment)
            refusals = (@persistence_refusals ||= {})
            return refusals[key] if refusals.key?(key)

            described = held_domain(key)
            refusals[key] = PersistenceGuard.refusal(described, @persistence_declared) if described
          end

          # @return [Hecks::Runtime::Loader::Described, nil] the loaded domain the guard judges
          def held_domain(environment)
            return if Array(@persistence_declared).empty? || @cache.nil?

            @cache.fetch(File.join(@root, DOMAIN), environment)
          end

          def load_everything
            require_hecks
            Stores.load
            @cache = DescribedCache.new
            at_root { ENVIRONMENTS.each { |name| load_domain(File.join(@root, DOMAIN), name) } }
          end

          # Runs the resident's own loads in its checkout. A load reads the local files of the
          # working directory too ({Adapters::FolderOverlay#load_overlay}), and a resident starts in
          # its spawner's, so a load made there would serve that directory's databases to every
          # later line. A root that is not a directory loads where it stands. The root is a real
          # path ({Paths.root_for}), and a line names its directory and script absolutely, so the
          # pool's threads read the same files while a load has moved the working directory.
          #
          # @return [Object] the block's value
          def at_root(&) = File.directory?(@root.to_s) ? Dir.chdir(@root, &) : yield

          # @return [Array<String>] the variables a line must match the resident on
          def loaded_names = (LOADED_WITH | EnvTrace.names) - PER_LINE

          # Keeps the values the loaded code saw of the variables it read, apart from the ones
          # `PER_LINE` names, which `under` set for each domain it loaded and which are not the
          # resident's own, and writes down which of them a plain resident would not have set
          # ({Baseline}), so a launcher can tell a resident born under an odd environment.
          def note_environment
            @environment = @start_env.slice(*loaded_names)
            Baseline.write(@root, Baseline.odd(@environment, @root))
          end

          def require_hecks
            gemfile = File.join(@root, "Gemfile")
            ENV["BUNDLE_GEMFILE"] ||= gemfile if File.exist?(gemfile) && File.exist?(File.join(@root, "hecks.gemspec"))
            begin
              require "bundler/setup"
            rescue LoadError, StandardError
              nil
            end
            require "hecks"
            compile_cache
            Hecks::Adapters::Driving::UsageCache.remember_code!
          end

          # The compiled-Ruby cache a cold launcher sets up, so a forked child need not.
          def compile_cache
            require "hecks/boot_cache"
            Hecks::BootCache.setup(@root)
          rescue ScriptError, StandardError
            nil
          end

          def load_domain(path, environment)
            return unless Dir.exist?(path)

            described = @cache.load(path, environment)
            @fingerprint.watch(path)
            Hecks::Adapters::Driving::UsageCache.code_fingerprint(described.directory)
          end

          # @return [Hash{Symbol => Float}] `idle_seconds`, `max_residents`, `ready_wait_ms` and
          #   `workers` from the Hecks world, and `line_seconds` when the world declares it. A
          #   linked worktree's `idle_seconds` is the world's `worktree_idle_seconds`.
          def settings
            world = @cache.fetch(File.join(@root, DOMAIN), ENVIRONMENTS.first)&.registry&.world("Hecks")
            declared = world ? world.for_verb("resident") : {}
            read = DEFAULTS.merge(declared.slice(*DEFAULTS.keys)).transform_values { |value| Float(value) }
            read.merge(idle_seconds: read[linked_worktree? ? :worktree_idle_seconds : :idle_seconds])
          end

          # Whether the checkout is a linked worktree, which one session uses and then leaves, so
          # its resident waits a shorter time than the main checkout's: its `.git` is a file that
          # names the repository, where a checkout of its own has a directory.
          def linked_worktree? = File.file?(File.join(@root, ".git"))

          # @return [Integer] how many other residents hold their locks
          def standing = Crowd.standing(Paths.lock(@root))

          # Loads what the children named as missing, so the next line finds it ready: a domain,
          # or a Ruby file of the checkout's own `lib/`. What it reads from the environment while
          # loading joins what a line must match.
          def learn
            return if @notes.empty?

            EnvTrace.tracing { at_root { learn_one(*@notes.pop) until @notes.empty? } }
            @persistence_refusals = {}
            note_environment
            settle
          end

          # Writes the verdicts the load judged, so no forked child inherits them unwritten and
          # writes them again at its own exit, and promotes everything loaded to the old
          # generation, so a child's garbage collections leave the shared pages alone instead of
          # copying them.
          def settle
            Hecks::Bluebook::MetaValidator::VerdictCache.flush
            ForkWarmup.run
            Process.warmup
          end

          def learn_one(kind, path, environment = nil)
            return load_domain(path, PersistenceGuard.environment(environment)) if kind == "D"

            require path if path.start_with?(File.join(@root, "lib/"))
          rescue LoadError, StandardError
            nil
          end
        end
      end
    end
  end
end
