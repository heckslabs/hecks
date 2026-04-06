  # BlueBook::Tokenizer
  #
  # Splits a command argument string into typed tokens. Handles symbols,
  # strings, type names, reference_to/list_of wrappers, keyword args,
  # and hash rockets.
  #
  #   Tokenizer.tokenize(':name, String, presence: true')
  #   # => [":name", "String", "presence: true"]
  #
module BlueBook
  module Tokenizer
    def self.tokenize(str)
      tokens = []
      remaining = str.strip
      until remaining.empty?
        remaining = remaining.sub(/\A,\s*/, "")
        break if remaining.empty?
        case remaining
        when /\A(reference_to\("[^"]*"\))/
          tokens << $1
        when /\A(list_of\("[^"]*"\))/
          tokens << $1
        when /\A("[^"]*"\s*=>\s*"[^"]*")/
          tokens << $1
        when /\A("[^"]*")/
          tokens << $1
        when /\A(:\w+)/
          tokens << $1
        when /\A(\w+:\s*"[^"]*")/
          tokens << $1
        when /\A(\w+:\s*(?:true|false|\d+))/
          tokens << $1
        when /\A(\w+)/
          tokens << $1
        else
          break
        end
        remaining = $~.post_match.strip
      end
      tokens
    end
  end
end
