module Hecks
  module Ports
    module Persistence
      # Adapter outcomes are runtime facts, never command lifecycle.
      Outcome = Struct.new(:status, :instance, keyword_init: true) do
        # `:stale` is an optimistic-concurrency conflict on a plain `save`
        # (someone else committed since this instance was read) — never a
        # domain refusal, distinct from `:conflicted` (a `creates?`
        # command's identity already exists, `AlreadyExists`). See
        # `Runtime::StaleWrite` (runtime/errors.rb) and `AppendOnly#save`.
        STATUSES = %i[inserted replaced updated conflicted missing saved stale].freeze

        # @param status [Symbol, String] one of `STATUSES`; stored as a Symbol
        # @param instance [Runtime::Instance, Object, nil] the record the write concerned, as
        #   the repository reports it; nil when there is none
        # @raise [ArgumentError] if `status` is not one of `STATUSES`
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
