require "fileutils"
require "json"
require "hecks"

module Hecks
  # The committed record of each bluebook's storage shape, held against the shapes the bluebooks
  # have now, so a shape cannot change without the translation edge that carries a database across.
  #
  # A database that holds an era refuses a newer shape no edge leads to. The check that catches
  # that at a boot only runs against a real database, which specs and gates do not use, so this one
  # reads nothing but the loaded bluebooks and the committed edges: it needs no database.
  #
  # @example
  #   ShapeLedger.check("lib/hecks/hecks")  # => "15 bluebook shapes, each the one the ledger holds"
  module ShapeLedger
    # The ledger file, beside the bluebooks it records.
    FILE = "shapes.json".freeze

    # The length of the label a translation edge names a shape by.
    LABEL = 6

    # What a problem line tells the reader to do.
    REWRITE = "rewrite the ledger with `hecks conformance_run.check_shape_ledger --confirm --wait`".freeze

    # Raised with every problem found, or when the ledger cannot be rewritten.
    class Failure < StandardError; end

    module_function

    # Compares the ledger with the shapes of the bluebooks under a directory.
    #
    # @param directory [String] the domain directory whose bluebooks the ledger records
    # @param confirm [Boolean] rewrite the ledger when every moved shape has an edge
    # @param additive [Boolean] with `confirm`, write the empty edge for each shape that moved with
    #   none, on the operator's word that the change only adds; the mint audits every edge against
    #   the records it migrates and refuses one that would lose data
    # @return [String] the clean verdict, or what was written
    # @raise [Failure] with each problem
    def check(directory, confirm: false, additive: false)
      registry = Hecks.describe(directory).registry
      shapes = shapes_of(registry)
      edges = edges_of(registry)
      path = File.join(directory, FILE)
      confirm ? rewrite(path, shapes, edges, directory, additive) : verdict(path, shapes, edges)
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

    def verdict(path, shapes, edges)
      problems = problems(read(path), shapes, edges)
      raise Failure, problems.join("\n") unless problems.empty?

      "#{shapes.size} bluebook shapes, each the one the ledger holds"
    end

    # @return [Array<String>] one line per bluebook whose shape disagrees with the ledger
    def problems(ledger, shapes, edges)
      moved = shapes.filter_map { |name, now| problem(name, ledger[name], now, edges.fetch(name, [])) }
      moved + (ledger.keys - shapes.keys).map { |name| "#{name}: in the ledger but no longer loaded; #{REWRITE}" }
    end

    def problem(name, held, now, edges)
      return "#{name}: not in the ledger (shape #{label(now)}); #{REWRITE}" unless held
      return nil if label(held) == label(now)

      change = "#{name}: the shape moved #{label(held)} -> #{label(now)}"
      return "#{change}, and an edge covers it; #{REWRITE}" if reachable?(label(held), label(now), edges)

      "#{change} with no translation edge from #{label(held)}; #{edge_advice(name, label(held), label(now))}"
    end

    # What to commit: the empty edge covers a change that only adds, and a change that renames or
    # reshapes data needs the rules the scaffold writes from the database that holds the eras.
    def edge_advice(name, from, now)
      edge = %(Hecks.data_translation "#{name}", from: "#{from}", to: "#{now}" do end)
      "for a change that only adds, commit this edge under translations/ (as 2-#{now}.bluebook): #{edge}. " \
        "Data that is renamed or reshaped needs rules: `hecks query era.scaffold_translation " \
        "domain.value=<directory>` writes them, reading the eras from the database the domain's " \
        "own world names. A change that only adds is settled in one step " \
        "by `hecks conformance_run.check_shape_ledger --confirm --additive --wait`"
    end

    def rewrite(path, shapes, edges, directory, additive)
      ledger = read(path)
      written = additive ? write_edges(directory, uncovered_moves(ledger, shapes, edges)) : []
      uncovered = additive ? [] : problems(ledger, shapes, edges).reject { |line| line.include?(REWRITE) }
      raise Failure, uncovered.join("\n") unless uncovered.empty?

      File.write(path, "#{JSON.pretty_generate(shapes.sort.to_h)}\n")
      "wrote #{shapes.size} bluebook shapes to #{path}#{edges_note(written)}"
    end

    def edges_note(written) = written.empty? ? "" : " and #{written.size} empty edge(s): #{written.join(", ")}"

    # @return [Array<Array(String, String, String)>] `[bluebook, from, to]` for each shape that
    #   moved
    #   with no chain of edges leading to it
    def uncovered_moves(ledger, shapes, edges)
      shapes.filter_map do |name, now|
        held = ledger[name]
        next unless held && label(held) != label(now)
        next if reachable?(label(held), label(now), edges.fetch(name, []))

        [name, label(held), label(now)]
      end
    end

    # @return [Array<String>] the paths of the empty edges written
    def write_edges(directory, moves)
      FileUtils.mkdir_p(File.join(directory, "translations"))
      moves.map do |name, from, now|
        path = File.join(directory, "translations", "2-#{now}.bluebook")
        File.write(path, %(Hecks.data_translation "#{name}", from: "#{from}", to: "#{now}" do\nend\n))
        path
      end
    end

    # @return [Hash{String => String}] the ledger, empty when there is none yet
    def read(path) = File.exist?(path) ? JSON.parse(File.read(path)) : {}
  end
end
