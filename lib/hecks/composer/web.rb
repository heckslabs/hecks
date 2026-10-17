require "json"
require "rack"
require_relative "../composer"
require_relative "assistant"
require_relative "panels"

module Hecks
  module Composer
    # The Composer's driving side, on the hecksagon side: a Rack app that serves the editor page
    # and the JSON routes it speaks to, over one workspace directory. It binds no business
    # meaning. The routes are the three tables below: the page and files, the editor's own
    # (save, remove, parse, check, ask), and the lower panels', which {Panels} answers.
    class Web
      PAGE = File.expand_path("page.html", __dir__).freeze
      PREFIX = "/composer".freeze

      # @param workspace [String] the domain directory the editor opens
      # @param agents [Runtime::Registry, nil] a registry holding the `composer_agent` port and one
      #   adapter; the one `HECKS_COMPOSER_AGENT` names (`claude`, the default, or `fake`) when nil
      # @return [Web] a Rack app
      def self.app(workspace:, agents: nil) = new(workspace: workspace, agents: agents)

      # @param workspace [String] the domain directory the editor opens
      # @param agents [Runtime::Registry, nil] see {app}
      def initialize(workspace:, agents: nil)
        @workspace = File.expand_path(workspace)
        @agents = agents
      end

      # @param env [Hash] the Rack environment
      # @return [Array] the Rack response triple
      def call(env)
        request = Rack::Request.new(env)
        route(request)
      rescue Workspace::OutsideWorkspace, KeyError, JSON::ParserError => e
        json(400, error: e.message)
      rescue Parse::ParserMissing => e
        json(503, error: e.message)
      end

      private

      # Routes that answer from the workspace alone, those that read a JSON body first, and those
      # the lower panels ask (answered by {Panels}).
      READS = { "GET " => :page, "GET #{PREFIX}" => :page, "GET #{PREFIX}/files" => :listing,
                "GET #{PREFIX}/draft" => :conversation }.freeze
      WRITES = { "PUT #{PREFIX}/file" => :save, "DELETE #{PREFIX}/file" => :remove,
                 "POST #{PREFIX}/parse" => :parse, "POST #{PREFIX}/check" => :check,
                 "POST #{PREFIX}/ask" => :ask }.freeze
      PANEL_ROUTES = { "POST #{PREFIX}/live/commands" => :commands, "POST #{PREFIX}/live/dispatch" => :dispatch,
                       "POST #{PREFIX}/live/records" => :records, "POST #{PREFIX}/behaviors" => :behaviors,
                       "POST #{PREFIX}/timeline" => :timeline, "GET #{PREFIX}/catalog" => :catalog,
                       "POST #{PREFIX}/help" => :help, "POST #{PREFIX}/run" => :run,
                       "GET #{PREFIX}/eras" => :eras, "POST #{PREFIX}/job" => :start_job,
                       "GET #{PREFIX}/job" => :job_state, "DELETE #{PREFIX}/job" => :cancel_job }.freeze
      private_constant :READS, :WRITES, :PANEL_ROUTES

      def route(request)
        key = "#{request.request_method} #{request.path_info.chomp("/")}"
        answer_for(key, request) || json(404, error: "no such route")
      end

      # The response the key's table gives, or nil when no table has the key.
      def answer_for(key, request)
        return send(READS[key]) if READS.key?(key)
        return send(WRITES[key], body(request)) if WRITES.key?(key)

        json(200, panels.public_send(PANEL_ROUTES[key], body(request))) if PANEL_ROUTES.key?(key)
      end

      def panels = @panels ||= Panels.new(workspace: @workspace, session: session)

      def listing = json(200, files: files)

      def conversation = json(200, draft: session.summary(slug))

      def ask(body)
        json(200, assistant.ask(body.fetch("prompt")))
      rescue Agent::Unavailable => e
        json(503, error: e.message)
      rescue Agent::ValidationError => e
        json(502, error: e.message)
      end

      def slug = File.basename(@workspace)

      def session = @session ||= Session.new

      def assistant = @assistant ||= Assistant.new(workspace: @workspace, agents: agents, session: session)

      def agents = @agents ||= default_agents

      # The adapter `HECKS_COMPOSER_AGENT` names: the real `claude`, or a scripted `fake`.
      def default_agents
        name = ENV.fetch("HECKS_COMPOSER_AGENT", "claude") == "fake" ? "fake_agent" : "claude_composer"
        require_relative "adapters/#{name}"
        Agent.registry_with(File.join(Agent::ADAPTERS, "#{name}.adapter"))
      end

      def page = [200, { "content-type" => "text/html; charset=utf-8" }, [File.read(PAGE)]]

      def files
        Workspace.files(@workspace).map { |path| { path: path, text: File.read(File.join(@workspace, path)) } }
      end

      def save(body)
        path = body.fetch("path")
        Workspace.refuse_escapes!([path])
        return json(400, error: "#{path.inspect} is not a domain file") unless declaration?(path)

        target = File.join(@workspace, path)
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, body.fetch("text"))
        session.record(path: path, text: body.fetch("text"))
        json(200, saved: path)
      end

      def remove(body)
        path = body.fetch("path")
        Workspace.refuse_escapes!([path])
        return json(400, error: "#{path.inspect} is not a domain file") unless declaration?(path)

        FileUtils.rm_f(File.join(@workspace, path))
        json(200, removed: path)
      end

      def parse(body)
        refusal = Workspace.stage(dir: @workspace, buffers: buffers(body)) { |stage| Parse.call(stage) }
        json(200, diagnostic: refusal)
      end

      def check(body)
        json(200, Check.call(dir: @workspace, buffers: buffers(body), chapter_name: body["chapter_name"]))
      end

      def declaration?(path) = Workspace::EXTENSIONS.include?(File.extname(path).delete_prefix("."))

      def buffers(body) = body.fetch("buffers", {})

      def body(request)
        raw = request.body&.read.to_s
        raw.empty? ? {} : JSON.parse(raw)
      end

      def json(status, payload)
        [status, { "content-type" => "application/json" }, [JSON.generate(payload)]]
      end
    end
  end
end
