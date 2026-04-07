# __DOMAIN_MODULE__::Validations
#
# Server-side parameter validation. Checks command parameters against
# domain validation rules without touching the domain layer. Rules are
# extracted from the domain IR at generation time.
#
#   error = __DOMAIN_MODULE__::Validations.check("Pizza", "create_pizza", name: "")
#   # => #<ValidationError "name can't be blank" field=:name rule=:presence>
#

module __DOMAIN_MODULE__
  module Validations
    class << self
      attr_accessor :rules

      def check(aggregate, command, params)
        cmd_rules = rules && rules["#{aggregate}/#{command}"]
        return nil unless cmd_rules

        cmd_rules.each do |field, checks|
          val = params[field.to_sym] || params[field.to_s]
          if checks["presence"] && (val.nil? || val.to_s.strip.empty?)
            return __DOMAIN_MODULE__::ValidationError.new(
              "#{field} can't be blank", field: field.to_sym, rule: :presence)
          end
          if checks["positive"] && val && val.to_f <= 0
            return __DOMAIN_MODULE__::ValidationError.new(
              "#{field} must be positive", field: field.to_sym, rule: :positive)
          end
        end
        nil
      end
    end
  end
end
