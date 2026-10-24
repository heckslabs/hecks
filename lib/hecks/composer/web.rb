require "json"
require "rack"
require_relative "../composer"
require_relative "domains"
require_relative "workbench"

module Hecks
  module Composer
    # The Composer's driving side, on the hecksagon side: a Rack app that serves the editor page
    # and the JSON routes it speaks to, over one workspace directory at a time. It binds no
    # business meaning. The routes are the tables below: the page and files, the editor's own
    # (save, remove, parse, check, ask), the domain list, and the lower panels', which {Panels}
    # answers.
    class Web
      PAGE = File.expand_path("page.html", __dir__).freeze
      PREFIX = "/composer".freeze

      # @param workspace [String] the domain directory the editor opens
      # @param agents [Runtime::Registry, nil] see {Workbench#initialize}
      # @param root [String] the checkout whose domains the picker lists
      # @return [Web] a Rack app
      def self.app(workspace:, agents: nil, root: Parse::ROOT) = new(workspace: workspace, agents: agents, root: root)

      # @param workspace [String] the domain directory the editor opens
      # @param agents [Runtime::Registry, nil] see {Workbench#initialize}
      # @param root [String] the checkout whose domains the picker lists
      def initialize(workspace:, agents: nil, root: Parse::ROOT)
        @agents = agents
        @root = File.expand_path(root)
        @bench = Workbench.new(workspace: workspace, agents: agents)
      end

      # @param env [Hash] the Rack environment
      # @return [Array] the Rack response triple
      def call(env)
        request = Rack::Request.new(env)
        route(request)
      rescue Workspace::OutsideWorkspace, KeyError, JSON::ParserError => e
        json(400, error: e.message)
      rescue Domains::Unknown => e
        json(404, error: e.message)
      rescue Parse::ParserMissing => e
        json(503, error: e.message)
      end

      private

      # Routes that answer from the workspace alone, those that read a JSON body first, and those
      # the lower panels ask (answered by {Panels}).
      READS = { "GET " => :page, "GET #{PREFIX}" => :page, "GET #{PREFIX}/files" => :listing,
                "GET #{PREFIX}/draft" => :conversation, "GET #{PREFIX}/domains" => :domains }.freeze
      WRITES = { "PUT #{PREFIX}/file" => :save, "DELETE #{PREFIX}/file" => :remove,
                 "POST #{PREFIX}/parse" => :parse, "POST #{PREFIX}/check" => :check,
                 "POST #{PREFIX}/ask" => :ask, "POST #{PREFIX}/open" => :open_domain }.freeze
      PANEL_ROUTES = { "POST #{PREFIX}/live/commands" => :commands, "POST #{PREFIX}/live/dispatch" => :dispatch,
                       "POST #{PREFIX}/live/records" => :records, "POST #{PREFIX}/behaviors" => :behaviors,
                       "POST #{PREFIX}/timeline" => :timeline, "POST #{PREFIX}/board/edit" => :board_edit,
                       "GET #{PREFIX}/catalog" => :catalog,
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

        json(200, @bench.panels.public_send(PANEL_ROUTES[key], body(request))) if PANEL_ROUTES.key?(key)
      end

      def workspace = @bench.workspace

      def listing = json(200, files: files)

      def conversation = json(200, draft: @bench.session.summary(@bench.slug))

      # The known domains, and the directory the editor has open now.
      def domains = json(200, domains: Domains.known(root: @root), current: File.basename(workspace))

      # Opens a known domain as a scratch copy, replacing everything kept for the old workspace.
      def open_domain(body)
        id = body.fetch("id")
        opened = Domains.open(root: @root, id: id)
        @bench.close
        @bench = Workbench.new(workspace: opened, agents: @agents)
        json(200, opened: id, current: File.basename(opened))
      end

      def ask(body)
        json(200, @bench.assistant.ask(body.fetch("prompt")))
      rescue Agent::Unavailable => e
        json(503, error: e.message)
      rescue Agent::ValidationError => e
        json(502, error: e.message)
      end

      def page = [200, { "content-type" => "text/html; charset=utf-8" }, [File.read(PAGE)]]

      def files
        Workspace.files(workspace).map { |path| { path: path, text: File.read(File.join(workspace, path)) } }
      end

      def save(body)
        path = domain_path(body) or return refused(body)

        target = File.join(workspace, path)
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, body.fetch("text"))
        @bench.session.record(path: path, text: body.fetch("text"))
        json(200, saved: path)
      end

      def remove(body)
        path = domain_path(body) or return refused(body)

        FileUtils.rm_f(File.join(workspace, path))
        json(200, removed: path)
      end

      # The request's path when it names a domain file inside the workspace, else nil.
      def domain_path(body)
        path = body.fetch("path")
        Workspace.refuse_escapes!([path])
        path if Workspace::EXTENSIONS.include?(File.extname(path).delete_prefix("."))
      end

      def refused(body) = json(400, error: "#{body["path"].inspect} is not a domain file")

      def parse(body)
        refusal = Workspace.stage(dir: workspace, buffers: buffers(body)) { |stage| Parse.call(stage) }
        json(200, diagnostic: refusal)
      end

      def check(body)
        json(200, Check.call(dir: workspace, buffers: buffers(body), chapter_name: body["chapter_name"]))
      end

      def buffers(body) = body.fetch("buffers", {})

      def body(request)
        stream = request.body
        raw = stream&.read.to_s
        raw.empty? ? {} : JSON.parse(raw)
      end

      def json(status, payload)
        [status, { "content-type" => "application/json" }, [JSON.generate(payload)]]
      end
    end
  end
end
