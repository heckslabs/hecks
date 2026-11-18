# frozen_string_literal: true

require_relative "effective_area"
require_relative "../delivery_library"

Hecks::Adapters::DeliveryLibrary.require("git_landing/rivals")

module Hecks
  module Adapters
    class Dispatching
      # Makes a landing's clash check read the ground each rival holds now: the files its own
      # branch has committed once it has commits, the same ground {EffectiveArea} gives the fill,
      # read at the landing and not as of the last fill. Files a rival has edited but not committed
      # are not seen, so they clash at that work item's own landing.
      #
      # The check itself is `GitLanding::Rivals`, in the vendored delivery package, whose files are
      # the release its lock names (ADR 0205) and are not edited here. The package gives no place
      # to hand it an area reader, so this module is prepended to it and swaps the area of each
      # work item the check asks about. Once the package takes a reader, this goes.
      module HeldGround
        # A work item as {EffectiveArea} reads one.
        Held = Struct.new(:key, :area)

        # @param git [Object] the adapter every git call goes through
        # @param checkout [String] the repository's top level, where the rivals' branches are read
        # @param registry [Runtime::Registry, nil] where the work items are read from
        def initialize(git, checkout, registry)
          super
          @held_root = checkout
        end

        # @param branch [String] the branch to land
        # @param onto [String] the branch it lands on, which each rival's changes are measured from
        # @return [String, nil] the refusal naming the work item and the files, nil when none clash
        def refusal(branch, onto)
          @held_reader = EffectiveArea.new(@held_root, onto: onto)
          super
        end

        private

        def claims?(item, file) = super(held(item), file)

        def wording(branch, item, clash) = super(branch, held(item), clash)

        def held(item) = item.merge(area: @held_reader.call(Held.new(item[:key], item[:area])))
      end
    end
  end
end

Hecks::Adapters::GitLanding::Rivals.prepend(Hecks::Adapters::Dispatching::HeldGround)
