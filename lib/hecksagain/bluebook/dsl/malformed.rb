# Malformed — a declaration that cannot mean what it says.
#
# These rules used to live in grammar/bluebook.bluebook, as `given`s and
# `invariant`s on a self-description : "a vision must say something", "a rule
# must survive extraction", "a mutation either sets or appends". Written there
# they DESCRIBED the language and enforced nothing — the DSL happily built a
# command whose given had no readable source, and the document saying otherwise
# sat one folder away, executing against its own toy state.
#
# They live here now, as refusals in the builders that actually see the
# declarations. A rule that cannot fire is not a rule ; the whole point of
# moving them is that these ones fire.
#
# Every message says what was declared AND what would have gone wrong if it had
# been allowed through, because "invalid" tells an author nothing about which
# half of their sentence to fix.
module Hecksagain
  module Bluebook
    module DSL
      class Malformed < StandardError; end
    end
  end
end
