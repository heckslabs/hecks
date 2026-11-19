# frozen_string_literal: true

require_relative "../delivery_library"
require_relative "../dispatching/held_ground"

Hecks::Adapters::DeliveryLibrary.require("git_landing")

module Hecks
  module Adapters
    # Lets a finished branch land ahead of a started work item that shares its files. The area
    # check keeps two coders from starting on the same files; at a landing it would throw away
    # finished work, so the landing goes on and its report names the started item, which rebases
    # when it lands. Only a real merge conflict refuses, and the merger's compare-and-swap on the
    # target is unchanged.
    #
    # The override point is the vendored `GitLanding#refuse_rival`, in the delivery package, whose
    # files are not edited here (ADR 0205). This module is prepended to it and goes once the
    # package takes a setting for this.
    module LandingAhead
      # What opens the note a landing ahead of a started work item adds to its report.
      AHEAD = "landed ahead of a started work item"

      private

      # One try of a landing, with the started work item it lands ahead of read first and held in
      # this call alone, so a later landing by the same adapter never names it.
      def land_alone(branch, onto, **how)
        ahead = GitLanding::Rivals.new(@git, @checkout, @registry).refusal(branch, onto)
        landed = super
        ahead ? ahead_of(landed, ahead) : landed
      end

      def refuse_rival(_branch, _onto) = nil

      def ahead_of(landed, ahead)
        note = "#{AHEAD}: #{ahead}; it rebases when it lands"
        landed.merge(report: { value: "#{landed[:report][:value]}; #{note}" })
      end
    end
  end
end

Hecks::Adapters::GitLanding.prepend(Hecks::Adapters::LandingAhead)
