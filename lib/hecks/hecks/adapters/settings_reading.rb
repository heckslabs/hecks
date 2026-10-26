# frozen_string_literal: true

require "hecks"
require_relative "console_capture"

module Hecks
  module Adapters
    # The `Settings` port's adapter for `Checkout`: what a copy resolves for each setting that can
    # come from a variable, the copy's own world or a default, and which of the three supplied it.
    # It reads and never writes, and prints no secret: a database URL's password is hidden.
    #
    # The query takes `domain`, a domain directory (the current directory when absent), and
    # answers `text:`, one `name: value (source)` line each, then any deprecated variable that is
    # set. A setting the domain cannot resolve is shown as such, not left out.
    class SettingsReading
      # The variables that turn a cache off or choose a stage, each replaced by a command or by
      # git configuration; one that is set is reported.
      DEPRECATED = %w[HECKS_SYNTAX_BOOT_CACHE HECKS_VERDICT_CACHE HECKS_NO_USAGE_CACHE
                      HECKS_PRE_PUSH_GATE].freeze

      # The first line of a message.
      FIRST_LINE = /\A[^\n]*/

      # A URL's password: `user:secret@` becomes `user:***@`.
      PASSWORD = %r{(://[^:/@\s]+):[^@\s]+@}

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # @param held [Hash] `domain`, a domain directory
      # @return [Hash{Symbol => String}] `text:` the resolved settings
      # @raise [ConsoleCapture::Failure] when the directory is not there
      def settings(**held)
        directory = plain(held[:domain]) || Dir.pwd
        raise ConsoleCapture::Failure, "#{directory} is not a directory" unless File.directory?(directory)

        { text: (rows(directory).map { |row| line_of(*row) } + deprecated).join("\n") }
      end

      private

      def rows(directory)
        [environment, database(directory), schema, project_environment,
         variable_or_default("cache directory", "HECKS_CACHE_DIR", usage_cache_directory),
         variable_or_default("rust workspace", "HECKS_RUST_DIR", RustBuild.rust_dir),
         registry_source(directory)]
      end

      def line_of(name, value, source) = "#{name}: #{value} (#{source})"

      def environment
        named = ENV.fetch("HECKS_ENVIRONMENT", "")
        named.empty? ? ["environment", "none", "default"] : ["environment", named, "variable HECKS_ENVIRONMENT"]
      end

      # The world's `default_database`, and which of the variable, the copy's
      # `environments/local.world` or the world itself supplied it.
      def database(directory)
        value = declared_database(directory) || "none declared"
        ["database", hide_password(value), database_source(directory)]
      rescue StandardError => e
        ["database", "could not be read", first_line(e.message)]
      end

      def database_source(directory)
        return "variable HECKS_DATABASE, deprecated: name it in environments/local.world" if ENV["HECKS_DATABASE"]
        return "environments/local.world" if File.exist?(File.join(directory, "environments", "local.world"))

        "world"
      end

      def declared_database(directory)
        registry = Hecks.describe(directory).registry
        name = registry.first_domain_name
        name && registry.default_database_for(name)
      end

      def first_line(text) = text.to_s[FIRST_LINE].strip

      def schema
        return ["schema", ENV.fetch("HECKS_SCHEMA"), "variable HECKS_SCHEMA"] unless ENV.fetch("HECKS_SCHEMA", "").empty?

        ["schema", "the world's, else one derived from the domain's name", "default"]
      end

      def project_environment
        named = ENV.fetch("HECKS_PROJECT_ENVIRONMENT", "")
        return ["project environment", "none", "default"] if named.empty?

        ["project environment", named, "variable HECKS_PROJECT_ENVIRONMENT"]
      end

      def usage_cache_directory
        require "hecks/adapters/driving/usage_cache"
        Hecks::Adapters::Driving::UsageCache.directory
      end

      def registry_source(directory)
        require "hecks/embryonaut_bluebook/vendor_cli"
        found = Hecks::EmbryonautBluebook::VendorCli.default_source(directory)
        return ["registry source", "none found", "default"] unless found

        named = ENV.fetch("EMBRYONAUT_BLUEBOOKS_SRC", nil)
        ["registry source", found, named ? "variable EMBRYONAUT_BLUEBOOKS_SRC" : "beside the project"]
      end

      def variable_or_default(name, variable, value)
        [name, value, ENV.fetch(variable, nil) ? "variable #{variable}" : "default"]
      end

      def deprecated
        set = DEPRECATED.select { |name| ENV.fetch(name, nil) }
        set.empty? ? [] : ["deprecated variables set: #{set.join(", ")}"]
      end

      def hide_password(url) = url.to_s.gsub(PASSWORD, '\1:***@')

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
