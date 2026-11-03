require "delegate"

module Hecks
  # The values a world hands an adapter under a `secret` declaration, held by name so any text a
  # launcher prints can be scrubbed of them: a refusal, a boot note, a settings line, a result or
  # an exception's message. The adapter that declared the secret gets the value; whatever a person
  # or a log sees gets `«secret:NAME»`. Redaction follows the declaration, not a guess at a
  # value's shape, with one addition: the password inside a `database` URL, which the URL
  # carries without any adapter declaring it.
  module Secrets
    MASK     = "«secret:%s»".freeze
    PASSWORD = %r{://[^:/@\s]+:([^@\s]+)@}

    @held  = {}
    @mutex = Mutex.new

    module_function

    # Holds one secret value under its name. An empty or non-String value is nothing to hide.
    #
    # @param name [#to_s] the declared name
    # @param value [Object] the value the world supplied
    # @return [void]
    def register(name, value)
      return unless value.is_a?(String) && !value.empty?

      @mutex.synchronize { @held[value] = name.to_s }
    end

    # Holds every secret an adapter declares out of the settings it is built with, and the
    # password of its `database` URL when the URL carries one.
    #
    # @param adapter [Bluebook::Adapter, nil] the adapter's declaration; nil holds nothing
    # @param settings [Hash] the settings the world supplied for it
    # @return [void]
    def register_settings(adapter, settings)
      Array(adapter&.secrets).each { |secret| register(secret, settings[secret.to_sym]) }
      register_database(settings[:database])
    end

    # Holds the password a `scheme://user:password@host` URL carries, under a fixed name.
    #
    # @param url [Object] the database setting; anything but a URL with a password holds nothing
    # @return [void]
    def register_database(url)
      return unless url.is_a?(String) && (found = url.match(PASSWORD))

      register(database_secret_name, found[1])
    end

    # The name a database URL's password is masked under: the one `CarriedSecret` Privacy declares.
    #
    # @return [String] the declared name
    def database_secret_name = Hecks::Framework.closed_set("Privacy", "Secret", "CarriedSecret").first

    # Replaces every held value in the text with its mask, longest value first so a value that
    # contains another is masked whole.
    #
    # @param text [Object] what is about to be printed; a non-String is returned as it is
    # @return [Object] the text with each held value masked
    def redact(text)
      return text unless text.is_a?(String)

      held = @mutex.synchronize { @held.dup }
      held.keys.sort_by { |value| -value.length }
          .reduce(text) { |scrubbed, value| scrubbed.gsub(value) { format(MASK, held[value]) } }
    end

    # Forgets every held value, for a process that boots another domain.
    # @return [void]
    def clear! = @mutex.synchronize { @held.clear }

    # Whether any value is held.
    # @return [Boolean]
    def any? = @mutex.synchronize { !@held.empty? }

    # The stream, writing through `redact`; a stream already guarded is returned as it is.
    #
    # @param io [IO, #write] the stream to guard
    # @return [Guarded] the guarded stream
    def guarded(io) = io.is_a?(Guarded) ? io : Guarded.new(io)

    # Guards the process's own output streams, so a `puts`, `warn` or `abort` anywhere in it
    # prints no held value. A launcher calls it once, right after it loads the gem.
    #
    # @return [void]
    def guard!
      $stdout = guarded($stdout)
      $stderr = guarded($stderr)
    end

    # A stream whose every write passes through `Secrets.redact`. A value split across two
    # writes is not caught, which the one-call writes `puts`, `warn` and `abort` make never
    # happens.
    class Guarded < SimpleDelegator
      # @param parts [Array<#to_s>] what is written
      # @return [Integer] the bytes written
      def write(*parts) = __getobj__.write(*parts.map { |part| Secrets.redact(part.to_s) })

      # @param parts [Array<#to_s>] the lines; an Array prints one line per element
      # @return [nil]
      def puts(*parts) = __getobj__.puts(*parts.flatten.map { |part| Secrets.redact(part.to_s) })

      # @param parts [Array<#to_s>] what is printed
      # @return [nil]
      def print(*parts) = __getobj__.print(*parts.map { |part| Secrets.redact(part.to_s) })

      # @param part [#to_s] what is appended
      # @return [Guarded] self
      def <<(part)
        write(part)
        self
      end
    end
  end
end
