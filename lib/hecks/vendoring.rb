require "fileutils"
require "tmpdir"
require_relative "vendoring/git_environment"
require_relative "vendoring/git_source"

module Hecks
  # Pins an exact commit of one directory of another repository into a
  # project's own tree, so a build doesn't depend on a live clone.
  module Vendoring
    # Raised when a pin cannot be made or is refused.
    class Error < StandardError; end

    # File name of the commit marker written into every pinned directory.
    MARKER = "VENDORED_COMMIT".freeze

    # What a pin produced.
    #
    # @!attribute [r] commit
    #   @return [String] the full commit id the files were exported from
    # @!attribute [r] dir
    #   @return [String] the directory holding the exported subtree
    # @!attribute [r] files
    #   @return [Array<String>] the exported files' names, sorted
    Pin = Struct.new(:commit, :dir, :files, keyword_init: true)

    # Exports the top-level files of one directory at one commit into `into`,
    # replacing it wholly; the optional block may refuse before that happens.
    #
    # @param from [String] path of the local source repository
    # @param ref [String] the commit-ish to export
    # @param subtree [String] repository-relative directory to export
    # @param into [String] the directory to replace with the export
    # @param options [Hash] `glob:`, the pattern each exported file's name must match (`"*"`),
    #   and `marker:`, the name of the file recording the commit (`MARKER`)
    # @return [Pin] the commit and where the files landed
    # @raise [Vendoring::Error] if the source or a matching file is missing
    # @raise [ArgumentError] for any other keyword
    def self.pin(from:, ref:, subtree:, into:, **options, &)
      unknown = options.keys - %i[glob marker]
      raise ArgumentError, "unknown keyword: #{unknown.first.inspect}" unless unknown.empty?

      request = request_for(from, ref, subtree, into, options)
      Dir.mktmpdir("hecks-vendoring") do |stage|
        request.source.export(request.commit, request.files, stage)
        pinned(stage, request, &)
      end
    end

    # What one pin exports, and where it goes.
    Request = Struct.new(:source, :commit, :files, :subtree, :into, :marker) do
      # @return [String] the directory the exported subtree lands in
      def pin_dir = File.join(into, File.basename(subtree))

      # @return [Array<String>] the exported files' names
      def names = files.map { |file| File.basename(file) }
    end

    # @return [Request] the commit and files to export
    # @raise [Vendoring::Error] if the source or a matching file is missing
    def self.request_for(from, ref, subtree, into, options)
      source = GitSource.new(from)
      commit = source.commit(ref)
      glob = options.fetch(:glob, "*")
      files = source.files(commit, subtree, glob)
      raise Error, "no #{glob} files in #{subtree} at #{ref} in #{source.path}" if files.empty?

      Request.new(source, commit, files, subtree, into, options.fetch(:marker, MARKER))
    end

    # Runs the optional hook on the staged export, installs what it leaves, and describes it.
    def self.pinned(stage, request)
      staged = File.join(stage, request.subtree)
      extras = block_given? ? yield(staged, request.commit) : nil
      install(staged, request.into, request.marker, request.commit, extras || {})
      Pin.new(commit: request.commit, dir: request.pin_dir, files: request.names)
    end
    private_class_method :request_for, :pinned

    # Replaces `into` with the staged files, the marker and any extras.
    def self.install(staged, into, marker, commit, extras)
      FileUtils.rm_rf(into)
      FileUtils.mkdir_p(into)
      FileUtils.cp_r(staged, File.join(into, File.basename(staged)))
      File.write(File.join(into, marker), "#{commit}\n")
      extras.each { |name, text| File.write(File.join(into, name), text) }
    end
    private_class_method :install
  end
end
