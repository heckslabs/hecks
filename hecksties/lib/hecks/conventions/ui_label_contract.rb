# = Hecks::Conventions::UILabelContract
#
# Single source of truth for converting names to display labels.
# Handles both snake_case (field names) and PascalCase (command
# names, aggregate names). Pure Ruby — no ActiveSupport dependency.
#
#   Hecks::Conventions::UILabelContract.label(:effective_date)    # => "Effective Date"
#   Hecks::Conventions::UILabelContract.label("ReportIncident")   # => "Report Incident"
#   Hecks::Conventions::UILabelContract.plural_label("GovernancePolicy")  # => "Governance Policies"
#

module Hecks::Conventions
  module UILabelContract
    # Convert any name (snake_case or PascalCase) to a display label.
    def self.label(name)
      s = name.to_s
      s = s.gsub(/([A-Z]+)([A-Z][a-z])/, '\1 \2')
           .gsub(/([a-z\d])([A-Z])/, '\1 \2')
      s.split(/[_ ]+/).map(&:capitalize).join(" ")
    end

    # Humanized plural label for an aggregate or entity name.
    # "GovernancePolicy" → "Governance Policies"
    def self.plural_label(name)
      words = label(name).split(" ")
      words[-1] = pluralize(words[-1])
      words.join(" ")
    end

    # Inline pluralizer covering common English patterns for Ruby class names.
    # Handles: s/x/z/ch/sh → +es, consonant+y → ies, everything else → +s.
    def self.pluralize(word)
      if word.match?(/(?:s|x|z|ch|sh)\z/i)
        "#{word}es"
      elsif word.match?(/[^aeiou]y\z/i)
        "#{word[0..-2]}ies"
      else
        "#{word}s"
      end
    end
  end
end
