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
    # @param options [Hash] `glob:` (the pattern of each exported file's name, `"*"`), `marker:`
    #   (the file recording the commit, `MARKER`) and `beside:` (see {.beside_files})
    # @return [Pin] the commit and where the files landed
    # @raise [Vendoring::Error] if the source or a matching file is missing
    # @raise [ArgumentError] for any other keyword
    def self.pin(from:, ref:, subtree:, into:, **options, &)
      unknown = options.keys - %i[glob marker beside]
      raise ArgumentError, "unknown keyword: #{unknown.first.inspect}" unless unknown.empty?

      request = request_for(from, ref, subtree, into, options)
      Dir.mktmpdir("hecks-vendoring") do |stage|
        request.source.export(request.commit, request.files + request.beside, stage)
        pinned(stage, request, &)
      end
    end

    # What one pin exports, and where it goes.
    Request = Struct.new(:source, :commit, :files, :subtree, :into, :marker, :beside) do
      # @return [String] the directory the exported subtree lands in
      def pin_dir = File.join(into, File.basename(subtree))

      # @return [Array<String>] the exported files' names
      def names = files.map { |file| File.basename(file) }

      # @return [Array<String>] the directories next to the subtree that were exported with it
      def beside_dirs = beside.map { |file| file.delete_prefix("#{File.dirname(subtree)}/").split("/").first }.uniq
    end

    # @return [Request] the commit and files to export
    # @raise [Vendoring::Error] if the source or a matching file is missing
    def self.request_for(from, ref, subtree, into, options)
      source = GitSource.new(from)
      commit = source.commit(ref)
      glob = options.fetch(:glob, "*")
      files = source.files(commit, subtree, glob)
      raise Error, "no #{glob} files in #{subtree} at #{ref} in #{source.path}" if files.empty?

      beside = beside_files(source, commit, subtree, options.fetch(:beside, {}))
      Request.new(source, commit, files, subtree, into, options.fetch(:marker, MARKER), beside)
    end

    # The files of the directories exported whole beside the subtree, at any depth: `beside:`
    # names each directory next to it with the pattern of its files' names (`{ "lib" => "*.rb" }`).
    #
    # @return [Array<String>] repository-relative paths; none for a directory the commit lacks
    def self.beside_files(source, commit, subtree, beside)
      beside.flat_map { |dir, pattern| source.tree(commit, File.join(File.dirname(subtree), dir), pattern) }
    end

    # Runs the optional hook on the staged export, installs what it leaves, and describes it.
    def self.pinned(stage, request)
      staged = File.join(stage, request.subtree)
      extras = block_given? ? yield(staged, request.commit) : nil
      install(staged, request, extras || {})
      Pin.new(commit: request.commit, dir: request.pin_dir, files: request.names)
    end
    private_class_method :request_for, :pinned, :beside_files

    # Replaces `into` with the staged files, the directories exported beside them, the marker and
    # any extras.
    def self.install(staged, request, extras)
      into = request.into
      FileUtils.rm_rf(into)
      FileUtils.mkdir_p(into)
      copy_staged(File.dirname(staged), [File.basename(staged), *request.beside_dirs], into)
      File.write(File.join(into, request.marker), "#{request.commit}\n")
      extras.each { |name, text| File.write(File.join(into, name), text) }
    end

    def self.copy_staged(stage, dirs, into)
      dirs.each { |dir| FileUtils.cp_r(File.join(stage, dir), File.join(into, dir)) }
    end
    private_class_method :install, :copy_staged
  end
end
