# frozen_string_literal: true

require "open3"
require_relative "launcher_options"

module Hecks
  module Adapters
    module Driving
      # The one line a command prints before it writes: which checkout it runs in, the store each
      # bluebook uses, and the audience the launcher lists for. It reads only, through the store
      # resolution `hecks config` uses, so the line cannot disagree with a boot.
      module ContextLine
        MEMORY = "Memory"

        # The store of a bluebook, as a label with no aggregate in it.
        BLUEBOOK_STORE = /\Astore [^:]+\z/

        # The storage kinds a store description starts with.
        SQLITE_STORE = /\ASqlite/i
        POSTGRES_STORE = /\APostgres/

        module_function

        # Prints the line on a terminal; a pipe or a file gets nothing, so stdout stays clean.
        #
        # @param err [#tty?, #puts] where the line goes
        # @param directory [String] the checkout a command runs in
        # @return [String, nil] the line printed, or nil when nothing was printed
        def announce(err, directory: Dir.pwd)
          return unless err.respond_to?(:tty?) && err.tty?

          require_relative "../../hecks/adapters/settings_reading"

          text = line(directory: directory, stores: SettingsReading.new.stores(directory),
                      audience: audience(directory))
          err.puts(text)
          text
        end

        # @param directory [String] the checkout a command runs in
        # @param stores [Array<Array(String, String, String)>] store rows, as `stores` answers them
        # @param audience [String] the audience the launcher lists for
        # @return [String] the line
        def line(directory:, stores:, audience:)
          ["checkout #{File.basename(directory)} (#{branch(directory)})", stored(stores),
           "audience #{audience}"].join(" · ")
        end

        # @param stores [Array<Array(String, String, String)>] store rows
        # @return [String] "Tickets in SQLite" for each bluebook off Memory, else Memory
        def stored(stores)
          found = stores.filter_map do |label, value, _source|
            next unless label.match?(BLUEBOOK_STORE) && kind(value) != MEMORY

            "#{label.delete_prefix("store ")} in #{kind(value)}"
          end
          found.empty? ? MEMORY : found.join(", ")
        end

        # @param value [String] a store's description, as the rows give it
        # @return [String] the store's kind
        def kind(value)
          case value.to_s
          when SQLITE_STORE then "SQLite"
          when POSTGRES_STORE then "Postgres"
          else value.to_s.split.first || MEMORY
          end
        end

        # @param directory [String]
        # @return [String] the checked-out branch, or "detached" when there is none
        def branch(directory)
          out, status = Open3.capture2e("git", "-C", directory, "symbolic-ref", "--short", "HEAD")
          status.success? ? out.strip : "detached"
        end

        # @param directory [String]
        # @return [String] "maintainer" inside a hecks checkout, else "person"
        def audience(directory)
          LauncherOptions.maintainer?(directory) ? "maintainer" : "person"
        end
      end
    end
  end
end
