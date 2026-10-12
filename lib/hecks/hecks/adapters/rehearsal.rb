# frozen_string_literal: true

require "open3"
require_relative "rehearsal/declaration"
require_relative "rehearsal/rows"
require_relative "rehearsal/subject"
require_relative "rehearsal/memory_store"
require_relative "rehearsal/postgres_store"
require_relative "rehearsal/inquiry"

module Hecks
  module Adapters
    # Helpers the two rehearsal port adapters (`RehearsalStore`, `RehearsalSubject`) share.
    module Rehearsal
      module_function

      # The Hecks this process runs, as `release+commit` when a checkout can name its commit.
      #
      # @return [String] `3.9.0`, or `3.9.0+bb8e41d`
      def host_version
        commit = checkout_commit
        commit ? "#{Hecks::VERSION}+#{commit[0, 7]}" : Hecks::VERSION.to_s
      end

      # @param pin [String, nil] a release or a commit prefix the run must be on
      # @return [void]
      # @raise [Refused] if this process is not on the pin
      def check_pin!(pin)
        return if pin.nil? || pin.empty? || pin == Hecks::VERSION.to_s || checkout_commit.to_s.start_with?(pin)

        raise Refused, "this is Hecks #{host_version}, not the pin #{pin}: run the rehearsal from the pinned install"
      end

      # @param subject [Subject] the loaded domain
      # @param run [String] the rehearsal's key
      # @return [MemoryStore, PostgresStore] the store its world declares
      def store_for(subject, run)
        declaration = subject.declaration
        return MemoryStore.new(declaration) if declaration.kind == "memory"

        PostgresStore.new(declaration, run, protected_databases: subject.declared_databases)
      end

      # @return [String, nil] the commit of the checkout this gem runs from
      def checkout_commit
        root = File.expand_path("../../../..", __dir__)
        out, status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD", err: File::NULL)
        status.success? ? out.strip : nil
      rescue SystemCallError
        nil
      end
    end
  end
end
