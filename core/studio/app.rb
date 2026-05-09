# StudioApp
#
# Sinatra::Base subclass — the runtime layer of the Hecks Studio.
# Boots Hecks against the sibling studio.bluebook + studio.hecksagon
# at load time, then exposes four routes : /health, /statusline,
# /, and POST /commands.
#
# /statusline is the FROZEN endpoint the terminal bar polls. Its
# JSON shape lives in StatuslinePayload ; do not change it without
# co-ordinating with the bar parser. See hazy-spinning-garden.md.
#
# /commands is the dispatch endpoint the tag-driven harness POSTs
# to. Body shape : { "aggregate", "command", "attrs" }. Response
# shape lives in CommandsHandler.
#
# Usage :
#   bundle exec rackup config.ru -p 3100 -o 127.0.0.1
#   curl localhost:3100/health
#   curl localhost:3100/statusline
#   curl -X POST localhost:3100/commands -d '{"aggregate":"...","command":"...","attrs":{}}'
#

require "sinatra/base"
require "sinatra/json"
require "json"
require "time"

require_relative "boot_studio"
require_relative "heki_view"
require_relative "feature_view"
require_relative "statusline_payload"
require_relative "commands_handler"
require_relative "concerns_view"

class StudioApp < Sinatra::Base
  helpers Sinatra::JSON

  set :views, File.expand_path("views", __dir__)
  set :public_folder, File.expand_path("public", __dir__)

  # The studio binds to 127.0.0.1 by design (heki-private body).
  # Host-Authorization is therefore unnecessary noise — and it
  # rejects Rack::Test's default "example.org" host out of the box.
  # Empty list disables the check (rack-protection convention).
  set :host_authorization, permitted_hosts: []

  # ----------------------------------------------------------------
  # Boot — fire Hecks once, at load time, so the runtime is ready
  # for the first request. BootStudio handles the path-shape
  # divergence between Hecks.boot's expected hecks/ subdir and the
  # studio's flat layout (studio.bluebook sits next to app.rb).
  # ----------------------------------------------------------------
  configure do
    set :hecks_runtime, BootStudio.call(__dir__)
  end

  # Class-level accessor the tag_dispatch_spec relies on (line :
  # `STUDIO_APP.respond_to?(:runtime) && STUDIO_APP.runtime`).
  # Same Hecks::Runtime instance that backs every request.
  def self.runtime
    settings.hecks_runtime
  end

  before do
    headers "Access-Control-Allow-Origin"  => "*",
            "Access-Control-Allow-Methods" => "GET, POST, PATCH, DELETE, OPTIONS",
            "Access-Control-Allow-Headers" => "Content-Type"
  end

  # ----------------------------------------------------------------
  # CORS preflight — every method, every path.
  # ----------------------------------------------------------------
  options "*" do
    status 204
    ""
  end

  # ----------------------------------------------------------------
  # /health — runtime liveness + a row per TickedFeature record.
  # JSON shape :
  #   { "status": "ok"|"degraded",
  #     "features": [{ "name", "status",
  #                    "last_tick_at", "expected_interval_ms" }, ...] }
  # ----------------------------------------------------------------
  get "/health" do
    content_type :json
    features = FeatureView.rows(settings.hecks_runtime)
    status_str = features.all? { |f| f[:status] == "running" } ? "ok" : "degraded"
    json status: status_str, features: features
  end

  # ----------------------------------------------------------------
  # /statusline — FROZEN shape. The terminal bar parses this every
  # tick. Adding or removing fields is a breaking change.
  # See StatuslinePayload for the documented schema.
  # ----------------------------------------------------------------
  get "/statusline" do
    content_type :json
    json StatuslinePayload.build(
      runtime: settings.hecks_runtime,
      heki_root: HekiView::DEFAULT_ROOT
    )
  end

  # ----------------------------------------------------------------
  # / — the dashboard view. Server-side ERB, DaisyUI, no JS yet.
  # Renders four sections :
  #   1. Vital signs    (data-domain="Consciousness")
  #   2. Features grid  (data-domain="TickedFeature")
  #   3. Body concerns  (data-domain="Concern")
  #   4. Events stub    (data-domain="event_store")
  # ----------------------------------------------------------------
  get "/" do
    content_type :html
    @payload  = StatuslinePayload.build(
      runtime: settings.hecks_runtime,
      heki_root: HekiView::DEFAULT_ROOT
    )
    @features = @payload[:features]
    @vitals   = {
      state:      @payload[:state],
      last_wake:  @payload[:last_wake],
      last_dream: @payload[:last_dream]
    }
    @concerns       = ConcernsView.recent
    @concerns_total = ConcernsView.window_count(60)
    @concerns_kinds = ConcernsView.window_kinds(60)
    @concerns_alert = ConcernsView.escalating?
    erb :dashboard
  end

  # ----------------------------------------------------------------
  # POST /commands — the dispatch endpoint.
  #
  # Body : { "aggregate", "command", "attrs" } as JSON.
  # See CommandsHandler for the full request/response contract.
  # Tag-driven harness in spec/tag_dispatch_spec.rb POSTs here for
  # every command-shape data-domain tag found in the dashboard.
  # ----------------------------------------------------------------
  post "/commands" do
    content_type :json
    result = CommandsHandler.call(settings.hecks_runtime, request.body.read)
    status result.fetch(:status)
    json   result.fetch(:body)
  end
end
