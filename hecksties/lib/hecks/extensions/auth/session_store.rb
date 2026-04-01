# Hecks::Auth::SessionStore
#
# In-memory credential store and cookie-based session management for
# auth screens. Tracks registered users as a simple hash of email to
# password+role. Sessions are Base64-encoded JSON in an HttpOnly cookie.
#
# This is a development/prototyping store. Production apps should swap
# in a persistent adapter.
#
#   include Hecks::Auth::SessionStore
#   set_session(res, actor)
#   actor = restore_session(req)
#
require "securerandom"
require "json"
require "base64"
require "ostruct"
require "uri"

module Hecks
  module Auth
    module SessionStore
      SESSION_COOKIE = "_hecks_session".freeze

      # Set a session cookie encoding the actor as JSON.
      #
      # @param res [WEBrick::HTTPResponse] the response
      # @param actor [OpenStruct] the authenticated actor
      # @return [void]
      def set_session(res, actor)
        payload = Base64.strict_encode64(
          JSON.generate(email: actor.email, role: actor.role))
        res["Set-Cookie"] =
          "#{SESSION_COOKIE}=#{payload}; Path=/; HttpOnly; SameSite=Lax"
        Hecks.actor = actor
      end

      # Read the session cookie and restore the actor.
      #
      # @param req [WEBrick::HTTPRequest] the request
      # @return [OpenStruct, nil] the actor or nil if no valid session
      def restore_session(req)
        cookie_header = req["Cookie"] || ""
        match = cookie_header.match(
          /(?:^|;\s*)#{Regexp.escape(SESSION_COOKIE)}=([^;]+)/)
        return nil unless match

        data = JSON.parse(Base64.strict_decode64(match[1]))
        OpenStruct.new(email: data["email"], role: data["role"])
      rescue
        nil
      end

      # Look up an actor by email and password from the in-memory store.
      #
      # @param email [String] the user email
      # @param password [String] the plaintext password
      # @return [OpenStruct, nil] the actor or nil
      def resolve_actor(email, password)
        stored = @auth_store&.dig(email)
        return nil unless stored && stored[:password] == password

        OpenStruct.new(email: email, role: stored[:role] || "User")
      end

      # Create a new actor in the in-memory store.
      #
      # @param email [String] the user email
      # @param password [String] the plaintext password
      # @return [OpenStruct] the new actor
      def create_actor(email, password)
        @auth_store ||= {}
        role = default_auth_role
        @auth_store[email] = { password: password, role: role }
        OpenStruct.new(email: email, role: role)
      end

      # Determine the default role for new signups from the domain DSL.
      #
      # @return [String] the first actor role found, or "User"
      def default_auth_role
        @domain.aggregates.each do |agg|
          agg.commands.each do |cmd|
            next unless cmd.respond_to?(:actors) && cmd.actors&.any?
            return cmd.actors.first.name
          end
        end
        "User"
      end

      # Validate signup form fields.
      #
      # @param email [String]
      # @param password [String]
      # @param confirmation [String]
      # @return [String, nil] error message or nil if valid
      def validate_signup(email, password, confirmation)
        return "All fields are required" if email.empty? || password.empty?
        return "Passwords do not match" if password != confirmation
        return "Password must be at least 8 characters" if password.length < 8

        if @auth_store&.key?(email)
          return "An account with that email already exists"
        end

        nil
      end

      # Parse URL-encoded form body params from a POST request.
      #
      # @param req [WEBrick::HTTPRequest] the request
      # @return [Hash{String => String}]
      def parse_form_params(req)
        body = req.body || ""
        URI.decode_www_form(body).to_h
      end
    end
  end
end
