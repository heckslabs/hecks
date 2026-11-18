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
        # the stores the loaded registry resolved.
        #
        # Only the entry a line is served from counts: a line made under the spec switch or a
        # `memory` or `test` environment is meant to run on Memory and is never refused.
        module PersistenceGuard
          # An aggregate a local hecksagon binds to SQLite: `Tickets::Work.persisted_by("SqlitePersistence")`.
          BIND = /^\s*([A-Z]\w*(?:::\w+)+)\.persisted_by\(?\s*["']SqlitePersistence["']/
          # The store a registry row names for an aggregate that is on Memory.
          MEMORY = "Memory".freeze
          # The front of a store row's name.
          ROW = "store ".freeze

          module_function

          # @param directory [String] the Hecks domain's directory in the checkout
          # @param env [#[]] the resident's environment, which the worktree borrow reads
          # @return [Array<String>] the aggregates, as `Domain::Aggregate`, the local hecksagons bind
          #   to SQLite
          def declared(directory, env = ENV)
            require "hecks/adapters/driven/worktree_borrow"
            own = Adapters::WorktreeBorrow.directory(directory, env: env) || directory
            Dir.glob(File.join(own, "*.local.hecksagon")).flat_map { |file| File.read(file).scan(BIND).flatten }.uniq
          rescue SystemCallError
            []
          end

          # @param declared [Array<String>] what {declared} answered
          # @param rows [Array<Array>] the registry's store rows: the name, the store, where it was bound
          # @return [String, nil] the first declared aggregate whose loaded store is Memory
          def gap(declared, rows)
            memory = rows.select { |_, store, _| store == MEMORY }.map { |name, _, _| name.delete_prefix(ROW) }
            declared.find { |aggregate| memory.include?(aggregate) }
          end

          # @param env [#[]] a line's environment
          # @return [Boolean] whether the line is meant to run on Memory
          def exempt?(env)
            !env["HECKS_WRITES_LOCAL"].to_s.empty? || %w[memory test].include?(env["HECKS_ENVIRONMENT"].to_s.strip)
          end

          # @return [String] the refusal reason for an aggregate, short enough for one reply line
          def reason(aggregate) = "persistence:#{aggregate}"[0, 60]
        end
      end
    end
  end
end
