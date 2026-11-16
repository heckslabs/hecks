require_relative "../dispatch_context"

module Hecks
  module Runtime
    class PortOperationInterpreter
      # The state one port-operation dispatch carries from step to step.
      Context = Struct.new(:domain, :aggregate, :operation, :args, :route, :instance, :result, :invocation) do
        include DispatchContext

        # @return [String] the operation's declared name
        def operation_hecks_name = operation.hecks_name

        # @return [Object] the identity of the record the route names
        def route_identity = route.aggregate
      end
    end
  end
end
