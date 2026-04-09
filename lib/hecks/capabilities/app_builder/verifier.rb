# Hecks::Capabilities::AppBuilder::Verifier
#
# Checks planned additions against the live domain IR.
# Returns which additions exist and which are missing.
#
#   verifier = Verifier.new(runtime)
#   verifier.verify(additions)
#   # => { additions: [{ ..., exists: true }, ...], complete: false }
#
module Hecks
  module Capabilities
    module AppBuilder
      class Verifier
        def initialize(runtime)
          @runtime = runtime
        end

        def verify(additions)
          return { additions: [], complete: false } unless additions&.any?

          checked = additions.map do |a|
            a = a.transform_keys(&:to_s)
            exists = check_exists(a)
            a.merge("exists_in_domain" => exists ? "true" : "false")
          end

          complete = checked.all? { |a| a["exists_in_domain"] == "true" }
          { additions: checked, complete: complete }
        end

        private

        def check_exists(addition)
          domain = @runtime.domain
          case addition["kind"]
          when "aggregate"
            domain.aggregates.any? { |a| a.name == addition["name"] }
          when "command"
            agg = domain.aggregates.find { |a| a.name == addition["parent"] }
            agg && agg.commands.any? { |c| c.name == addition["name"] }
          when "event"
            agg = domain.aggregates.find { |a| a.name == addition["parent"] }
            agg && agg.respond_to?(:events) && agg.events.any? { |e| e.name == addition["name"] }
          when "attribute"
            agg = domain.aggregates.find { |a| a.name == addition["parent"] }
            agg && agg.attributes.any? { |a| a.name.to_s == addition["name"] }
          when "value_object"
            agg = domain.aggregates.find { |a| a.name == addition["parent"] }
            agg && agg.respond_to?(:value_objects) && agg.value_objects.any? { |v| v.name == addition["name"] }
          when "policy"
            agg = domain.aggregates.find { |a| a.name == addition["parent"] }
            agg && agg.respond_to?(:policies) && agg.policies.any? { |p| p.name == addition["name"] }
          else
            false
          end
        end
      end
    end
  end
end
