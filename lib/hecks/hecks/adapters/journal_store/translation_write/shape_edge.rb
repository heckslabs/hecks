# frozen_string_literal: true

module Hecks
  module Adapters
    class JournalStore
      module TranslationWrite
        # The edge for a shape that changed under an unchanged label: the scaffold's diff, written
        # from
        # the label to itself. Only `TranslationWrite` includes it.
        module ShapeEdge
          # A line of an edge file that still marks a field as undecided.
          UNRESOLVED_LINE = /^\s*unresolved /

          private

          # A held label that equals the current one with a different projection: the edge is the
          # scaffold's diff, from the label to itself. A field the diff cannot decide refuses the
          # write.
          #
          # @raise [Runtime::WiringError] when the diff leaves a field or an aggregate to decide
          def shape_edge_plan(domain, latest, current)
            diffed = diff_for(domain, latest)
            refuse_undecided!(domain, "UNCLAIMED #{diffed[:unclaimed].join(", ")}") unless diffed[:unclaimed].empty?
            text = Translation::Scaffold.render(shape_edge(domain, latest, current, diffed))
            refuse_undecided!(domain, "unresolved fields") if text.match?(UNRESOLVED_LINE)
            Plan.new(path: Translation::EdgeFiles.path_for(domain.directory, from: latest[:label], to: current),
                     text: text, removals: [], labels: [latest[:label], current])
          end

          def diff_for(domain, latest)
            Translation::Scaffold.diff(PostgresRevision::LineageManager.held_bluebook(latest), domain.bluebook)
          end

          def shape_edge(domain, latest, current, diffed)
            Translation::Scaffold::Edge.new(domain: domain.domain_name, from: latest[:label], to: current,
                                            ordinal: latest[:ordinal] + 1, label: current,
                                            aggregates: diffed[:aggregates], retired: diffed[:retired])
          end

          def refuse_undecided!(domain, reason)
            raise Runtime::WiringError,
                  "cannot write the translation of #{domain.domain_name}: the shape changed under the same label " \
                  "and the scaffold leaves #{reason} to decide; write the edge by hand"
          end

          def already_leads(from, to)
            Plan.new(message: "one edge already leads #{from} to #{to} — nothing to write.")
          end

          def edge_plan(domain, from, to, chain)
            edge = Translation::Compose.compose(domain: domain.domain_name, from: from, to: to, chain: chain)
            labels = [from, *chain.map(&:to)]
            stale = Translation::EdgeFiles.stale(domain.directory, domain: domain.domain_name, chain: chain)
            Plan.new(path: Translation::EdgeFiles.path_for(domain.directory, from: from, to: to),
                     text: Translation::ComposeRender.render(edge, labels: labels), removals: stale, labels: labels)
          end
        end
      end
    end
  end
end
