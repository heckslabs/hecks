module Hecks
  module Ports
    module Persistence
      class Lineage
        # Answers whether a translation edge accounts for a path that vanished, or fills one
        # that arrived; the questions the era diff asks of a lineage.
        module Coverage
          # Reports whether some rule accounts for a held path that vanished or changed type.
          #
          # A rule covering a whole top-level attribute also covers anything nested
          # under it; `backfills` only matches a whole name, since a backfill adds an
          # attribute that is new outright, never a path that existed and moved.
          #
          # @param path [String, Symbol] a bare attribute name or a dotted value-object member path
          # @return [Boolean] true when a rename, move, convert, drop or compute names the path or
          #   its top-level attribute as its source, or a backfill names the top-level attribute
          def explains?(path)
            path = path.to_s
            top = path.split(".").first

            @renames.key?(top.to_sym) ||
              sources.any? { |source| source == path || source.split(".").first == top } ||
              backfilled?(top)
          end

          # Reports whether some rule gives an existing record a value at a new attribute.
          #
          # The destination-side twin of `explains?`, which checks a rule's source; this checks
          # `@renames.value?` too, since a bare rename fills the destination unconditionally,
          # the same way a backfill would.
          #
          # @param path [String, Symbol] the name of a top-level attribute new in the current shape
          # @return [Boolean] true when a rename, move, convert or compute lands a value in that
          #   attribute, or a backfill names it
          def fills?(path)
            path = path.to_s

            @renames.value?(path.to_sym) ||
              destinations.any? { |destination| destination.split(".").first == path } ||
              backfilled?(path)
          end

          private

          # Every path a move, convert, compute or drop reads from.
          def sources
            [*@moves, *@converts, *@rules.computes].map(&:from) + @drops.map(&:to_s)
          end

          # Every path a move, convert or compute writes to.
          def destinations = [*@moves, *@converts, *@rules.computes].map(&:to)

          def backfilled?(name) = @rules.backfills.any? { |backfill| backfill.name.to_s == name }
        end
      end
    end
  end
end
