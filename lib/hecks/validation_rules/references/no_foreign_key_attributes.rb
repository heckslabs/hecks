# Hecks::ValidationRules::References::NoForeignKeyAttributes
#
# Warns when an attribute looks like a foreign key (e.g., `attribute :team_id, String`).
# Since references are now standalone declarations (`reference_to "Team"`),
# an `_id` suffix on a String attribute likely means the user should be using
# `reference_to` instead.
#
#   # Bad:  attribute :team_id, String
#   # Good: reference_to "Team"
#
module Hecks
  module ValidationRules
    module References
      class NoForeignKeyAttributes < BaseRule
        def errors
          [] # Non-blocking — use warnings instead
        end

        def warnings
          issues = []
          @domain.aggregates.each do |agg|
            agg.attributes.each do |attr|
              next unless attr.name.to_s.end_with?("_id")
              next unless attr.type.to_s == "String"
              role = attr.name.to_s.sub(/_id$/, "")
              target = HecksTemplating::Names.bluebook_constant_name(role)
              issues << "#{agg.name}.#{attr.name} looks like a foreign key. " \
                        "Use reference_to \"#{target}\" instead."
            end
          end
          issues
        end
      end
      Hecks.register_validation_rule(NoForeignKeyAttributes)
    end
  end
end
