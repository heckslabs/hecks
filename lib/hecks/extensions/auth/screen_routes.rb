# Hecks::Auth::ScreenRoutes
#
# Mixin for DomainServer that adds login, signup, and logout HTTP
# routes when the auth extension is active. Renders ERB templates
# from the auth/views directory with inline CSS (no JS framework).
# Uses a session cookie to track the authenticated actor.
#
# Routes:
#   GET  /login  — render login form
#   POST /login  — authenticate and set session cookie
#   GET  /signup — render signup form
#   POST /signup — create account and set session cookie
#   GET  /logout — clear session cookie and redirect to login
#
#   include Hecks::Auth::ScreenRoutes
#   # then call handle_auth_route(req, res) from the server dispatch
#
require "erb"
Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Extensions::AuthChapter,
  base_dir: __dir__
)

module Hecks
  module Auth
    # Hecks::Auth::ScreenRoutes
    #
    # Mixin for DomainServer that adds login, signup, and logout HTTP routes when the auth extension is active.
    #
    module ScreenRoutes
      include SessionStore

      VIEWS_DIR = File.expand_path("views", __dir__)
      AUTH_PATHS = %w[/login /signup /logout].freeze

      # Check whether the request path is an auth screen route.
      #
      # @param path [String] the request path
      # @return [Boolean]
      def auth_route?(path)
        AUTH_PATHS.include?(path)
      end

      # Dispatch an auth route request to the appropriate handler.
      #
      # @param req [WEBrick::HTTPRequest] the incoming request
      # @param res [WEBrick::HTTPResponse] the outgoing response
      # @return [void]
      def handle_auth_route(req, res)
        case [req.request_method, req.path]
        when ["GET", "/login"]   then render_login(req, res)
        when ["POST", "/login"]  then process_login(req, res)
        when ["GET", "/signup"]  then render_signup(req, res)
        when ["POST", "/signup"] then process_signup(req, res)
        when ["GET", "/logout"]  then process_logout(req, res)
        end
      end

      private

      # Render the login form.
      def render_login(req, res)
        token = ensure_csrf_cookie(req, res)
        serve_auth_html(res, :login, error_message: nil, csrf_token: token)
      end

      # Authenticate the user and set a session cookie.
      def process_login(req, res)
        params = parse_form_params(req)
        email = params["email"].to_s.strip
        password = params["password"].to_s

        if email.empty? || password.empty?
          token = read_csrf_cookie(req) || ensure_csrf_cookie(req, res)
          serve_auth_html(res, :login,
            error_message: "Email and password are required",
            csrf_token: token)
          return
        end

        actor = resolve_actor(email, password)
        unless actor
          token = read_csrf_cookie(req) || ensure_csrf_cookie(req, res)
          serve_auth_html(res, :login,
            error_message: "Invalid email or password",
            csrf_token: token)
          return
        end

        set_session(res, actor)
        res.set_redirect(WEBrick::HTTPStatus::SeeOther, "/")
      end

      # Render the signup form.
      def render_signup(req, res)
        token = ensure_csrf_cookie(req, res)
        serve_auth_html(res, :signup, error_message: nil, csrf_token: token)
      end

      # Create a new account and set a session cookie.
      def process_signup(req, res)
        params = parse_form_params(req)
        email = params["email"].to_s.strip
        password = params["password"].to_s
        confirmation = params["password_confirmation"].to_s

        error = validate_signup(email, password, confirmation)
        if error
          token = read_csrf_cookie(req) || ensure_csrf_cookie(req, res)
          serve_auth_html(res, :signup,
            error_message: error, csrf_token: token)
          return
        end

        actor = create_actor(email, password)
        set_session(res, actor)
        res.set_redirect(WEBrick::HTTPStatus::SeeOther, "/")
      end

      # Clear the session cookie and redirect to login.
      def process_logout(_req, res)
        cookie = "#{SessionStore::SESSION_COOKIE}=; Path=/; Max-Age=0; HttpOnly"
        res["Set-Cookie"] = cookie
        Hecks.actor = nil
        res.set_redirect(WEBrick::HTTPStatus::SeeOther, "/login")
      end

      # Render an auth template and set the response body.
      def serve_auth_html(res, name, **locals)
        html = render_auth_template(name, **locals)
        res["Content-Type"] = "text/html"
        res.body = html
      end

      # Render an auth ERB template with the given locals.
      #
      # @param name [Symbol] template name (:login or :signup)
      # @param locals [Hash] template variables
      # @return [String] rendered HTML
      def render_auth_template(name, **locals)
        locals[:domain_name] = @domain.name
        path = File.join(VIEWS_DIR, "#{name}.erb")
        template = File.read(path)
        b = Hecks::Auth::TemplateBinding.new(locals)
        ERB.new(template, trim_mode: "-").result(b.get_binding)
      end
    end

    # Minimal binding for auth screen ERB templates.
    # Locals become methods so templates can reference them directly.
    class TemplateBinding
      def initialize(locals)
        locals.each { |k, v| define_singleton_method(k) { v } }
      end

      def h(text)
        ERB::Util.html_escape(text.to_s)
      end

      def get_binding
        binding
      end
    end
  end
end
