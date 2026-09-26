require "fileutils"
require "tmpdir"
require_relative "vendoring/git_source"

module Hecks
  # Pins an exact commit of one directory of another repository into a
  # project's own tree.
  #
  # ## What it is
  #
  # A project that consumes a package from a private repository cannot clone
  # that repository when its image builds, and a live pull would make the build
  # depend on whatever is checked out. So the files are exported from one
  # commit, committed into the consumer, and a marker file beside them records
  # which commit they came from. Only the files directly inside the named
  # subtree are taken; the source's own specs, ports, adapters and data stay
  # where they are.
  #
  # ## Marker
  #
  # `VENDORED_COMMIT` holds the full 40-character commit id and a newline, so
  # `git -C <source> show <id>:<subtree>` reproduces the vendored files. The
  # marker sits in `into`, beside the exported directory.
  #
  # ## Whole-directory replacement
  #
  # A pin replaces `into` entirely, so a file the source dropped does not
  # linger. Nothing is touched until the export succeeded and the optional
  # block accepted it.
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

    # Exports the top-level files of one directory at one commit into `into`.
    #
    # The exported files land in `into/<last segment of subtree>/`; the marker
    # lands in `into` itself. The optional block sees the staged files before
    # anything is replaced and may raise to refuse the pin.
    #
    # @param from [String] path of the local source repository
    # @param ref [String] the commit-ish to export (branch, tag or commit id)
    # @param subtree [String] repository-relative directory to export, such as
    #   `"payments/bluebook"`
    # @param into [String] the directory to replace with the export
    # @param glob [String] `File.fnmatch` pattern each exported file's name must match
    # @param marker [String] name of the file recording the commit
    # @yield [staged, commit] the staged files, before `into` is touched
    # @yieldparam staged [String] directory holding the exported files
    # @yieldparam commit [String] the resolved commit id
    # @yieldreturn [Hash{String => String}, nil] extra files to write into `into`,
    #   keyed by file name; nil for none
    # @return [Pin] the commit and where the files landed
    # @raise [Vendoring::Error] if the source is missing, `ref` names no commit,
    #   the subtree holds no matching file, or the block refuses
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
    #
    # @param staged [String] directory holding the exported files
    # @param into [String] the directory to replace
    # @param marker [String] marker file name
    # @param commit [String] commit id the marker records
    # @param extras [Hash{String => String}] more files to write into `into`
    # @return [void]
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
