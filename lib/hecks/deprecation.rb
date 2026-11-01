module Hecks
  # Says a deprecation once per process, so a boot that checks twice is not noisy. A bluebook's
  # `formerly_known_as` is the first: the notice names the world line that replaces it.
  module Deprecation
    module_function

    # @param key [Array<String>] what the notice is about, such as the domain and aggregate
    # @param text [String] the warning
    # @param err [#puts] where it goes
    # @return [String, nil] the text when it was said now, nil when it had been said already
    def once(key, text, err: $stderr)
      @seen ||= {}
      return if @seen[key]

      @seen[key] = true
      err.puts(text)
      text
    end

    # Forgets what was said, so a spec can hear a notice again.
    def forget! = @seen = {}
  end
end
