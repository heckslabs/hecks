require_relative "../projector"
require_relative "../naming"

module Hecks
  module Projections
    # A chapter projected as the files a Rails app drives it through (ADR 0121): one thin model and
    # one controller per aggregate, and a routes file that draws the chapter's verbs.
    #
    #   Projector.call(:rails_app, bluebook: chapter)
    #   # => { "app/models/account.rb" => "...", "app/controllers/accounts_controller.rb" => "...",
    #   #      "config/routes.rb" => "..." }
    #
    # The text only names `hecks-rails`'s classes; nothing here requires Rails. A model is the app's
    # own once written (it may grow presentation methods), so `launch.project_rails` writes a file
    # only where none exists. A class is named the way Rails names the file's constant, `AtmCard`
    # for `atm_card.rb`, and says which aggregate it stands for in full.
    module RailsApp
      extend Projector::Target

      projects_as :rails_app, emits: :files

      module_function

      # Projects every file the app needs for one chapter.
      #
      # @param bluebook [Bluebook::Chapter] the chapter the app drives
      # @param options [Hash] the registry's call shape
      # @option options [Array<String>] :route_chapters every chapter the routes file draws, when
      #   the app drives more than this one; this chapter alone when absent
      # @return [Hash{String => String}] each file's path in the app to its text
      def call(bluebook:, options: {})
        files = bluebook.aggregates.flat_map { |aggregate| aggregate_files(bluebook, aggregate) }.to_h
        files.merge("config/routes.rb" => routes(Array(options[:route_chapters] || [bluebook.name])))
      end

      # The model and controller of one aggregate, by path.
      #
      # @param bluebook [Bluebook::Chapter] the chapter declaring the aggregate
      # @param aggregate [Bluebook::Aggregate] the aggregate
      # @return [Array<Array(String, String)>] the model's and the controller's path and text
      def aggregate_files(bluebook, aggregate)
        snake = Naming.snake(aggregate.hecks_name)
        plural = Naming.plural(snake)
        [["app/models/#{snake}.rb", model(bluebook, aggregate, snake)],
         ["app/controllers/#{plural}_controller.rb", controller(aggregate, snake, plural)]]
      end

      # @return [String] the model's text
      def model(bluebook, aggregate, snake)
        <<~RUBY
          # The #{aggregate.hecks_name} aggregate of the #{bluebook.name} chapter, whose shape, rules and
          # verbs the chapter declares. Presentation methods may be added here; a validation, callback
          # or association may not (HecksRails/ThinModel).
          class #{Naming.pascal(snake)} < Hecks::Rails::Model
            aggregate "#{bluebook.name}.#{aggregate.hecks_name}"
          end
        RUBY
      end

      # @return [String] the controller's text
      def controller(aggregate, snake, plural)
        <<~RUBY
          # One named action per verb of #{aggregate.hecks_name}; override one by name and call `super`.
          class #{Naming.pascal(plural)}Controller < ApplicationController
            include Hecks::Rails::Controller

            drives #{Naming.pascal(snake)}
          end
        RUBY
      end

      # @return [String] the routes file's text
      def routes(chapters)
        drawn = chapters.map { |name| %(  hecks_routes "#{Naming.snake(name)}") }.join("\n")
        "# The domain's verbs: a POST per command, a GET per query, and `show` per aggregate.\n" \
          "Rails.application.routes.draw do\n#{drawn}\nend\n"
      end
    end
  end
end
