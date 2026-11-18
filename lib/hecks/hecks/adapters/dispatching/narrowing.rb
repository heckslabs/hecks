# frozen_string_literal: true

require_relative "effective_area"

module Hecks
  module Adapters
    class Dispatching
      # Narrows the claim of each started work item to the ground it holds now ({EffectiveArea}),
      # so the `WorkAreas` port and a landing's clash check, which read the stored claim, hold a
      # work item to its files and not to the directory it was planned with.
      module Narrowing
        private

        # A confirmed filling settles the ended sessions, then holds each started work item to the
        # files it changes.
        def settle_and_narrow(held)
          settle_ended(held)
          narrow_started(held)
        end

        # Rescopes each started work item whose effective area differs from its stored claim. A
        # rescope the domain refuses leaves the claim as it was and never stops the filling.
        #
        # @param held [Hash] the `Dispatch` record: `repo`
        # @return [Array<String>] the keys of the work items rescoped
        def narrow_started(held)
          effective = effective_for(plain(held[:repo]))
          return [] unless effective

          launcher = launcher_for(held)
          work_items.started.filter_map { |item| narrowed(launcher, item, effective.call(item)) }
        end

        def narrowed(launcher, item, area)
          return if area.sort == item.area.sort || !launcher.rescoped?(item.key, area)

          item.key
        end

        # A line for each chosen work item whose area is a top-level package directory.
        def area_warnings(plan) = plan.chosen.filter_map { |item| PackageRoots.warning(item) }

        # @return [EffectiveArea, nil] the reader for the checkout, a stand-in's when it names one
        def effective_for(repo)
          @standins[:effective] || (repo.to_s.empty? ? nil : EffectiveArea.new(repo))
        end
      end
    end
  end
end
