require "rack"
require_relative "page"
require_relative "index_renderer"
require_relative "app/responses"
require_relative "app/records"
require_relative "app/commands"
require_relative "app/queries"

module Hecks
  module Forms
    # A Rack app that content-negotiates one route: `/Banking/Account/Overdrawn.html`
    # renders HTML, and the same path with no extension or `.json` answers JSON.
    class App
      include Responses
      include Records
      include Commands
      include Queries

      # Builds the Rack app for a configured app name, exposing exactly the chapters its
      # `Forms.configure` block declared.
      #
      # @param registry [Runtime::Registry] the booted registry holding the exposed chapters
      # @param app_name [String, Symbol] the name an earlier `Forms.configure` call registered
      # @return [Forms::App] a Rack app routing only the configured chapters
      # @raise [ArgumentError] if no app of that name has been configured
      def self.for(registry:, app_name:)
        config = Forms.config(app_name) ||
                 raise(ArgumentError, "no app #{app_name.inspect} configured — " \
                                      "call Hecks::Forms.configure(#{app_name.inspect}) { expose \"...\" } first")
        new(registry: registry, exposed: config.exposes)
      end

      # @param registry [Runtime::Registry] the booted registry holding the exposed chapters
      # @param exposed [Array<String>] names of the chapters (domains) this app routes; a
      #   request for any other domain is answered 404
      # @param dispatcher [Runtime::Dispatcher, nil] the dispatcher commands and queries go
      #   through; nil builds a `Runtime::Dispatcher` over `registry`
      def initialize(registry:, exposed:, dispatcher: nil)
        @registry   = registry
        @exposed    = exposed
        @dispatcher = dispatcher || Runtime::Dispatcher.new(registry)
      end

      # Answers one Rack request, routing on the path and its trailing `.html`/`.json` format;
      # an unknown or unexposed route is answered as a plain-text 404 rather than raised.
      #
      # @param env [Hash{String => Object}] the Rack environment for the request
      # @return [Array(Integer, Hash{String => String}, Array<String>)] the Rack response
      #   triple of status, headers and body
      def call(env)
        request = Rack::Request.new(env)
        route(request)
      rescue RouteNotFound => e
        respond(404, "text/plain", e.message)
      end

      class RouteNotFound < StandardError; end

      private

      def route(request)
        segments = request.path_info.split("/").reject(&:empty?)
        return home(request) if segments.empty?

        chapter = chapter_for(segments[0])
        case segments.size
        when 2 then aggregate_route(request, chapter, *split_format(segments[1]))
        when 3 then verb_or_record_route(request, chapter, segments[1], *split_format(segments[2]))
        else unrouted(request, chapter, segments)
        end
      end

      def unrouted(request, chapter, segments)
        refuse_entity_command if segments.size == 4 && entity_command?(chapter, segments)
        respond(404, "text/plain", "no route for #{request.path_info}")
      end

      def chapter_for(domain)
        refuse_unexposed(domain)
        @registry.bluebook(domain) || raise(RouteNotFound, "no domain #{domain.inspect} loaded")
      end

      def entity_command?(chapter, segments)
        entity = chapter.aggregate(segments[1])&.entities&.find { |candidate| candidate.hecks_name == segments[2] }
        !entity&.command(split_format(segments[3]).first).nil?
      end

      def refuse_entity_command
        raise RouteNotFound,
              "entity command routes are not supported by Forms; use a command door with " \
              "to.aggregate and to.entity"
      end

      def refuse_unexposed(domain)
        return if @exposed.include?(domain)

        raise RouteNotFound, "#{domain.inspect} is not exposed by this app — declared chapters: #{@exposed.join(", ")}"
      end

      # Only a trailing ".html"/".json" is a format; other dots belong to the identity
      # (an email, say). An identity ending in ".html" or ".json" stays ambiguous.
      def split_format(segment)
        segment = segment.to_s
        return [Regexp.last_match(1), Regexp.last_match(2)] if segment =~ /\A(.*)\.(html|json)\z/

        [segment, "json"]
      end

      def home(request)
        format = request.params["format"] || "html"
        chapters = @exposed.to_h { |name| [name, @registry.bluebook(name)] }.compact
        return json(200, chapters.transform_values { |c| { aggregates: c.aggregates.map(&:hecks_name) } }) if format != "html"

        html("Exposed domains", IndexRenderer.render(chapters))
      end
    end
  end
end
