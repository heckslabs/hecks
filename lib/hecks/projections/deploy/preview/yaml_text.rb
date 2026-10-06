require "json"

module Hecks
  module Projections
    module Deploy
      module Preview
        # Text helpers the preview template's sections share: indentation and the
        # rendering of a value as a YAML scalar or CloudFormation intrinsic.
        module YamlText
          PREVIEW_URL_TOKEN = "{{preview_url}}".freeze
          PREVIEW_URL_SUB = "https://${PreviewDistribution.DomainName}".freeze

          module_function

          # Indents every non-empty line of a block.
          #
          # @param text [String] the block
          # @param width [Integer] spaces to add
          # @return [String] the indented block
          def indent(text, width)
            pad = " " * width
            text.each_line.map { |line| line.strip.empty? ? line : "#{pad}#{line}" }.join
          end

          # Renders one environment or property value as a YAML scalar or intrinsic.
          #
          # @param value [String] a literal, optionally holding the `{{preview_url}}` token
          # @return [String] a double-quoted scalar, or a `!Sub` when the token is present
          def scalar(value)
            return JSON.generate(value) unless value.include?(PREVIEW_URL_TOKEN)

            "!Sub #{JSON.generate(value.gsub(PREVIEW_URL_TOKEN, PREVIEW_URL_SUB))}"
          end

          # Names the logical id of a container's generated secret.
          #
          # @param container [Containers::Entry] the container that declares the secret
          # @param name [String] the environment variable name
          # @return [String] the logical id, ending in `Secret`
          def secret_id(container, name)
            stem = "#{container.logical}#{name.sub(/_ARN\z/, "").split("_").map(&:capitalize).join}"
            stem.end_with?("Secret") ? stem : "#{stem}Secret"
          end
        end
      end
    end
  end
end
