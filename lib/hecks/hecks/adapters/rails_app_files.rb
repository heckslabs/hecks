# frozen_string_literal: true

require "fileutils"
require_relative "console_capture"

module Hecks
  module Adapters
    # Writes the `:rails_app` projection of a Rails app's domain into the app, for the
    # `Workspace` port's `ProjectRails` question.
    #
    # The domain is read from the app's `bluebook/` without binding an adapter or opening a store.
    # Each of the app's own bluebooks gives its controllers; a bluebook a hecksagon only attaches
    # (Governance, Identity) gives none. A file already in the app is the app's own, so it is
    # reported and left alone.
    class RailsAppFiles
      # @param root [String] the Rails app's directory, holding `bluebook/`
      def initialize(root)
        @root = root
      end

      # Writes every file the app does not have yet and reports each one.
      #
      # @return [String] one line per file: `wrote <path>` or `kept <path>`
      # @raise [ConsoleCapture::Failure] when the app has no `bluebook/` or it declares no bluebook
      def call
        files = projected_files
        raise ConsoleCapture::Failure, "no bluebook declared under #{bluebook_dir}" if files.empty?

        files.sort.map { |path, text| write(path, text) }.join("\n")
      end

      private

      def bluebook_dir = File.join(@root, "bluebook")

      def projected_files
        raise ConsoleCapture::Failure, "no bluebook/ in #{@root}" unless File.directory?(bluebook_dir)

        declarations = own_bluebooks
        declarations.each_with_object({}) do |declaration, files|
          files.merge!(Projector.call(:rails_app, bluebook: declaration, options: { route_bluebooks: declarations }))
        end
      end

      # The app's bluebooks: every bluebook the boot loaded except a framework member or another
      # bluebook a hecksagon only attaches.
      def own_bluebooks
        registry = Hecks.describe(bluebook_dir, environment: nil).registry
        registry.bluebooks.values.reject do |declaration|
          registry.bounded?(declaration.name) || Hecks::Framework.members.key?(declaration.name)
        end
      end

      def write(path, text)
        full = File.join(@root, path)
        return "kept #{path}" if File.exist?(full)

        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, text)
        "wrote #{path}"
      end
    end
  end
end
