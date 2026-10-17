require "fileutils"
require "tmpdir"

module Hecks
  module Composer
    # A workspace is a directory of domain files; an editor holds unsaved text for some of them.
    # Staging lays that text over a copy of the files on disk so a check sees what is on screen
    # and the directory itself stays untouched.
    module Workspace
      # The files a domain is made of; anything else in the directory is data, not declaration.
      EXTENSIONS = %w[bluebook hecksagon world adapter port behaviors].freeze

      # Raised when an unsaved buffer names a path outside the workspace.
      class OutsideWorkspace < ArgumentError; end

      module_function

      # Copies the workspace's declaration files into a temporary directory, lays the buffers over
      # them, and yields that directory.
      #
      # @param dir [String] the workspace directory
      # @param buffers [Hash{String => String}] unsaved text by path relative to `dir`; a path
      #   with no file on disk yet is created
      # @yieldparam stage [String] the temporary directory holding the staged files
      # @return [Object] what the block returned
      # @raise [OutsideWorkspace] if a buffer's path is absolute or climbs out of the workspace
      def stage(dir:, buffers: {})
        stage = materialize(dir: dir, buffers: buffers)
        yield stage
      ensure
        FileUtils.rm_rf(stage) if stage
      end

      # Stages as {stage} does, but leaves the directory for the caller to remove, so a booted
      # domain can keep reading its files after this returns.
      #
      # @param dir [String] the workspace directory
      # @param buffers [Hash{String => String}] unsaved text by path relative to `dir`
      # @return [String] the temporary directory holding the staged files
      # @raise [OutsideWorkspace] if a buffer's path is absolute or climbs out of the workspace
      def materialize(dir:, buffers: {})
        refuse_escapes!(buffers.keys)
        stage = Dir.mktmpdir("hecks-composer")
        copy_declarations(dir, stage)
        buffers.each { |path, text| write(File.join(stage, path), text) }
        stage
      rescue StandardError
        FileUtils.rm_rf(stage) if stage
        raise
      end

      # @param stage [String] a staged directory
      # @return [Array<String>] the declaration files in it, relative and sorted
      def files(stage)
        Dir.glob("**/*.{#{EXTENSIONS.join(",")}}", base: stage).sort
      end

      # @api private
      def copy_declarations(dir, stage)
        files(dir).each do |relative|
          FileUtils.mkdir_p(File.dirname(File.join(stage, relative)))
          FileUtils.cp(File.join(dir, relative), File.join(stage, relative))
        end
      end

      # @api private
      def write(path, text)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, text)
      end

      # @api private
      def refuse_escapes!(paths)
        offender = paths.find { |path| path.start_with?("/") || path.split("/").include?("..") }
        return unless offender

        raise OutsideWorkspace, "#{offender.inspect} is not inside the workspace"
      end
    end
  end
end
