require_relative "../naming"

module Hecks
  module CLI
    # The files `hecks init` writes: a stub domain that boots as it stands and that the author
    # then edits into a real one (ADR 0087).
    #
    # Pure: it answers the text of each file and writes none, so the adapter that does the writing
    # can check every target before it writes the first, and a spec can boot the result.
    module DomainStub
      # A domain's name: a capital, then letters and digits, as its bluebook spells it.
      NAME = /\A[A-Z][A-Za-z0-9]*\z/

      SQLITE_URL = 'default_database "data/%<snake>s.db"'.freeze
      POSTGRES_URL = 'default_database "postgres://localhost/%<snake>s"'.freeze
      private_constant :SQLITE_URL, :POSTGRES_URL

      # Persistence adapters a stub can be bound to, each with the world lines that bind it, the
      # data it keeps under `data/` (so a `.gitignore` is written), and whether it needs a server
      # (so a memory overlay is written and the first run needs no database).
      ADAPTERS = {
        "Memory"            => { world: ['default_adapter "Memory"'], local_data: false, server: false },
        "SqlitePersistence" => { world: ['default_adapter "SqlitePersistence"', SQLITE_URL],
                                 local_data: true, server: false },
        "Heki"              => { world: ['default_adapter "Heki"', 'persisted_by("Heki") { dir "data" }'],
                    local_data: true, server: false },
        "Postgres"          => { world: ['default_adapter "Postgres"', POSTGRES_URL],
                        local_data: false, server: true },
        "PostgresEra"       => { world: ['default_adapter "PostgresEra"', POSTGRES_URL],
                           local_data: false, server: true }
      }.freeze

      # What `init` binds a stub to when no adapter is named: it needs no server and keeps its data.
      DEFAULT_ADAPTER = "SqlitePersistence".freeze

      module_function

      # @return [Array<String>] the adapter names `init` accepts
      def adapters = ADAPTERS.keys

      # @param name [String] the domain's name, as its bluebook spells it (`Lending`)
      # @param adapter [String, nil] an adapter named in `ADAPTERS`; the default when nil
      # @return [Hash{String => String}] each file's path under the domain directory, and its text
      # @raise [ArgumentError] when the name is not a capitalised word or the adapter is unknown
      def files(name:, adapter: nil)
        adapter ||= DEFAULT_ADAPTER
        check!(name, adapter)
        { "bluebook/#{Naming.snake(name)}.bluebook" => bluebook(name) }.merge(support_files(name: name, adapter: adapter))
      end

      # The files around a domain's bluebook: its world bound to the adapter, the memory overlay for
      # an adapter that needs a server, and a `.gitignore` for one that keeps data. `hecks init`
      # writes them beside a stub, and an interview draft beside the bluebook it renders (ADR 0088).
      #
      # @param name [String] the domain's name
      # @param adapter [String, nil] an adapter named in `ADAPTERS`; the default when nil
      # @return [Hash{String => String}] each file's path under the domain directory, and its text
      # @raise [ArgumentError] when the name is not a capitalised word or the adapter is unknown
      def support_files(name:, adapter: nil)
        adapter ||= DEFAULT_ADAPTER
        check!(name, adapter)
        snake = Naming.snake(name)
        files = { "bluebook/#{snake}.world" => world(name, snake, adapter) }
        files["bluebook/environments/memory.world"] = overlay(name) if ADAPTERS.fetch(adapter).fetch(:server)
        files[".gitignore"] = "data/\n" if ADAPTERS.fetch(adapter).fetch(:local_data)
        files
      end

      # @param name [String] a domain name
      # @return [String] the directory `init` writes into when none is named
      def directory(name) = Naming.snake(name)

      # @api private
      def check!(name, adapter)
        unless name.to_s.match?(NAME)
          raise ArgumentError, "#{name.inspect} is not a domain name: a capital, then letters and digits (Lending)"
        end
        return if ADAPTERS.key?(adapter)

        raise ArgumentError, "unknown adapter #{adapter.inspect}; choose one of #{adapters.join(', ')}"
      end

      # @api private
      def bluebook(name)
        <<~BLUEBOOK
          Hecks.bluebook "#{name}" do
            vision "TODO: say in one sentence what #{name} is for."
            supporting

            # TODO: rename Example to the main thing #{name} keeps track of.
            aggregate "Example" do
              description "TODO: describe what an Example is."

              identified_by :name

              attribute :name, ExampleName

              value_object "ExampleName" do
                attribute :value, String, pattern: '[^ \\t\\n\\r]'
              end

              # TODO: replace Create with the first thing that happens to an Example.
              command "Create" do
                goal "TODO: say what Create does"

                attribute :name, ExampleName

                emits "ExampleCreated"
              end
            end
          end
        BLUEBOOK
      end

      # @api private
      def world(name, snake, adapter)
        lines = ADAPTERS.fetch(adapter).fetch(:world).map { |line| "  #{format(line, snake: snake)}" }
        note = adapter == "PostgresEra" ? "  # PostgresEra refuses a superuser role; use an ordinary one in the URL.\n" : ""
        "Hecks.world \"#{name}\" do\n  realm \"#{name}\"\n#{note}#{lines.join("\n")}\nend\n"
      end

      # @api private
      def overlay(name)
        "Hecks.world \"#{name}\" do\n  default_adapter \"Memory\"\nend\n"
      end
    end
  end
end
