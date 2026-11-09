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
          # The world's defaults when it declares no `resident` line.
          DEFAULTS = { idle_seconds: 600.0, max_residents: Crowd::DEFAULT_CAP.to_f }.freeze

          private

          def prepare
            # First registered, so last run: after every handler a line registers, a child ends.
            at_exit { Worker.leave if defined?(::Hecks::Adapters::Driving::Resident::CHILD) }
            @start_env = ENV.to_h
            @fingerprint = Fingerprint.new(@root)
            @fingerprint.mark!
            EnvTrace.tracing { load_everything }
            note_environment
            @settings = settings
            Crowd.remember(@settings[:max_residents])
            @crowded = standing >= @settings[:max_residents]
          end

          def load_everything
            require_hecks
            @cache = DescribedCache.new
            ENVIRONMENTS.each { |name| load_domain(File.join(@root, DOMAIN), name) }
          end

          # @return [Array<String>] the variables a line must match the resident on
          def loaded_names = (LOADED_WITH | EnvTrace.names) - PER_LINE

          # Keeps the values the loaded code saw of the variables it read, apart from the ones
          # `PER_LINE` names, which `under` set for each domain it loaded and which are not the
          # resident's own.
          def note_environment = (@environment = @start_env.slice(*loaded_names))

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
            require "bootsnap"
            return unless Hecks::CacheDir.stable?

            Bootsnap.setup(cache_dir: Hecks::CacheDir.path("bootsnap"), development_mode: true,
                           load_path_cache: true, compile_cache_iseq: true, compile_cache_yaml: false)
          rescue ScriptError, StandardError
            nil
          end

          def load_domain(path, environment)
            return unless Dir.exist?(path)

            described = @cache.load(path, environment)
            @fingerprint.watch(path)
            Hecks::Adapters::Driving::UsageCache.code_fingerprint(described.directory)
          end

          # @return [Hash{Symbol => Float}] `idle_seconds` and `max_residents` from the Hecks world
          def settings
            world = @cache.fetch(File.join(@root, DOMAIN), ENVIRONMENTS.first)&.registry&.world("Hecks")
            declared = world ? world.for_verb("resident") : {}
            DEFAULTS.merge(declared.slice(*DEFAULTS.keys)).transform_values { |value| Float(value) }
          end

          # @return [Integer] how many other residents hold their locks
          def standing = Crowd.standing(Paths.lock(@root))

          # Loads what the children named as missing, so the next line finds it ready: a domain,
          # or a Ruby file of the checkout's own `lib/`. What it reads from the environment while
          # loading joins what a line must match.
          def learn
            return if @notes.empty?

            EnvTrace.tracing { learn_one(*@notes.pop) until @notes.empty? }
            note_environment
            settle
          end

          # Writes the verdicts the load judged, so no forked child inherits them unwritten and
          # writes them again at its own exit, and promotes everything loaded to the old
          # generation, so a child's garbage collections leave the shared pages alone instead of
          # copying them.
          def settle
            Hecks::Bluebook::MetaValidator::VerdictCache.flush
            Process.warmup
          end

          def learn_one(kind, path, environment = nil)
            return load_domain(path, environment.to_s.empty? ? nil : environment) if kind == "D"

            require path if path.start_with?(File.join(@root, "lib/"))
          rescue LoadError, StandardError
            nil
          end
        end
      end
    end
  end
end
