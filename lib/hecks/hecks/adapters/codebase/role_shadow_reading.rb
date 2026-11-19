# frozen_string_literal: true

require_relative "../console_capture"
require "hecks/runtime/role_shadow/report"

module Hecks
  module Adapters
    module Codebase
      # The role shadow report a `ConformanceRun` asks for: the domain directory the record names,
      # read from its declarations alone (`Runtime.describe`, so no adapter is bound and nothing is
      # written). The directory may be any domain on disk, not only this checkout.
      module RoleShadowReading
        module_function

        # @param held [Hash] the `ConformanceRun` record's fields; `domain` names the directory
        # @return [String] the report: its counts, then each command and reaction an unstated caller
        #   would be refused
        # @raise [ConsoleCapture::Failure] when the record names no directory that exists
        def call(held)
          directory = directory_of(held[:domain])
          raise ConsoleCapture::Failure, "no domain directory at #{directory}" unless File.directory?(directory)

          Runtime::RoleShadow::Report.of_directory(directory)
        end

        # @return [String] the absolute directory a field names, bare or as `{ value: }`
        # @raise [ConsoleCapture::Failure] when the field names none
        def directory_of(field)
          named = (field.is_a?(Hash) ? field[:value] : field).to_s.strip
          raise ConsoleCapture::Failure, "name a domain directory: domain.value=<dir>" if named.empty?

          File.expand_path(named)
        end
      end
    end
  end
end
