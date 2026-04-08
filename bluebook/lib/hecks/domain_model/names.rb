module Hecks
  module BluebookModel

    # Hecks::BluebookModel::Names
    #
    # Value objects for domain identifiers — command names, event names,
    # aggregate names, and state names. Each wraps a String and provides
    # equality, hashing, and to_s so they can be used as hash keys and
    # compared with raw strings transparently.
    #
    #   name = CommandName.new("CreatePizza")
    #   name == "CreatePizza"   # => true
    #   name.to_s               # => "CreatePizza"
    #   { name => :value }[name] # works as hash key
    #
    module Names
      autoload :BaseName,      "hecks/domain_model/names/base_name"
      autoload :CommandName,   "hecks/domain_model/names/command_name"
      autoload :EventName,     "hecks/domain_model/names/event_name"
      autoload :AggregateName, "hecks/domain_model/names/aggregate_name"
      autoload :StateName,     "hecks/domain_model/names/state_name"

      def command_name(value)   = CommandName.wrap(value)
      def event_name(value)     = EventName.wrap(value)
      def aggregate_name(value) = AggregateName.wrap(value)
      def state_name(value)     = StateName.wrap(value)

      module_function :command_name, :event_name, :aggregate_name, :state_name
    end
  end
end
