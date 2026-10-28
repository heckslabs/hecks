require_relative "../projector"
require_relative "../naming"
require_relative "site/table"

module Hecks
  module Projections
    # A bluebook projected as the files a Rails app needs to drive it through `hecks-rails`: a
    # controller per aggregate, and a routes file with a `resources` line for each.
    #
    #   Projector.call(:rails_app, bluebook: bluebook)
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

      # Projects every file the app needs for a bluebook.
      #
      # @param bluebook [Bluebook::Declaration] the bluebook the app drives
      # @param options [Hash] the registry's call shape
      # @option options [Array<Bluebook::Declaration>] :route_bluebooks every bluebook the routes
      #   file
      #   draws, when the app drives more than this one; this bluebook alone when absent
      # @return [Hash{String => String}] each file's path in the app to its text
      def call(bluebook:, options: {})
        controllers = driven(bluebook).to_h { |aggregate| controller(aggregate) }
        controllers.merge("config/routes.rb" => routes(options[:route_bluebooks] || [bluebook]))
      end

      # @param bluebook [Bluebook::Declaration] a bluebook
      # @return [Array<Bluebook::Aggregate>] its aggregates that take commands; one that only holds
      #   rows, such as an `App` row, has no page
      def driven(declaration) = declaration.aggregates.select { |aggregate| aggregate.commands.any? }

      # @param aggregate [Bluebook::Aggregate] the aggregate
      # @return [Array(String, String)] the controller's path and text
      def controller(aggregate)
        name = "#{Naming.pascal(Naming.plural(Naming.snake(aggregate.hecks_name)))}Controller"
        ["app/controllers/#{Naming.snake(name)}.rb",
         "# Joins the domain by its name; redefine an action here and call `super` to keep the generated one.\n" \
         "class #{name} < ApplicationController\nend\n"]
      end

      # @param bluebooks [Array<Bluebook::Declaration>] the bluebooks to draw
      # @return [String] the routes file's text
      def routes(declarations)
        resources = resources_of(declarations)
        drawn = ["  root to: \"#{home(declarations, resources)}#index\"", *resources.map { |_, name| "  resources :#{name}" }]
        "# A list, a show and a POST per command, drawn from the domain by hecks-rails.\n" \
          "Rails.application.routes.draw do\n#{drawn.join("\n")}\nend\n"
      end

      # @param bluebooks [Array<Bluebook::Declaration>] the bluebooks to draw
      # @return [Array<Array(String, String)>] each driven aggregate's name and resource name
      def resources_of(declarations)
        aggregates = declarations.flat_map { |declaration| driven(declaration) }
        aggregates.map { |aggregate| [aggregate.hecks_name, Naming.plural(Naming.snake(aggregate.hecks_name))] }
      end

      # @param bluebooks [Array<Bluebook::Declaration>] the bluebooks to draw
      # @param resources [Array<Array(String, String)>] each aggregate's name and resource name
      # @return [String] the resource the root path lists: the `App` row's home, else the first
      def home(declarations, resources)
        rows = declarations.flat_map { |declaration| Site::Table.rows_of(declaration, "App") }
        named = rows.filter_map { |row| row[:home] }.first
        resources.find { |name, _| name == named }&.last || resources.first.last
      end
    end
  end
end
