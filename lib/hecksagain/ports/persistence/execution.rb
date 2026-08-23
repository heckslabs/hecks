module Hecksagain
  module Ports
    module Persistence
      # Adapter outcomes are runtime facts, never command lifecycle.
      Outcome = Struct.new(:status, :instance, keyword_init: true) do
        STATUSES = %i[inserted replaced updated conflicted missing saved].freeze

        def initialize(status:, instance: nil)
          normalized = status.to_sym
          raise ArgumentError, "unknown persistence outcome #{status.inspect}" unless STATUSES.include?(normalized)

          super(status: normalized, instance: instance)
          freeze
        end
      end
    end
  end
end
