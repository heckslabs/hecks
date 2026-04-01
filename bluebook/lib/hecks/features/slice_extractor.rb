module Hecks::Features

  # Hecks::Features::SliceExtractor
  #
  # Extracts vertical slices from a domain by tracing reactive chains
  # through FlowGenerator. Each flow becomes a VerticalSlice with its
  # entry command, steps, participating aggregates, and cycle status.
  #
  #   slices = SliceExtractor.new(domain).extract
  #   slices.first.name           # => "Loan Issuance -> Disbursement"
  #   slices.first.aggregates     # => ["Loan", "Account"]
  #   slices.first.cross_aggregate? # => true
  #
  class SliceExtractor
    # @param domain [Hecks::DomainModel::Structure::Domain]
    def initialize(domain)
      @domain = domain
    end

    # Extract all vertical slices from the domain.
    #
    # @return [Array<VerticalSlice>]
    def extract
      flows = Hecks::FlowGenerator.new(@domain).trace_flows
      flows.map { |flow| build_slice(flow) }
    end

    private

    def build_slice(flow)
      steps = flow[:steps].map { |s| SliceStep.new(**s) }
      aggregates = steps
        .map(&:aggregate)
        .compact
        .uniq

      VerticalSlice.new(
        name: flow[:name],
        entry_command: steps.first.command,
        steps: steps,
        aggregates: aggregates,
        cyclic: flow[:cyclic]
      )
    end
  end
end
