# = csrf_rest_spec
#
# Unit specs for Hecks::HTTP::CsrfHelpers — CSRF protection for JSON/REST routes.
# Uses a lightweight FakeRequest struct so no WEBrick server is started.
#
require "spec_helper"
require "hecks/conventions/csrf_contract"
require "hecks/extensions/serve/csrf_helpers"

RSpec.describe Hecks::HTTP::CsrfHelpers do
  # Minimal fake that quacks like a WEBrick::HTTPRequest for header access.
  FakeRequest = Struct.new(:request_method, :headers, :query_params) do
    def [](name)
      headers[name]
    end

    def query
      query_params || {}
    end
  end

  # Helper to build a request with a CSRF cookie already set.
  def request_with_cookie(token, method: "POST", headers: {})
    cookie = "#{Hecks::Conventions::CsrfContract::COOKIE_NAME}=#{token}"
    FakeRequest.new(method, { "Cookie" => cookie }.merge(headers), {})
  end

  subject(:helper) do
    obj = Object.new
    obj.extend(described_class)
    obj
  end

  # 1. POST without Authorization or X-CSRF-Token → 403 (csrf_required? + !valid)
  describe "#csrf_required? and #valid_csrf_json?" do
    it "requires CSRF for a bare POST with no auth or token" do
      req = FakeRequest.new("POST", {}, {})
      expect(helper.csrf_required?(req)).to be true
      expect(helper.valid_csrf_json?(req)).to be false
    end
  end

  # 2. POST with valid Authorization header → bypasses CSRF
  describe "#token_authenticated?" do
    it "returns true when Authorization header is present" do
      req = FakeRequest.new("POST", { "Authorization" => "Bearer tok123" }, {})
      expect(helper.token_authenticated?(req)).to be true
    end

    it "returns false when Authorization header is absent" do
      req = FakeRequest.new("POST", {}, {})
      expect(helper.token_authenticated?(req)).to be false
    end

    it "csrf_required? is false when Authorization is present" do
      req = FakeRequest.new("POST", { "Authorization" => "Bearer tok123" }, {})
      expect(helper.csrf_required?(req)).to be false
    end
  end

  # 3. POST with matching cookie + X-CSRF-Token header → valid
  describe "#valid_csrf_json? with matching values" do
    it "returns true when cookie and header match" do
      token = "abc123def456"
      req = request_with_cookie(token, headers: {
        Hecks::Conventions::CsrfContract::HEADER_NAME => token
      })
      expect(helper.valid_csrf_json?(req)).to be true
    end
  end

  # 4. POST with mismatched cookie + X-CSRF-Token header → invalid
  describe "#valid_csrf_json? with mismatched values" do
    it "returns false when cookie and header differ" do
      req = request_with_cookie("real-token", headers: {
        Hecks::Conventions::CsrfContract::HEADER_NAME => "wrong-token"
      })
      expect(helper.valid_csrf_json?(req)).to be false
    end
  end

  # 5. GET requests are never blocked by CSRF
  describe "GET requests" do
    it "csrf_required? is false for GET" do
      req = FakeRequest.new("GET", {}, {})
      expect(helper.csrf_required?(req)).to be false
    end
  end

  # 6. DELETE with Authorization → CSRF not required
  describe "DELETE with Authorization header" do
    it "csrf_required? is false when Authorization is present" do
      req = FakeRequest.new("DELETE", { "Authorization" => "Token secret" }, {})
      expect(helper.csrf_required?(req)).to be false
    end
  end

  # 7. PATCH with valid CSRF token → succeeds
  describe "PATCH with valid CSRF cookie + header" do
    it "valid_csrf_json? returns true for PATCH with matching token" do
      token = Hecks::Conventions::CsrfContract.generate_token
      req = request_with_cookie(token, method: "PATCH", headers: {
        Hecks::Conventions::CsrfContract::HEADER_NAME => token
      })
      expect(helper.csrf_required?(req)).to be true
      expect(helper.valid_csrf_json?(req)).to be true
    end
  end

  describe "#read_csrf_cookie" do
    it "parses the CSRF token from a multi-value Cookie header" do
      req = FakeRequest.new("GET", { "Cookie" => "session=abc; _csrf_token=mytoken; other=x" }, {})
      expect(helper.read_csrf_cookie(req)).to eq("mytoken")
    end

    it "returns nil when cookie is absent" do
      req = FakeRequest.new("GET", {}, {})
      expect(helper.read_csrf_cookie(req)).to be_nil
    end
  end

  describe "#ensure_csrf_cookie" do
    FakeResponse = Struct.new(:headers) do
      def []=(key, val)
        headers[key] = val
      end
    end

    it "sets a new cookie when none is present" do
      req = FakeRequest.new("GET", {}, {})
      res = FakeResponse.new({})
      token = helper.ensure_csrf_cookie(req, res)
      expect(token).to match(/\A[0-9a-f]{64}\z/)
      expect(res.headers["Set-Cookie"]).to include("_csrf_token=#{token}")
    end

    it "returns existing cookie without setting a new one" do
      req = request_with_cookie("existing-token")
      res = FakeResponse.new({})
      token = helper.ensure_csrf_cookie(req, res)
      expect(token).to eq("existing-token")
      expect(res.headers["Set-Cookie"]).to be_nil
    end
  end
end
