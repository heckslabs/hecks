module Hecks
  # Reads a hash by key whichever way its keys are spelled, so the guess about Symbol or String
  # keys is made in one place and `Hecks/SymbolStringKeyMix` can refuse it everywhere else.
  #
  # IndifferentKey.read({ "era" => "a1" }, :era)  # => "a1"
  module IndifferentKey
    module_function

    # Reads `key` as given when present, else by its other spelling. Presence decides, not
    # `||`, so a held `false` is not mistaken for an absent key.
    #
    # @param hash [Hash] a hash keyed by Symbols or by Strings
    # @param key [Symbol, String] the key to read; its own spelling is tried first
    # @return [Object, nil] the held value, or nil when neither spelling is present
    def read(hash, key)
      other = key.is_a?(Symbol) ? key.to_s : key.to_sym
      hash.key?(key) ? hash[key] : hash[other]
    end
  end
end
