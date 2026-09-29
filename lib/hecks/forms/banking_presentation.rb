# frozen_string_literal: true

require_relative "../forms"
require_relative "port_argument"

module Hecks
  module Forms
    # The banking example, wired for the forms app: its bluebook, an in-memory store for every
    # aggregate, and the `expose` sample that renders it.
    #
    # It is what `hecks present` serves. The `expose` sample stays out of `examples/`, since every
    # entry there is scanned as a corpus member and must be a complete, model-checked domain.
    module BankingPresentation
      # The aggregates of the banking example, each held in memory.
      AGGREGATES = %w[Customer Account SafeDepositBox Transfer ATMCard CardPayment ExternalTransfer
                      ScheduledPayment OnboardingCase Statement].freeze

      module_function

      # Builds the Rack app for the banking example.
      #
      # @param root [String] the checkout's root
      # @return [#call] the app, for a Rack server
      def app(root:)
        registry = Hecks::Runtime::Registry.new
        Hecks.with_registry(registry) { load_into(registry, root) }
        registry.verify!
        Hecks::Forms::App.for(registry: registry, app_name: "BankingConsole")
      end

      # @api private
      def load_into(_registry, root)
        %w[lib/hecks/ports/persistence.port lib/hecks/ports/extraction.port
           lib/hecks/adapters/driven/memory.adapter lib/hecks/adapters/driven/prism.adapter].each do |file|
          Kernel.load(File.join(root, file))
        end
        Hecks::Adapters::Folder.new.load_bluebooks(File.join(root, "examples/banking/bluebook"))
        Kernel.load(File.join(root, "lib/hecks/forms/examples/banking_console.bluebook"))
        Hecks.hecksagon("Banking") do
          uses_framework "Governance"
          AGGREGATES.each { |name| ::Banking.const_get(name).persisted_by("Memory") }
        end
        Hecks.hecksagon("Governance") do
          ::Governance::RoleAssignment.persisted_by("Memory")
          ::Governance::RoleTransition.persisted_by("Memory")
        end
      end
    end
  end
end
