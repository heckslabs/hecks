# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # Which integer attributes are moments in time, read from the names the bluebook gave them.
        #
        # An integer is a moment when one of the names it goes by (the attribute's, its value
        # object's, the value object's part's) ends in `_at` or `At` (a date and a time), ends in
        # `_on` or `On` (a date), or has `epoch` in it (seconds since 1970, so a date and a time).
        # The value is always whole seconds since 1970 UTC; the editor shows it in the viewer's own
        # time zone. A name is the only evidence the bluebook gives, so the rule is this narrow:
        # an integer named `duration` or `Season` is never a date.
        module Moment
          # Names that end in `at` or `on` as a word, so `created_at` and `CreatedAt` match and
          # `format`, `Season` and `Combat` do not.
          AT = /(?:_at|[a-z0-9]At)\z/
          ON = /(?:_on|[a-z0-9]On)\z/

          module_function

          # @param names [Array<String>] the names the integer goes by
          # @return [String, nil] `"datetime"`, `"date"`, or nil when the integer is not a moment
          def widget(names)
            return "datetime" if names.any? { |name| AT.match?(name) || name.match?(/epoch/i) }

            "date" if names.any? { |name| ON.match?(name) }
          end
        end
      end
    end
  end
end
