require "optparse"

module Hecks
  module CLI
    class SmokeHttp
      # Reads the command line and environment into the settings a run needs; `SmokeHttp`
      # extends it, so these are its class methods.
      module Settings
        # Reads the command line and environment into the settings a run needs.
        #
        # @param argv [Array<String>] the flags, consumed
        # @param env [Hash{String => String}] the environment defaults
        # @return [Hash{Symbol => String}] the settings
        # @raise [ArgumentError] if the path or the secret is missing or the scheme is unknown
        def settings(argv, env)
          options = {}
          parser(options).parse!(argv)
          resolve(options, env)
        end

        # Merges explicit options over the environment's defaults and validates the result.
        #
        # @param options [Hash{Symbol => String}] the settings offered explicitly
        # @param env [Hash{String => String}] the environment defaults
        # @return [Hash{Symbol => String}] the settings
        # @raise [ArgumentError] if the path or the secret is missing or the scheme is unknown
        def resolve(options, env)
          settings = {
            url: env.fetch("SMOKE_TARGET_URL", "http://127.0.0.1:4322"), path: env["SMOKE_WEBHOOK_PATH"],
            secret: env["SMOKE_WEBHOOK_SECRET"], header: env.fetch("SMOKE_SIGNATURE_HEADER", "X-Signature"),
            scheme: env.fetch("SMOKE_SIGNATURE_SCHEME", "timestamped")
          }.merge(options)
          validate!(settings)
          settings
        end

        # @api private
        def parser(options)
          OptionParser.new do |parser|
            %i[url path secret header scheme payload health_path state_path].each do |name|
              flag = "--#{name.to_s.tr("_", "-")}"
              parser.on("#{flag} VALUE") { |value| options[name] = value }
            end
            parser.on("--payload-file FILE") { |file| options[:payload] = File.read(file) }
          end
        end

        # Refuses settings a run cannot start from.
        #
        # @param settings [Hash{Symbol => String}] the settings to judge
        # @return [void]
        # @raise [ArgumentError] if the path or the secret is missing or the scheme is unknown
        def validate!(settings)
          raise ArgumentError, "no webhook path: pass --path or set SMOKE_WEBHOOK_PATH" if settings[:path].to_s.empty?
          raise ArgumentError, "no signing secret: set SMOKE_WEBHOOK_SECRET (or pass --secret)" if settings[:secret].to_s.empty?
          return if Signature::SCHEMES.include?(settings[:scheme])

          raise ArgumentError, "unknown scheme #{settings[:scheme].inspect}; expected one of #{Signature::SCHEMES.join(", ")}"
        end
      end
    end
  end
end
