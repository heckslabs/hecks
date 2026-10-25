require_relative "../projector"
require_relative "../naming"

module Hecks
  module Projections
    # A chapter projected as the files a Rails app needs to drive it through `hecks-rails`: a
    # controller per aggregate, and a routes file with a `resources` line for each.
    #
    #   Projector.call(:rails_app, bluebook: chapter)
    #   # => { "app/controllers/accounts_controller.rb" => "...", "config/routes.rb" => "..." }
    #
    # A model needs no file: `hecks-rails` generates one per aggregate at boot, so one is written by
    # hand only to hold presentation methods. A controller joins the domain by its name and the
    # `resources` line draws a show and a POST per command, so neither file names more than that.
    # The text only names `hecks-rails`'s conventions; nothing here requires Rails.
    module RailsApp
      extend Projector::Target

      projects_as :rails_app, emits: :files

      module_function

      # Projects every file the app needs for a chapter.
      #
      # @param bluebook [Bluebook::Chapter] the chapter the app drives
      # @param options [Hash] the registry's call shape
      # @option options [Array<Bluebook::Chapter>] :route_chapters every chapter the routes file
      #   draws, when the app drives more than this one; this chapter alone when absent
      # @return [Hash{String => String}] each file's path in the app to its text
      def call(bluebook:, options: {})
        controllers = bluebook.aggregates.to_h { |aggregate| controller(aggregate) }
        controllers.merge("config/routes.rb" => routes(options[:route_chapters] || [bluebook]))
      end

      # @param aggregate [Bluebook::Aggregate] the aggregate
      # @return [Array(String, String)] the controller's path and text
      def controller(aggregate)
        name = "#{Naming.pascal(Naming.plural(Naming.snake(aggregate.hecks_name)))}Controller"
        ["app/controllers/#{Naming.snake(name)}.rb",
         "# Joins the domain by its name; redefine an action here and call `super` to keep the generated one.\n" \
         "class #{name} < ApplicationController\nend\n"]
      end

      # @param chapters [Array<Bluebook::Chapter>] the chapters to draw
      # @return [String] the routes file's text
      def routes(chapters)
        drawn = chapters.flat_map(&:aggregates).map do |aggregate|
          "  resources :#{Naming.plural(Naming.snake(aggregate.hecks_name))}"
        end
        "# A show and a POST per command, drawn from the domain by hecks-rails.\n" \
          "Rails.application.routes.draw do\n#{drawn.join("\n")}\nend\n"
      end
    end
  end
end
