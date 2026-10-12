# frozen_string_literal: true

require "uri"

module Hecks
  module Adapters
    # Everything a rehearsal does on a client's domain: where its data copy comes from, how the
    # mint's audit is run over it, and what is reported. The two port adapters (`RehearsalStore`
    # and `RehearsalSubject`) are thin; the work lives here.
    module Rehearsal
      # A rehearsal that was not admitted or could not be carried on: the port answers it as a
      # refusal, which the run keeps as `refusal`.
      class Refused < StandardError; end

      # What a subject's own `.world` says about the copy of its data, read from its
      # `rehearsed_by` block and checked before anything is touched.
      #
      # A connection is only ever named by an environment variable (`connection_env`); a literal
      # connection string, user or password in the world is refused, so the file holds no secret.
      class Declaration
        KINDS = %w[memory postgres].freeze
        MODES = %w[empty dump readonly_copy].freeze
        LITERALS = %i[database url connection password user].freeze
        LOCAL_HOSTS = [nil, "", "localhost", "127.0.0.1", "::1", "[::1]"].freeze

        NAME = /\A[A-Za-z0-9_-]+\z/

        attr_reader :kind, :mode, :connection_env, :dump, :rows, :drop_after, :allow_remote, :schema, :environment

        # @param world [#for_verb, nil] the subject's world, as the registry holds it
        # @param directory [String] the domain's bluebook directory, which a relative file is under
        # @return [Declaration] the checked declaration
        # @raise [Refused] if the world declares no `rehearsed_by`, or declares it wrongly
        def self.from_world(world, directory)
          settings = world&.for_verb("rehearsed_by") || {}
          raise Refused, "the domain's world declares no `rehearsed_by`: nothing says where its data copy is" if settings.empty?

          new(settings, directory).tap(&:check!)
        end

        # @param settings [Hash] the block's settings, `adapter:` among them
        # @param directory [String] where a relative `dump` or `rows` is found
        def initialize(settings, directory)
          @kind           = settings[:adapter].to_s.downcase
          @connection_env = settings[:connection_env]&.to_s
          @dump           = expand(settings[:dump], directory)
          @rows           = expand(settings[:rows], directory)
          @mode           = settings.fetch(:mode) { default_mode }.to_s
          read_switches(settings)
        end

        # @return [void]
        # @raise [Refused] naming what is wrong with the declaration
        def check!
          check_names!
          raise Refused, literal_wording unless @literals.empty?

          kind == "postgres" ? check_postgres! : check_memory!
        end

        # @return [String] the connection the environment holds
        # @raise [Refused] if the variable the world names is unset or empty, or names a server
        #   that is not this machine and the world did not say `allow_remote true`
        def connection
          value = ENV.fetch(connection_env, "")
          raise Refused, "the environment variable #{connection_env} is not set" if value.strip.empty?

          refuse_remote!(value)
          value
        end

        private

        def refuse_remote!(value)
          host = URI.parse(value).host
          return if allow_remote || LOCAL_HOSTS.include?(host)

          raise Refused, "#{connection_env} names the server #{host.inspect}, which is not this machine: " \
                         "a rehearsal reads a local copy; say `allow_remote true` in rehearsed_by to point it elsewhere"
        rescue URI::InvalidURIError
          nil
        end

        def read_switches(settings)
          @drop_after   = settings.fetch(:drop_after, true) != false
          @allow_remote = settings.fetch(:allow_remote, false) == true
          @literals     = LITERALS & settings.keys.map(&:to_sym)
          @schema       = settings[:schema]&.to_s
          @environment  = settings[:environment]&.to_s
        end

        def default_mode = dump || rows ? "dump" : "empty"

        def check_names!
          raise Refused, "rehearsed_by names #{kind.inspect}; the stores are #{KINDS.join(" and ")}" unless KINDS.include?(kind)

          raise Refused, "rehearsed_by mode #{mode.inspect} is not one of #{MODES.join(", ")}" unless MODES.include?(mode)

          check_label!("schema", schema)
          check_label!("environment", environment)
        end

        def check_label!(word, value)
          return if value.nil? || NAME.match?(value)

          raise Refused, "rehearsed_by #{word} #{value.inspect} is not a name (letters, digits, `_`, `-`)"
        end

        def expand(path, directory)
          path && File.expand_path(path.to_s, directory)
        end

        def literal_wording
          "rehearsed_by holds #{@literals.join(", ")}: name the environment variable in `connection_env`, " \
            "never the value, so the world file holds no secret"
        end

        def check_postgres!
          unless connection_env
            raise Refused,
                  "a postgres rehearsal needs `connection_env`, the name of the variable holding the server"
          end
          raise Refused, "mode dump needs `dump`, the file to restore" if mode == "dump" && !dump
        end

        def check_memory!
          raise Refused, "mode readonly_copy is a postgres mode: a memory store has no copy to read" if mode == "readonly_copy"
          raise Refused, "mode dump needs `rows`, the JSON file the memory store holds" if mode == "dump" && !rows
        end
      end
    end
  end
end
