require "hecks/adapters/driving/resident/env_value"

module Hecks
  module Adapters
    module Driving
      module Resident
        # What stops a resident from serving an aggregate out of Memory that its checkout's local
        # hecksagon binds to SQLite. A boot that read the local files half written, or not at all,
        # resolves every aggregate to Memory and answers each command with success while writing
        # nothing the ledger holds. The guard reads the same files the load read (the borrowed
        # main checkout's when a worktree borrows them, {WorktreeBorrow}) and compares them with
        # the stores the loaded registry resolved, for the loaded domain a line is served from.
        # A declared file that cannot be read declares nothing; a registry whose stores cannot be
        # read is refused ({unreadable}).
        #
        # Only the entry a line is served from counts: a line made under the spec switch or a
        # `memory` or `test` environment is meant to run on Memory and is never refused.
        module PersistenceGuard
          # An aggregate a local hecksagon binds to SQLite, as in
          # `Tickets::Work.persisted_by("SqlitePersistence")`.
          BIND = /^\s*([A-Z]\w*(?:::\w+)+)\.persisted_by\(?\s*["']SqlitePersistence["']/
          # The front of the store a registry row names for an aggregate kept in SQLite.
          SQLITE = "SqliteAt ".freeze
          # The front of a store row's name.
          ROW = "store ".freeze
          # The last part of a class's name, after the modules around it.
          LAST_NAME = /\w+\z/

          module_function

          # @param directory [String] the Hecks domain's directory in the checkout
          # @param env [#[]] the resident's environment, which the worktree borrow reads
          # @return [Array<String>] the aggregates, as `Domain::Aggregate`, the local hecksagons
          #   bind to SQLite
          def declared(directory, env = ENV)
            require "hecks/adapters/driven/worktree_borrow"
            own = Adapters::WorktreeBorrow.directory(directory, env: env) || directory
            Dir.glob(File.join(own, "*.local.hecksagon")).flat_map { |file| File.read(file).scan(BIND).flatten }.uniq
          rescue SystemCallError
            []
          end

          # A declared aggregate counts as kept when its own store row, or, without one, its
          # bluebook's row, names SQLite. A registry that lost the local binds writes no row for
          # the aggregate and Memory for its bluebook, so a missing row is a gap too. A declared
          # aggregate the registry resolves to Postgres is a gap as well: the local file says
          # SQLite.
          #
          # @param declared [Array<String>] what {declared} answered
          # @param rows [Array<Array>] the registry's store rows: name, store, where it was bound
          # @return [String, nil] the first declared aggregate the registry does not keep in SQLite
          def gap(declared, rows)
            stores = rows.to_h { |name, store, _| [name.delete_prefix(ROW), store] }
            declared.find { |aggregate| !stores.fetch(aggregate) { stores[bluebook_of(aggregate)] }.to_s.start_with?(SQLITE) }
          end

          # @param aggregate [String] `Domain::Aggregate`
          # @return [String] the bluebook's part of the name
          def bluebook_of(aggregate) = aggregate.split("::")[0..-2].join("::")

          # @param environment [String, nil] a line's `HECKS_ENVIRONMENT`
          # @return [String, nil] the environment its loaded domain is cached under: an empty
          #   value is none, as {Loading} keys the domains it loads
          def environment(environment) = environment.to_s.empty? ? nil : environment

          # @param env [#[]] a line's environment
          # @return [Boolean] whether the line is meant to run on Memory
          def exempt?(env)
            !env["HECKS_WRITES_LOCAL"].to_s.empty? || %w[memory test].include?(env["HECKS_ENVIRONMENT"].to_s.strip)
          end

          # @return [String] the refusal reason for an aggregate, short enough for one reply line
          def reason(aggregate) = "persistence:#{aggregate}"[0, 60]

          # A registry whose stores cannot be read is not served: the guard cannot say it keeps
          # the declared aggregates, so it refuses as it would a gap.
          #
          # @param error [Exception] what reading the registry's stores raised
          # @return [String] the refusal reason, naming the error's class
          def unreadable(error) = reason("unreadable:#{class_name(error)}")

          # @param error [Exception] an error
          # @return [String] its class's name without the modules around it
          def class_name(error) = error.class.name.to_s[LAST_NAME]

          # @param described [Hecks::Runtime::Loader::Described] a domain the resident loaded
          # @param declared [Array<String>] what {declared} answered
          # @return [String, nil] the refusal for a line served from it: the first declared
          #   aggregate it does not keep in SQLite, or that its stores could not be read; nil
          #   when every declared aggregate is kept there
          def refusal(described, declared)
            found = gap(declared, rows_of(described.registry))
            found && reason(found)
          rescue StandardError => e
            unreadable(e)
          end

          # @param registry [Hecks::Runtime::Registry] a loaded registry
          # @return [Array<Array(String, String, String)>] its store rows, as `hecks config` reads
          #   them
          def rows_of(registry)
            require "hecks/hecks/adapters/settings_reading"
            Hecks::Adapters::SettingsReading.new.registry_stores(registry)
          end
        end
      end
    end
  end
end
