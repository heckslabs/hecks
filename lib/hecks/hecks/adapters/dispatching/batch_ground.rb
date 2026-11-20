# frozen_string_literal: true

require_relative "../area_overlap"

module Hecks
  module Adapters
    class Dispatching
      # The ground the lead of a batch holds now: its own ground ({EffectiveArea}), less what the
      # members already committed on its branch edited, plus the planned area of each member not
      # yet committed. A committed member's work is done, so it does not hold back an item of
      # another group while the lead waits to land; a member still to be built keeps its ground held
      # even once the lead's branch has commits. A work item that leads no batch holds its
      # {EffectiveArea} unchanged.
      #
      # It reads facts only: the members a started lead carries as `batched`, each one's
      # `batch_commit`, and the ground the wrapped reader says the lead's branch holds.
      class BatchGround
        # @param effective [#call] the ground of a work item by its branch ({EffectiveArea})
        # @param root [String, nil] the repository's top level, a relative area's base
        def initialize(effective, root: nil)
          @effective = effective
          @root = root
        end

        # @param item [Plan::Item] a started work item, carrying the members of its batch as
        #   `batched`
        # @return [Array<String>] the area it holds now
        def call(item)
          members = Array(item.batched)
          return @effective.call(item) if members.empty?

          own = item.area - members.flat_map(&:area)
          done, building = areas(members)
          (branch_ground(item, own).reject { |file| released?(file, done, own + building) } + building).uniq
        end

        private

        # @return [Array(Array<String>, Array<String>)] the areas of the committed members, then of
        #   those still to be built
        def areas(members)
          members.partition { |member| !member.batch_commit.to_s.empty? }.map { |part| part.flat_map(&:area) }
        end

        # What the lead's branch holds of its own area: the files it changes once it has commits.
        def branch_ground(item, own) = @effective.call(Plan::Item.new(**item.to_h, area: own))

        # A file is let go when a committed member's area holds it and no ground still held does.
        def released?(file, done, held) = inside?(file, done) && !inside?(file, held)

        def inside?(file, area) = !AreaOverlap.first_overlap([file], area, root: @root).nil?
      end
    end
  end
end
