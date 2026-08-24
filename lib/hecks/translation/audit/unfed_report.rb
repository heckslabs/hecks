module Hecks
  module Translation
    module Audit
      # New-era attributes that nothing feeds: absent from every
      # translated state, produced by no rule, and carrying no default.
      # A report, not a violation — the remedy is a `default:` on the
      # attribute, and the loud refusal for a REQUIRED one comes from
      # Layer 1 the moment an invariant reads it.
      module UnfedReport
        def unfed(aggregate, declared, after)
          fed = if declared
                  (declared.renames.values.map(&:to_s) +
                   declared.moves.map(&:to) +
                   declared.converts.map(&:to) +
                   declared.computes.map(&:to)).map { |path| path.to_s.split(".").first }
                else
                  []
                end
          aggregate.attributes.filter_map do |attribute|
            name = attribute.name.to_s
            next if fed.include?(name)
            next unless attribute.default.nil?
            next if after.any? { |_, state| !dig_path(state, name).nil? }
            next if after.empty?

            name
          end
        end

        def dig_path(state, path)
          return nil if state.nil?

          path.to_s.split(".").reduce(state) do |node, segment|
            break nil unless node.is_a?(Hash)

            node[segment] || node[segment.to_sym]
          end
        end
      end
    end
  end
end
