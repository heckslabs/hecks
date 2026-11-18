require "json"
require "hecks"
require_relative "ports/persistence/plugins/era/era_check"
require_relative "shape_ledger/kept"
require_relative "shape_ledger/scope"
require_relative "shape_ledger/status"
require_relative "shape_ledger/edge_hygiene"
require_relative "shape_ledger/classify"

module Hecks
  # The committed record of each bluebook's storage shape as of its last release mint, held against
  # the shapes the bluebooks have now. It reads nothing but the loaded bluebooks, the ledger and the
  # committed edges, so the gate needs no database.
  #
  # Each entry holds the shape's hash and projection. A shape that moved passes when it only adds
  # (`Classify.additive?`) or a committed edge covers it, and commits nothing; any other move fails
  # by name. `release.mint` (`SchemaRevision.ReleaseMint`) is the one writer of the ledger.
  #
  # It holds only era-adapter bluebooks and framework members that clients persist (see `Scope`).
  #
  # @example
  #   ShapeLedger.check("lib/hecks/hecks")  # => "1 bluebook shapes, each ..."
  module ShapeLedger
    # The ledger file, beside the bluebooks it records.
    FILE = "shapes.json".freeze

    # The length of the label a translation edge names a shape by.
    LABEL = 6

    # What a problem line tells the reader to do.
    REWRITE = "release.mint rewrites the ledger (`hecks schema_revision.release_mint! --confirm --wait`)".freeze

    # Raised with every problem found, or when the ledger cannot be rewritten.
    class Failure < StandardError; end

    module_function

    # Compares the ledger with the shapes of the bluebooks under a directory.
    #
    # @param directory [String] the domain directory whose bluebooks the ledger records
    # @param confirm [Boolean] rewrite the ledger with the shapes the bluebooks have now, once every
    #   move is one the check passes
    # @return [String] the clean verdict, or what was written
    # @raise [Failure] with each problem
    def check(directory, confirm: false)
      registry = Scope.committed_registry(directory)
      path = File.join(directory, FILE)
      shapes, ledger, skipped = Scope.view(registry, path)
      judge = Classify.judge(registry, projections(path))
      edges = edges_of(registry)
      return rewrite(path, registry, shapes, problems(ledger, shapes, edges, judge)) if confirm

      verdict(problems(ledger, shapes, edges, judge), shapes) + Scope.note(skipped) +
        EdgeHygiene.report(directory, ledger: ledger, shapes: shapes)
    end

    # @param directory [String] the domain directory whose bluebooks the ledger records
    # @return [Array<String>] one line per bluebook whose shape moved in a way nothing covers, as
    #   `check` refuses it; empty when a release mint may go ahead
    def refusals(directory)
      registry = Scope.committed_registry(directory)
      path = File.join(directory, FILE)
      shapes, ledger, = Scope.view(registry, path)
      found = problems(ledger, shapes, edges_of(registry), Classify.judge(registry, projections(path)))
      found.reject { |line| line.include?(REWRITE) }
    end

    # @param registry [Runtime::Registry] the loaded bluebooks
    # @return [Hash{String => String}] each bluebook's storage-shape hash, by name
    def shapes_of(registry)
      registry.bluebooks.to_h { |name, bluebook| [name, Runtime::StorageShape.mint_hash(bluebook)] }
    end

    # @param registry [Runtime::Registry] the loaded bluebooks
    # @return [Hash{String => Array<Array(String, String)>}] each bluebook's edges as `[from, to]`
    def edges_of(registry)
      registry.translations.group_by(&:domain).transform_values { |edges| pairs(edges) }
    end

    def pairs(edges) = edges.map { |edge| [edge.from, edge.to] }

    def label(hash) = hash.to_s[0, LABEL]

    # @return [Boolean] whether a chain of edges leads from one label to another
    def reachable?(from, to, edges)
      seen = [from]
      queue = [from]
      queue.concat(next_labels(queue.shift, edges, seen)) until queue.empty? || seen.include?(to)
      seen.include?(to)
    end

    def next_labels(at, edges, seen)
      fresh = edges.filter_map { |from, to| to if from == at && !seen.include?(to) }
      seen.concat(fresh)
      fresh
    end

    def verdict(problems, shapes)
      raise Failure, problems.join("\n") unless problems.empty?

      "#{shapes.size} bluebook shapes, each the one the ledger holds or only added to"
    end

    # @return [Array<String>] one line per bluebook whose shape moved in a way nothing covers
    def problems(ledger, shapes, edges, judge)
      moved = shapes.filter_map { |name, now| problem(name, ledger[name], now, edges.fetch(name, []), judge) }
      moved + (ledger.keys - shapes.keys).map { |name| "#{name}: in the ledger but no longer loaded; #{REWRITE}" }
    end

    def problem(name, held, now, edges, judge)
      return nil if held.nil? || label(held) == label(now)
      return nil if reachable?(label(held), label(now), edges) || judge.additive?(name)

      "#{name}: the shape moved #{label(held)} -> #{label(now)} in a way that is not provably additive and " \
        "no translation edge covers it; #{edge_advice(name)}"
    end

    # What to commit: a rule that names the change, since a change that renames or reshapes data
    # cannot be carried by a diff, and the scaffold writes the rules from the database that holds
    # the eras.
    def edge_advice(name)
      "write the rules for #{name}: `hecks schema_revision.scaffold_translation domain.value=<directory>` " \
        "reads the eras from the database the domain's own world names. A change that only adds needs nothing."
    end

    def rewrite(path, registry, shapes, problems)
      uncovered = problems.reject { |line| line.include?(REWRITE) }
      raise Failure, uncovered.join("\n") unless uncovered.empty?

      File.write(path, "#{JSON.pretty_generate(entries_of(registry, shapes))}\n")
      "wrote #{shapes.size} bluebook shapes to #{path}"
    end

    # @return [Hash{String => Hash}] each bluebook's `hash` and `projection`, by name
    def entries_of(registry, shapes)
      shapes.sort.to_h do |name, hash|
        [name, { "hash" => hash, "projection" => Runtime::StorageShape.project(registry.bluebooks.fetch(name)) }]
      end
    end

    # @return [Hash{String => String}] each held shape's hash by name, empty when there is no ledger
    def read(path) = entries(path).transform_values { |entry| entry.is_a?(Hash) ? entry["hash"] : entry }

    # @return [Hash{String => Hash, nil}] each held shape's projection by name; nil for an entry
    #   that holds only a hash, or whose projection does not hash to the entry's hash
    def projections(path) = entries(path).transform_values { |entry| proven_projection(entry) }

    def proven_projection(entry)
      return unless entry.is_a?(Hash) && entry["projection"]

      entry["projection"] if Classify.hash_of(entry["projection"]) == entry["hash"]
    end

    # @return [Hash] the ledger as committed, empty when there is none yet
    def entries(path) = File.exist?(path) ? JSON.parse(File.read(path)) : {}
  end
end
