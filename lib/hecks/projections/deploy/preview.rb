require_relative "preview/settings"
require_relative "preview/template"
require_relative "preview/script"

module Hecks
  module Projections
    module Deploy
      # Per-branch preview stacks for a `deployed_to("AwsFargate")` domain, opt-in
      # via a `preview` setting; the host mints era 1 itself, so no bastion is needed.
      module Preview
        module_function

        # Answers whether a domain opted in to previews.
        #
        # @param deploy_settings [Hash{Symbol => Object}] the `deployed_to` settings
        # @return [Boolean] true when a `preview` setting is present and not `false`
        def requested?(deploy_settings)
          value = deploy_settings[:preview]
          !value.nil? && value != false
        end

        # Generates the preview files for one domain.
        #
        # @param deploy_settings [Hash{Symbol => Object}] the `deployed_to` settings
        # @param main [Hash{Symbol => Object}] the main stack's facts; see `Settings.build`
        # @return [Hash{String => String}] `"preview.yaml"` and `"preview.sh"`, or `{}` when
        #   the domain did not opt in
        # @raise [ArgumentError] if a preview setting is unknown or malformed
        def call(deploy_settings:, main:)
          return {} unless requested?(deploy_settings)

          settings = Settings.build(deploy_settings[:preview], deploy_settings: deploy_settings, main: main)
          { "preview.yaml" => Template.render(settings), "preview.sh" => Script.render(settings) }
        end
      end
    end
  end
end
