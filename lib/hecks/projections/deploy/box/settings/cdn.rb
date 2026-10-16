require_relative "patterns"

module Hecks
  module Projections
    module Deploy
      module Box
        module Settings
          # Reads the `cdn` setting: the CloudFront edge in front of the box. Extended onto
          # `Settings`. The alias names themselves are checked by the Deploy bluebook's
          # `BoxTarget.Declare` before this runs; this checks the shape and the guard.
          module CdnReaders
            include Patterns

            # @param value [Hash{Symbol => Object}, nil] the world's `cdn` setting
            # @param origin_header [String, nil] the declared origin header
            # @return [Cdn, nil] the edge to generate, or nil when the world declares none
            # @raise [ArgumentError] when the shape is wrong or there is no origin guard
            def read_cdn(value, origin_header)
              return nil if value.nil?

              aliases = cdn_aliases(value)
              raise ArgumentError, CDN_NEEDS_ORIGIN if origin_header.nil?

              Settings::Cdn.new(aliases: aliases.uniq)
            end

            private

            def cdn_aliases(value)
              listed = value.is_a?(Hash) && value.keys == [:aliases] ? value[:aliases] : nil
              raise ArgumentError, CDN_SHAPE unless listed.is_a?(Array) && !listed.empty?

              listed.map { |name| check(:cdn_aliases, name, CDN_ALIAS) }
            end
          end
        end
      end
    end
  end
end
