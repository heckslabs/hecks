module Hecks
  # Reads a hash by key whichever way its keys are spelled, so the guess about Symbol or String
  # keys is made in one place and `Hecks/SymbolStringKeyMix` can refuse it everywhere else.
  #
  # IndifferentKey.read({ "era" => "a1" }, :era)  # => "a1"
  module IndifferentKey
    module_function

    # Reads `key` by its Symbol spelling when present, else by its String spelling. Presence
    # decides, not `||`, so a held `false` is not mistaken for an absent key.
    #
    # @param hash [Hash] a hash keyed by Symbols or by Strings
    # @param key [Symbol, String] the key to read, in either spelling
    # @return [Object, nil] the held value, or nil when neither spelling is present
    def read(hash, key)
      symbol = key.to_sym
      hash.key?(symbol) ? hash[symbol] : hash[key.to_s]
    end
  end
end
