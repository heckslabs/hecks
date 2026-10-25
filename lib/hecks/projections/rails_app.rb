require "cgi"
require_relative "../projector"
require_relative "../naming"

module Hecks
  module Projections
    # A chapter projected as the files a Rails app needs to drive it through `hecks-rails`: a
    # controller per aggregate, a view per command, and a routes file with a `resources` line for
    # each aggregate.
    #
    #   Projector.call(:rails_app, bluebook: chapter)
    #   # => { "app/controllers/accounts_controller.rb" => "...",
    #   #      "app/views/accounts/freeze_account.html.erb" => "...", "config/routes.rb" => "..." }
    #
    # A model needs no file: `hecks-rails` generates one per aggregate at boot. A controller joins
    # the domain by its name and the `resources` line draws a show and a POST per command. A view is
    # the form a refusal comes back to; `command_form_for` takes its fields from the command, so
    # the text only names `hecks-rails`'s conventions and nothing here requires Rails.
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
        files = bluebook.aggregates.flat_map { |aggregate| aggregate_files(aggregate) }.to_h
        files.merge("config/routes.rb" => routes(options[:route_chapters] || [bluebook]))
      end

      # @param aggregate [Bluebook::Aggregate] the aggregate
      # @return [Array<Array(String, String)>] the path and text of its controller, then of a view
      #   for each of its commands
      def aggregate_files(aggregate)
        resource = Naming.plural(Naming.snake(aggregate.hecks_name))
        [controller(aggregate), *aggregate.commands.map { |command| view(aggregate, resource, command) }]
      end

      # @param aggregate [Bluebook::Aggregate] the aggregate
      # @param resource [String] the aggregate's plural resource name
      # @param command [Bluebook::Command] the command the form submits
      # @return [Array(String, String)] the view's path and text
      def view(aggregate, resource, command)
        verb = Naming.snake(command.hecks_name)
        creates = command.creates?
        subject = creates ? ":#{Naming.snake(aggregate.hecks_name)}" : "@record"
        member = creates ? "" : "/\#{@record.to_param}"
        ["app/views/#{resource}/#{verb}.html.erb",
         "<h1>#{CGI.escapeHTML(heading(command))}</h1>\n" \
         "<%= command_form_for #{subject}, :#{verb}, url: \"/#{resource}#{member}/#{verb}\" %>\n"]
      end

      # @param command [Bluebook::Command] the command
      # @return [String] its goal, or its name in words when it states none
      def heading(command)
        goal = command.goal.to_s
        goal.empty? ? Naming.words(command.hecks_name) : goal
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
