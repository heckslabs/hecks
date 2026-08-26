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
