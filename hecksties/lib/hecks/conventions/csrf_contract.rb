# = Hecks::Conventions::CsrfContract
#
# Double-submit cookie pattern constants and token generation.
# Stateless CSRF protection that works in both Ruby and Go targets
# without session stores.
#
#   token = Hecks::Conventions::CsrfContract.generate_token
#   # => "a3f8c2d1..." (64 hex chars)
#   Hecks::Conventions::CsrfContract::COOKIE_NAME  # => "_csrf_token"
#   Hecks::Conventions::CsrfContract::FIELD_NAME   # => "_csrf_token"
#
require "securerandom"

module Hecks::Conventions
  module CsrfContract
    COOKIE_NAME  = "_csrf_token"
    FIELD_NAME   = "_csrf_token"
    TOKEN_LENGTH = 32

    def self.generate_token
      SecureRandom.hex(TOKEN_LENGTH)
    end

    def self.cookie_header(token)
      "#{COOKIE_NAME}=#{token}; SameSite=Strict; HttpOnly"
    end

    def self.valid?(cookie_value, form_value)
      return false if cookie_value.nil? || cookie_value.empty?
      return false if form_value.nil? || form_value.empty?
      cookie_value == form_value
    end
  end
end
