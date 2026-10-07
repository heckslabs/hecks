# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # The `<kind>:<slug>` key convention, read from an attribute's own `pattern:`.
        #
        # A key such as `post:hello` says what it names in its first part. The bluebook states the
        # convention only when the attribute's pattern does: it must start `^kind:` or
        # `^(kind|kind):`, with lower-case words of letters, digits and underscores. Anything
        # else is not a convention the editor assumes.
        module KeyKinds
          # `^` then one word, or a group of words separated by `|`, then the `:`.
          LEAD = /\A\^(?:\((?:\?:)?(?<kinds>\w+(?:\|\w+)*)\)|(?<kinds>\w+)):/

          module_function

          # @param pattern [String, nil] the attribute's declared pattern
          # @return [Array<String>] the kinds the pattern allows before the colon; empty when none
          def of(pattern)
            found = LEAD.match(pattern.to_s)
            return [] unless found

            found[:kinds].split("|").grep(/\A[a-z][a-z0-9_]*\z/).uniq
          end
        end
      end
    end
  end
end
