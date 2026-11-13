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
          # runs as, its locale and terminal, the two that name where its own files live
          # (`HECKS_CACHE_DIR`, and `HECKS_RESIDENT_PROTOCOL`, which a spec uses to stand in for a
          # resident of another protocol), and the spec runner's switch `HECKS_WRITES_LOCAL`. The
          # boot reads that switch to stay off the main checkout's dev databases, so a resident a
          # spec starts keeps it: it writes where it stands, as its launchers do, and serves them.
          # A terminal never sets it, so a developer's resident is started without it.
          KEEP = %w[PATH HOME USER LOGNAME SHELL LANG TMPDIR TERM XDG_CACHE_HOME HECKS_CACHE_DIR
                    HECKS_RESIDENT_PROTOCOL HECKS_WRITES_LOCAL].freeze
          # The locale variables, kept as a family.
          KEEP_PREFIX = "LC_".freeze
          # Set for every resident, whatever its starter had. The resident forks a child per line
          # and the child never execs. On macOS the Objective-C runtime aborts a forked child that
          # sets up a system class for the first time (`pg`'s libpq does, through Kerberos), and
          # this variable turns that abort off. The runtime reads it when the process starts, so a
          # child's `ENV.replace` with the caller's variables does not undo it. No line is compared
          # on it: the resident's baseline names only the variables the loaded code read.
          #
          # `PGGSSENCMODE` keeps libpq from probing the security service in the resident itself. A
          # forked child still crashed in the Kerberos framework (a segmentation fault, not the
          # abort), so the cure is the option on the connection (`Hecks::PgOptions`). libpq reads
          # this variable when it connects, and a child's `ENV.replace` drops it, so the children
          # use that option.
          FORCE = { "OBJC_DISABLE_INITIALIZE_FORK_SAFETY" => "YES", "PGGSSENCMODE" => "disable" }.freeze

          module_function

          # @param env [#to_h] the starting launcher's environment
          # @return [Hash{String => String}] only what a resident keeps, and the `FORCE` pair;
          #   every other variable (`HECKS_*`, `CARGO_*`, `PG*`, `BUNDLE_*`, `GEM_*`, `RUBYOPT`,
          #   `RUBYLIB`, `CLAUDE_*` and the rest) is dropped
          def build(env = ENV)
            kept = env.to_h.select { |name, _value| KEEP.include?(name) || name.start_with?(KEEP_PREFIX) }
            kept.merge(FORCE)
          end
        end
      end
    end
  end
end
