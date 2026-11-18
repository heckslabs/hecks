# frozen_string_literal: true

module Hecks
  module ShapeLedger
    # The ledger status of each bluebook under a directory, read from the committed ledger and its
    # edges, never from a database. A status is one of:
    #
    # - `current`: the ledger holds the shape the bluebook now has.
    # - `behind`: the shape the ledger holds leads to the current one by a committed edge, or only
    #   adds to it; the next release mint moves the ledger.
    # - `superseded`: the current shape is an older one than the ledger holds.
    # - `unminted`: the ledger has no entry for the bluebook, or no chain of edges leads from
    #   what it holds to the current shape.
    #
    # @example
    #   Status.of("lib/hecks/hecks")["bluebooks"]["Governance"]["status"]  # => "current"
    module Status
      module_function

      # @param directory [String] the domain directory whose bluebooks the ledger records
      # @param registry [Runtime::Registry] the domain's loaded registry; loaded here when not given
      # @return [Hash] `domain`, and `bluebooks`: each bluebook's status row, by name
      def of(directory, registry: Hecks.describe(directory).registry)
        path = File.join(directory, FILE)
        ledger = ShapeLedger.read(path)
        edges = ShapeLedger.edges_of(registry)
        bluebooks = registry.bluebooks.slice(*Scope.of(Scope.committed_registry(directory)).first).to_h do |name, bluebook|
          [name, classify(name, ledger[name], Runtime::StorageShape.mint_hash(bluebook), edges)]
        end
        { "domain" => directory, "bluebooks" => bluebooks }
      end

      # @param name [String] the bluebook's name
      # @param held [String, nil] the storage-shape hash the ledger holds, nil when it has none
      # @param now [String] the storage-shape hash of the bluebook as it is now
      # @param edges [Hash{String => Array<Array(String, String)>}] each bluebook's edges
      # @return [Hash] the bluebook's status row
      def classify(name, held, now, edges)
        return unminted(name, now) unless held

        held_label = ShapeLedger.label(held)
        now_label = ShapeLedger.label(now)
        return row("current", held_label, now_label) if held_label == now_label

        ahead_of(held_label, now_label, edges.fetch(name, []))
      end

      # @return [Hash] a row for a bluebook the ledger holds no shape for
      def unminted(name, now)
        row("unminted", nil, ShapeLedger.label(now), reason: "the ledger holds no shape for #{name}")
      end

      # Places the current shape against the held one when they differ.
      #
      # @return [Hash] a `superseded`, `behind` or `unminted` row
      def ahead_of(held, now, edges)
        return superseded(held, now) if ShapeLedger.reachable?(now, held, edges)
        return row("behind", held, now) if ShapeLedger.reachable?(held, now, edges)

        row("unminted", held, now, reason: "no translation edge leads from #{held} to #{now}")
      end

      # @return [Hash] a row for a shape older than the one the ledger holds
      def superseded(held, now)
        row("superseded", held, now, reason: "the current shape #{now} is older than the ledger's #{held}")
      end

      # @return [Hash] one bluebook's status, with every field present; `source` says it was read
      #   from the ledger
      def row(status, held, now, reason: nil)
        { "status" => status, "held" => held, "current" => now, "reason" => reason,
          "source" => "ledger" }
      end
    end
  end
end
