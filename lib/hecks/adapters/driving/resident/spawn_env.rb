module Hecks
  module Adapters
    module Driving
      module Resident
        # The environment a resident is started with. A resident compares each line's variables
        # with the ones it loaded under, so a resident that kept its spawner's environment would
        # refuse every caller whose environment differed from that one process's: a spec harness,
        # a hook, a session with `HECKS_*` set, a `bundle exec`. Every resident is started with
        # the same plain environment instead, whoever starts it, and sets up Bundler for itself
        # as the launcher does.
        #
        # It uses only the standard library: the client runs before anything else loads.
        module SpawnEnv
          # The variables a resident keeps, by name: where its programs and cache are, who it
          # runs as, its locale and terminal, and the two that name where its own files live
          # (`HECKS_CACHE_DIR`, and `HECKS_RESIDENT_PROTOCOL`, which a spec uses to stand in for a
          # resident of another protocol).
          KEEP = %w[PATH HOME USER LOGNAME SHELL LANG TMPDIR TERM XDG_CACHE_HOME HECKS_CACHE_DIR
                    HECKS_RESIDENT_PROTOCOL].freeze
          # The locale variables, kept as a family.
          KEEP_PREFIX = "LC_".freeze

          module_function

          # @param env [#to_h] the starting launcher's environment
          # @return [Hash{String => String}] only what a resident keeps; every other variable
          #   (`HECKS_*`, `CARGO_*`, `PG*`, `BUNDLE_*`, `GEM_*`, `RUBYOPT`, `RUBYLIB`, `CLAUDE_*`
          #   and the rest) is dropped
          def build(env = ENV)
            env.to_h.select { |name, _value| KEEP.include?(name) || name.start_with?(KEEP_PREFIX) }
          end
        end
      end
    end
  end
end
