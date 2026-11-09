require "pg"

module Hecks
  # The connection option every Postgres connection of this process carries, so libpq never
  # asks the macOS Kerberos framework for a credential cache.
  #
  # On a first connection attempt libpq probes the security service (`pg_GSS_have_cred_cache`),
  # which sets up Objective-C classes in the Kerberos framework. In a process that forked without
  # exec, as a resident's children do, that aborts or crashes the child. `gssencmode=disable`
  # skips the probe, so the connection never touches the framework. A caller that names
  # `gssencmode` itself, in a string, a URL or a hash, keeps its value.
  #
  # Requiring this file requires `pg` and installs the option; there is no other setup.
  module PgOptions
    # The libpq keyword, and the value every connection gets unless the caller chose one.
    KEYWORD = "gssencmode".freeze
    DEFAULT = "disable".freeze

    # The first libpq version that knows the keyword (PostgreSQL 12).
    MINIMUM_LIBPQ = 120_000

    # Prepended to the pg gem's connection class methods.
    module Connecting
      # @return [String] the connection string, with the option added when none names it
      def parse_connect_args(*args)
        super(*PgOptions.arguments(args))
      end

      # @return [PG::Connection] a connection started with the option added when none names it
      def connect_start(*args)
        super(*PgOptions.started(args))
      end

      # @return [Integer] the ping result, with the option added when none names it
      def ping(*args)
        super(*PgOptions.arguments(args))
      end
    end

    class << self
      # Adds the option to the arguments of a connection, unless one of them names it.
      #
      # @param args [Array] what `PG.connect` takes: a string, a URL, positional values or a hash
      # @return [Array] the arguments, with a hash carrying the option last
      def arguments(args)
        return args if named?(args)

        args = args.dup
        options = args.last.is_a?(Hash) ? args.pop : {}
        args << { KEYWORD.to_sym => DEFAULT }.merge(options.transform_keys(&:to_sym))
      end

      # Adds the option to what `connect_start` takes: one string, URL or hash.
      #
      # @param args [Array] the arguments of `connect_start`
      # @return [Array] the arguments with the option added
      def started(args)
        return args if named?(args) || args.length != 1

        [with_option(args.first)]
      end

      # Installs the option on the pg gem, when its libpq knows the keyword.
      #
      # @return [Module, nil] this module once installed, nil on an older libpq
      def install!
        return if PG.library_version < MINIMUM_LIBPQ

        singleton = PG::Connection.singleton_class
        singleton.prepend(Connecting) unless singleton.include?(Connecting)
        self
      end

      private

      def named?(args)
        args.any? { |arg| arg.is_a?(Hash) ? hash_names?(arg) : arg.to_s.include?(KEYWORD) }
      end

      def hash_names?(hash)
        hash.keys.any? { |key| key.to_s == KEYWORD }
      end

      def with_option(conninfo)
        return { KEYWORD.to_sym => DEFAULT }.merge(conninfo.transform_keys(&:to_sym)) if conninfo.is_a?(Hash)

        text = conninfo.to_s
        return "#{text}#{text.include?("?") ? "&" : "?"}#{KEYWORD}=#{DEFAULT}" if text.include?("://")

        "#{text} #{KEYWORD}=#{DEFAULT}".strip
      end
    end
  end
end

Hecks::PgOptions.install!
