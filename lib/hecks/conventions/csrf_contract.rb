# = Hecks::Conventions::CsrfContract
#
# Double-submit cookie pattern constants and token generation.
# Stateless CSRF protection that works in both Ruby and Go targets
# without session stores. Covers both HTML forms (FIELD_NAME) and
# JSON/REST clients (HEADER_NAME + X-CSRF-Token).
#
#   token = Hecks::Conventions::CsrfContract.generate_token
#   # => "a3f8c2d1..." (64 hex chars)
#   Hecks::Conventions::CsrfContract::COOKIE_NAME  # => "_csrf_token"
#   Hecks::Conventions::CsrfContract::HEADER_NAME  # => "X-CSRF-Token"
#
require "securerandom"

module Hecks::Conventions
  # Hecks::Conventions::CsrfContract
  #
  # Double-submit cookie constants and token generation for stateless CSRF protection.
  #
  module CsrfContract
    COOKIE_NAME      = "_csrf_token"
    FIELD_NAME       = "_csrf_token"
    HEADER_NAME      = "X-CSRF-Token"
    TOKEN_LENGTH     = 32
    MUTATING_METHODS = %w[POST PATCH PUT DELETE].freeze

    def self.generate_token
      SecureRandom.hex(TOKEN_LENGTH)
    end

    # Cookie header without HttpOnly so SPA clients can read via document.cookie.
    # Security comes from SameSite=Strict (same-origin enforcement).
    def self.cookie_header(token)
      "#{COOKIE_NAME}=#{token}; SameSite=Strict"
    end

    def self.valid?(cookie_value, form_value)
      return false if cookie_value.nil? || cookie_value.empty?
      return false if form_value.nil? || form_value.empty?
      cookie_value == form_value
    end
  end
end
