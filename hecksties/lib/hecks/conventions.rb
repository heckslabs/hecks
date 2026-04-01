# Hecks::Conventions
#
# Naming helpers and data contracts for cross-target code generation.
# Merged from hecks_templating/. Provides short aliases on the Hecks module
# so consumers don't need verbose includes or qualified names.
#
require_relative "conventions/naming_helpers"

# Load all contract files
Dir[File.join(__dir__, "conventions", "*_contract.rb")].sort.each { |f| require f }

module Hecks
  # Short aliases — use these instead of the full Hecks::Conventions:: path
  Names = Conventions::Names
  NamingHelpers = Conventions::NamingHelpers

  # Backward compat — HecksTemplating still works
  module ::HecksTemplating
    Names = Hecks::Conventions::Names
    NamingHelpers = Hecks::Conventions::NamingHelpers
    TypeContract = Hecks::Conventions::TypeContract
    DisplayContract = Hecks::Conventions::DisplayContract
    ViewContract = Hecks::Conventions::ViewContract
    EventContract = Hecks::Conventions::EventContract
    EventLogContract = Hecks::Conventions::EventLogContract
    FormParsingContract = Hecks::Conventions::FormParsingContract
    AggregateContract = Hecks::Conventions::AggregateContract
    MigrationContract = Hecks::Conventions::MigrationContract
    UILabelContract = Hecks::Conventions::UILabelContract
    NamingContract = Hecks::Conventions::Names
    CommandContract = Hecks::Conventions::CommandContract
    RouteContract = Hecks::Conventions::RouteContract
  end

  module Contracts
    @registry = {}
    def self.register(name, contract) = @registry[name.to_sym] = contract
    def self.for(name) = @registry[name.to_sym]
    def self.registered = @registry.keys
  end

  Contracts.register(:types,      Conventions::TypeContract)
  Contracts.register(:display,    Conventions::DisplayContract)
  Contracts.register(:views,      Conventions::ViewContract)
  Contracts.register(:events,     Conventions::EventContract)
  Contracts.register(:event_log,  Conventions::EventLogContract)
  Contracts.register(:forms,      Conventions::FormParsingContract)
  Contracts.register(:aggregates, Conventions::AggregateContract)
  Contracts.register(:naming,     Conventions::Names)
  Contracts.register(:migrations, Conventions::MigrationContract)
  Contracts.register(:ui_labels,  Conventions::UILabelContract)
  Contracts.register(:commands,   Conventions::CommandContract)
  Contracts.register(:routes,     Conventions::RouteContract)
  Contracts.register(:dispatch,   Conventions::DispatchContract)
end
