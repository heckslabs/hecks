require "json"

module Hecksagain
  # HOW A VALUE READS INSIDE A REFUSAL, in one place, because a refusal is an
  # ANSWER and its wording is contract — pinned byte-for-byte by the corpus.
  #
  # `inspect` and JSON agree on scalars and disagree on everything composite :
  # a hash is `{"cents"=>100}` against `{"cents":100}`, an array is `["a", "b"]`
  # against `["a","b"]`. Each such spelling is invisible until a composite
  # actually reaches a message, which is why both known cases were found by
  # something deliberately passing the wrong shape rather than by review — the
  # first by hand in spec/corpus/banking.json, the second by bin/fuzz, at a
  # different site, after the first was patched where it was found.
  #
  # So it lives here rather than in whichever file noticed it, and the house style
  # is JSON because that is what every other refusal in the corpus already prints.
  module Rendering
    module_function

    def describe(value)
      case value
      when nil then "nil"
      when Hash, Array then JSON.generate(value)
      else value.inspect
      end
    end
  end
end
