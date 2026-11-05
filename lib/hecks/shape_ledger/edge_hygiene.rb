# frozen_string_literal: true

require "json"

module Hecks
  module ShapeLedger
    # Finds the translation edges that do not earn their file; it deletes nothing. The graph is
    # a bluebook's edge files plus its recorded implicit moves, aimed at the current shape. A file
    # is:
    #
    # - a **self-loop** when its `from` equals its `to`.
    # - a **fork** branch when two edges leave a label and both reach the current shape; the branch
    #   with the fewest steps is kept.
    # - an **orphan** when it lies on no path from a held era (the ledger label, an implicit move's
    #   start, or the start of a chain) to the current shape. A sole route is never flagged.
    #
    # @example
    #   EdgeHygiene.findings(dir, ledger: {}, shapes: { "Shop" => "bbbbbb1" }, moves: {})
    module EdgeHygiene
      # One edge: the file that declares it (nil for a recorded implicit move) and its two labels.
      Edge = Struct.new(:path, :from, :to)

      # The list beside the ledger of stale edges already known, each a finding key. A listed edge
      # is
      # reported as a warning and does not fail the check; any other stale edge fails it.
      KNOWN_FILE = "known_stale_edges.json"

      # One problem: its kind, the bluebook, the file to remove, a stable key naming the edge, and
      # what
      # to do.
      Finding = Struct.new(:kind, :domain, :path, :key, :message, keyword_init: true)

      module_function

      # Raises on each stale edge the known list does not name, and warns of those it does.
      #
      # @param directory [String] the domain directory holding `translations/`
      # @return [String] a warning line for each known stale edge, or empty
      # @raise [ShapeLedger::Failure] naming each other stale edge and the `git rm` that clears it
      def report(directory, **world)
        known = known_stale(File.join(directory, KNOWN_FILE))
        listed, fresh = findings(directory, **world).partition { |finding| known.include?(finding.key) }
        raise Failure, lines(fresh).join("\n") unless fresh.empty?

        listed.map { |finding| "\nwarning, known stale edge (#{KNOWN_FILE}) #{lines([finding]).first}" }.join
      end

      # @return [Array<String>] the finding keys of the known stale edges, empty when there is no
      #   list
      def known_stale(path) = File.exist?(path) ? JSON.parse(File.read(path)) : []

      # @param directory [String] the domain directory holding `translations/`
      # @param ledger [Hash{String => String}] the committed shape ledger
      # @param shapes [Hash{String => String}] each bluebook's current storage-shape hash
      # @param moves [Hash{String => Array<Hash>}] the recorded implicit moves
      # @return [Array<Finding>] every stale edge file, by bluebook
      def findings(directory, ledger:, shapes:, moves:)
        files = Translation::EdgeFiles.scan(directory)
        shapes.flat_map do |name, hash|
          recorded = moves.fetch(name, [])
          domain_findings(name, edges_of(files, name) + implicit_edges(recorded), ShapeLedger.label(hash),
                          held_labels(ledger[name], recorded))
        end
      end

      def edges_of(files, name)
        files.select { |found| found.domain == name }.map { |f| Edge.new(f.path, f.from, f.to) }
      end

      # @return [Array<String>] one report line per finding, each telling what to do
      def lines(findings) = findings.map { |finding| "#{finding.domain}: #{finding.message}" }

      # @return [String] the stable name of the edge a finding is about, as `kind:Bluebook:from>to`
      def key(kind, name, edge) = "#{kind}:#{name}:#{edge.from}>#{edge.to}"

      def implicit_edges(moves) = moves.map { |move| Edge.new(nil, move["from"], move["to"]) }

      def held_labels(held, moves)
        [(ShapeLedger.label(held) if held), *moves.map { |move| move["from"] }].compact
      end

      def domain_findings(name, all, current, held)
        loops, graph = all.partition { |edge| edge.from == edge.to && edge.path }
        forks = fork_findings(name, graph, current)
        route = held + entry_labels(graph)
        loops.map { |edge| loop_finding(name, edge) } + forks +
          orphan_findings(name, graph, current, route, forks.map(&:path))
      end

      def loop_finding(name, edge)
        Finding.new(kind: :self_loop, domain: name, path: edge.path, key: key(:self_loop, name, edge),
                    message: "self-loop edge #{edge.from} -> #{edge.to} in #{edge.path}; remove it with " \
                             "`git rm #{edge.path}`")
      end

      def fork_findings(name, graph, current)
        graph.group_by(&:from).flat_map do |label, leaving|
          live = leaving.select { |edge| leads_to?(edge.to, current, graph) }
          live.size > 1 ? fork_branch_findings(name, label, live, graph, current) : []
        end
      end

      def fork_branch_findings(name, label, live, graph, current)
        keep = live.min_by { |edge| [steps(edge.to, current, graph), edge.path ? 0 : 1] }
        (live - [keep]).map do |branch|
          files = branch_files(branch, keep, graph)
          Finding.new(kind: :fork, domain: name, path: files.first, key: key(:fork, name, branch),
                      message: fork_message(label, live, keep, branch, files))
        end
      end

      def fork_message(label, live, keep, branch, files)
        leaving = live.map { |edge| "#{edge.from} -> #{edge.to}" }.join(", ")
        "fork at #{label}: #{live.size} edges leave it and each reaches the current shape (#{leaving}); " \
          "keep #{keep.from} -> #{keep.to} and #{removal(branch, files)}, or compose the branch into one edge"
      end

      def removal(branch, files)
        return "remove the recorded implicit move #{branch.from} -> #{branch.to} from implicit_moves.json" if files.empty?

        "remove the branch with `git rm #{files.join(" ")}`"
      end

      # The files only the branch carries: edges leaving a label the branch reaches that the kept
      # route does not also reach.
      def branch_files(branch, keep, graph)
        shared = reached_from(keep.to, graph)
        own = reached_from(branch.to, graph) - shared
        [branch, *graph.select { |edge| own.include?(edge.from) }].filter_map(&:path).uniq
      end

      def orphan_findings(name, graph, current, starts, flagged)
        carried = starts.flat_map { |label| reached_from(label, graph) }
        graph.select(&:path).reject { |edge| flagged.include?(edge.path) || carried_to?(edge, carried, current, graph) }
             .map { |edge| orphan_finding(name, edge, current) }
      end

      def carried_to?(edge, carried, current, graph) = carried.include?(edge.from) && leads_to?(edge.to, current, graph)

      def orphan_finding(name, edge, current)
        Finding.new(kind: :orphan, domain: name, path: edge.path, key: key(:orphan, name, edge),
                    message: "orphan edge #{edge.from} -> #{edge.to} in #{edge.path} lies on no route from a " \
                             "held era to the current shape #{current}; remove it with `git rm #{edge.path}`")
      end

      # @return [Array<String>] labels no edge leads into: the first shape of each chain
      def entry_labels(graph) = graph.map(&:from).uniq - graph.map(&:to)

      def leads_to?(label, current, graph) = label == current || reached_from(label, graph).include?(current)

      # @return [Array<String>] every label a chain of edges leads to from one label, itself
      #   included
      def reached_from(label, graph)
        seen = [label]
        seen.each { |at| graph.each { |edge| seen << edge.to if edge.from == at && !seen.include?(edge.to) } }
        seen
      end

      # @return [Integer, Float] the fewest edges from one label to another, infinite when none
      def steps(label, current, graph)
        distance = { label => 0 }
        graph.size.times { widen(distance, graph) }
        distance.fetch(current, Float::INFINITY)
      end

      def widen(distance, graph)
        graph.each do |edge|
          next unless distance.key?(edge.from)

          distance[edge.to] = [distance[edge.to], distance[edge.from] + 1].compact.min
        end
      end
    end
  end
end
