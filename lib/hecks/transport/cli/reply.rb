# frozen_string_literal: true

require "digest"
require "fileutils"

module Hecks
  module Transport
    module Cli
      # What one run said and how it ended. Its stdout stays in a file that lives until the
      # client's block returns, so a caller reads it, fingerprints it or keeps it, as it needs.
      #
      # @!attribute [r] out_path
      #   @return [String] the file holding everything the program wrote to stdout
      # @!attribute [r] err
      #   @return [String] what the program wrote to stderr
      # @!attribute [r] status
      #   @return [Process::Status] how the program ended
      # @!attribute [r] seconds
      #   @return [Float] how long the run took, from start to exit
      Reply = Struct.new(:out_path, :err, :status, :seconds, keyword_init: true) do
        # Answers whether the program ended with status 0.
        #
        # @return [Boolean] true when the program exited 0
        def ok? = status.success?

        # Reads the program's stdout into memory, for output small enough to hold.
        #
        # @return [String] everything the program wrote to stdout
        def out = File.read(out_path)

        # Measures the program's stdout without reading it.
        #
        # @return [Integer] the size of the stdout file, in bytes
        def bytes = File.size(out_path)

        # Fingerprints the program's stdout, so a record can name output it does not hold.
        #
        # @return [String] the SHA-256 of the stdout file, as lowercase hex
        def sha256 = Digest::SHA256.file(out_path).hexdigest

        # Moves the program's stdout out of the run's scratch directory, which is removed when
        # the client's block returns.
        #
        # @param destination [String] the path to keep the output at; its directory is created
        # @return [String] `destination`
        def keep(destination)
          FileUtils.mkdir_p(File.dirname(destination))
          FileUtils.mv(out_path, destination)
          self.out_path = destination
        end
      end
    end
  end
end
