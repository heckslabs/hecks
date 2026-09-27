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
    # @param glob [String] pattern each exported file's name must match
    # @param marker [String] name of the file recording the commit
    # @return [Pin] the commit and where the files landed
    # @raise [Vendoring::Error] if the source or a matching file is missing
    def self.pin(from:, ref:, subtree:, into:, glob: "*", marker: MARKER)
      source = GitSource.new(from)
      commit = source.commit(ref)
      files = source.files(commit, subtree, glob)
      raise Error, "no #{glob} files in #{subtree} at #{ref} in #{source.path}" if files.empty?

      Dir.mktmpdir("hecks-vendoring") do |stage|
        source.export(commit, files, stage)
        staged = File.join(stage, subtree)
        extras = block_given? ? yield(staged, commit) : nil
        install(staged, into, marker, commit, extras || {})
        Pin.new(commit: commit, dir: File.join(into, File.basename(subtree)),
                files: files.map { |file| File.basename(file) })
      end
    end

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
