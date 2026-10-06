require_relative "../vocabulary"

module Hecks
  module Forms
    module FieldShape
      # Resolves a text attribute into a field, reading its HTML input type off its name and
      # pattern.
      module TextShape
        # Vocabulary::FieldHint rows (language/bluebook/vocabulary.bluebook), matched
        # case-insensitively. hecks project_field_hints writes the Rust host's copy from the same
        # rows.
        HINTS = Hecks::Vocabulary.rows("FieldHint")
                                 .to_h { |row| [row["name"], Regexp.new(row["pattern"], Regexp::IGNORECASE)] }
                                 .freeze
        EMAIL_HINT    = HINTS.fetch("email")
        URL_HINT      = HINTS.fetch("url")
        TEL_HINT      = HINTS.fetch("tel")
        TEXTAREA_HINT = HINTS.fetch("textarea")

        # @param attribute [Bluebook::Attribute] a string-typed attribute
        # @param common [Hash] the field attributes every kind shares
        # @return [Forms::Field] a `:text` field, or a `:textarea` for a long-form name
        def self.field(attribute, common)
          name = attribute.name.to_s
          html_type = html_type(name, attribute.pattern.to_s)
          kind = html_type == "text" && name.match?(TEXTAREA_HINT) ? :textarea : :text
          Field.new(**common, kind: kind, html_type: html_type)
        end

        def self.html_type(name, pattern)
          return "email" if pattern.include?("@") || name.match?(EMAIL_HINT)
          return "url" if pattern.match?(/https?/i) || name.match?(URL_HINT)
          return "tel" if name.match?(TEL_HINT)

          "text"
        end
      end
    end
  end
end
