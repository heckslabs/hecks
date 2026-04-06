  # Hecks::Features::LeakySliceDetection
  #
  # Validation rule that warns when a vertical slice crosses aggregate
  # boundaries via an aggregate-scoped policy rather than a domain-level
  # policy. Aggregate-scoped cross-boundary policies are "leaky" — the
  # reactive coupling is hidden inside an aggregate instead of declared
  # at the domain level where it's visible.
  #
  #   rule = LeakySliceDetection.new(domain)
  #   rule.warnings  # => ["Policy X in Aggregate Y triggers ..."]
  #
module Hecks::Features

  class LeakySliceDetection < Hecks::ValidationRules::BaseRule
    def errors
      []
    end

    # Warns when an aggregate-scoped policy triggers a command that
    # belongs to a different aggregate.
    #
    # @return [Array<String>]
    def warnings
      result = []
      command_owners = build_command_index

      @domain.aggregates.each do |agg|
        agg.policies.select(&:reactive?).each do |policy|
          target_agg = command_owners[policy.trigger_command]
          next unless target_agg
          next if target_agg == agg.name

          result << "Policy #{policy.name} in #{agg.name} triggers " \
                    "#{policy.trigger_command} on #{target_agg} — " \
                    "consider promoting to a domain-level policy for visibility"
        end
      end

      result
    end

    private

    def build_command_index
      index = {}
      @domain.aggregates.each do |agg|
        agg.commands.each { |cmd| index[cmd.name] = agg.name }
      end
      index
    end
  end
  Hecks.register_validation_rule(LeakySliceDetection)
end
