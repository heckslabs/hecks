require "spec_helper"
require "hecks/extensions/auth"
require "hecks/extensions/auth/screen_routes"
require "ostruct"
require "base64"
require "json"

RSpec.describe "Auth Screens" do
  let(:domain) do
    Hecks.domain "AuthScreens" do
      aggregate "Account" do
        attribute :email, String
        attribute :balance, Float

        command "Deposit" do
          actor "Admin"
          attribute :amount, Float
        end
      end
    end
  end

  # Minimal request/response doubles for testing without WEBrick
  let(:cookies) { {} }

  def make_req(method, path, body: nil, cookie: nil)
    req = OpenStruct.new(
      request_method: method,
      path: path,
      body: body,
      query: {}
    )
    req.define_singleton_method(:[]) do |name|
      return cookie if name == "Cookie"
      nil
    end
    req
  end

  def make_res
    headers = {}
    res = OpenStruct.new(status: 200, body: nil)
    res.define_singleton_method(:[]=) { |k, v| headers[k] = v }
    res.define_singleton_method(:[]) { |k| headers[k] }
    res.define_singleton_method(:headers) { headers }
    res.define_singleton_method(:set_redirect) { |_status, loc| headers["Location"] = loc }
    res
  end

  # Build a test object that includes the mixin
  let(:handler) do
    d = domain
    obj = Object.new
    obj.instance_variable_set(:@domain, d)
    obj.instance_variable_set(:@auth_store, {})
    obj.extend(Hecks::HTTP::CsrfHelpers)
    obj.extend(Hecks::Auth::ScreenRoutes)
    obj
  end

  before do
    @app = Hecks.load(domain)
  end

  after { Hecks.actor = nil }

  describe "auth_route?" do
    it "recognizes login path" do
      expect(handler.auth_route?("/login")).to be true
    end

    it "recognizes signup path" do
      expect(handler.auth_route?("/signup")).to be true
    end

    it "recognizes logout path" do
      expect(handler.auth_route?("/logout")).to be true
    end

    it "rejects non-auth paths" do
      expect(handler.auth_route?("/accounts")).to be false
    end
  end

  describe "GET /login" do
    it "renders the login form HTML" do
      req = make_req("GET", "/login")
      res = make_res
      handler.handle_auth_route(req, res)

      expect(res["Content-Type"]).to eq("text/html")
      expect(res.body).to include("Login")
      expect(res.body).to include('action="/login"')
      expect(res.body).to include('type="email"')
      expect(res.body).to include('type="password"')
    end
  end

  describe "GET /signup" do
    it "renders the signup form HTML" do
      req = make_req("GET", "/signup")
      res = make_res
      handler.handle_auth_route(req, res)

      expect(res["Content-Type"]).to eq("text/html")
      expect(res.body).to include("Create Account")
      expect(res.body).to include('action="/signup"')
      expect(res.body).to include("password_confirmation")
    end
  end

  describe "POST /signup" do
    it "creates an account and redirects" do
      body = URI.encode_www_form(
        "email" => "test@example.com",
        "password" => "secret123",
        "password_confirmation" => "secret123"
      )
      req = make_req("POST", "/signup", body: body)
      res = make_res
      handler.handle_auth_route(req, res)

      expect(res.headers["Location"]).to eq("/")
      expect(res["Set-Cookie"]).to include("_hecks_session=")
    end

    it "rejects mismatched passwords" do
      body = URI.encode_www_form(
        "email" => "test@example.com",
        "password" => "secret123",
        "password_confirmation" => "different"
      )
      req = make_req("POST", "/signup", body: body)
      res = make_res
      handler.handle_auth_route(req, res)

      expect(res.body).to include("Passwords do not match")
    end

    it "rejects short passwords" do
      body = URI.encode_www_form(
        "email" => "test@example.com",
        "password" => "short",
        "password_confirmation" => "short"
      )
      req = make_req("POST", "/signup", body: body)
      res = make_res
      handler.handle_auth_route(req, res)

      expect(res.body).to include("Password must be at least 8 characters")
    end
  end

  describe "POST /login" do
    before do
      # Register a user first
      body = URI.encode_www_form(
        "email" => "user@example.com",
        "password" => "password123",
        "password_confirmation" => "password123"
      )
      req = make_req("POST", "/signup", body: body)
      handler.handle_auth_route(req, make_res)
    end

    it "authenticates valid credentials and redirects" do
      body = URI.encode_www_form(
        "email" => "user@example.com",
        "password" => "password123"
      )
      req = make_req("POST", "/login", body: body)
      res = make_res
      handler.handle_auth_route(req, res)

      expect(res.headers["Location"]).to eq("/")
      expect(res["Set-Cookie"]).to include("_hecks_session=")
    end

    it "rejects invalid credentials" do
      body = URI.encode_www_form(
        "email" => "user@example.com",
        "password" => "wrong"
      )
      req = make_req("POST", "/login", body: body)
      res = make_res
      handler.handle_auth_route(req, res)

      expect(res.body).to include("Invalid email or password")
    end

    it "rejects empty fields" do
      body = URI.encode_www_form("email" => "", "password" => "")
      req = make_req("POST", "/login", body: body)
      res = make_res
      handler.handle_auth_route(req, res)

      expect(res.body).to include("Email and password are required")
    end
  end

  describe "GET /logout" do
    it "clears the session and redirects to login" do
      Hecks.actor = OpenStruct.new(role: "Admin")
      req = make_req("GET", "/logout")
      res = make_res
      handler.handle_auth_route(req, res)

      expect(res.headers["Location"]).to eq("/login")
      expect(res["Set-Cookie"]).to include("Max-Age=0")
      expect(Hecks.actor).to be_nil
    end
  end

  describe "session restore" do
    it "restores actor from session cookie" do
      payload = Base64.strict_encode64(
        JSON.generate(email: "test@example.com", role: "Admin"))
      cookie = "_hecks_session=#{payload}"
      req = make_req("GET", "/login", cookie: cookie)

      actor = handler.restore_session(req)
      expect(actor.email).to eq("test@example.com")
      expect(actor.role).to eq("Admin")
    end

    it "returns nil for missing session" do
      req = make_req("GET", "/login")
      expect(handler.restore_session(req)).to be_nil
    end
  end

  describe "default role detection" do
    it "picks the first actor role from domain commands" do
      role = handler.send(:default_auth_role)
      expect(role).to eq("Admin")
    end
  end
end
