# frozen_string_literal: true

require "fileutils"
require "pathname"
require_relative "memory"
require_relative "adr_files/header"

module Hecks
  module Adapters
    # The store whose records are the decision record files of the checkout (ADR 0175):
    # `docs/decisions/NNNN-slug.md` and `docs/implemented/decisions/NNNN-slug.md`.
    #
    # Each file is one `Tickets::Adr` row, read from its header ({Header}) when the store is built;
    # a save writes the title and status back into that file, and a new number gets a new file with
    # the headings to fill in. The prose below the header is the author's and is never touched. A
    # record is never deleted: a decision is withdrawn or superseded, and its file stays.
    class AdrFiles < Memory
      DIRS = %w[docs/decisions docs/implemented/decisions].freeze

      class Refused < StandardError; end

      attr_reader :base

      # @param aggregate [Bluebook::Aggregate] the Adr aggregate
      # @param settings [Hash] `dir:` the checkout holding `docs/decisions`, by default the nearest
      #   directory at or above the working directory that holds one; `writes: false` keeps every
      #   change in memory and writes no file
      # @param root [String, nil] the domain's directory; unused, since records live in the checkout
      def initialize(aggregate:, settings: {}, root: nil)
        super
        dir = setting(settings, :dir).to_s
        @base = dir.empty? ? self.class.checkout(Dir.pwd) : dir
        @writes = setting(settings, :writes) != false
        @paths = {}
        load_records
      end

      # The nearest directory at or above `from` that holds `docs/decisions`.
      #
      # @param from [String] where to start looking
      # @return [String] that directory, or `from` when none above it holds one
      def self.checkout(from)
        holding = Pathname.new(File.expand_path(from)).ascend.find { |dir| dir.join(DIRS.first).directory? }
        holding ? holding.to_s : from
      end

      # Applies one entry and writes the record's header to its file.
      #
      # @param entry [Persistence::Entry] the save to project
      # @return [Runtime::Instance] the stored record
      # @raise [Refused] on a delete
      def project(entry)
        raise Refused, "a decision record is never deleted: withdraw or supersede ADR #{entry.id}" if entry.delete?

        super.tap { write(entry.id, entry.state) if @writes && !@loading }
      end

      # @param id [String] a record's number
      # @return [String, nil] the file that holds it
      def path_of(id) = @paths[id.to_s]

      private

      def setting(settings, name) = settings.key?(name) ? settings[name] : settings[name.to_s]

      def load_records
        @loading = true
        files.each { |path| load_record(Header.read(path)) }
      ensure
        @loading = false
      end

      def files = DIRS.flat_map { |dir| Dir.glob(File.join(@base, dir, "[0-9][0-9][0-9][0-9]-*.md")) }.sort

      # A number two files share loads once, from the first file; the decision_records gate names it.
      def load_record(header)
        return if header[:adr].nil? || @paths.key?(header[:adr])

        @paths[header[:adr]] = header[:path]
        project(Ports::Persistence::Entry.new(operation: "save", id: header[:adr], state: state(header)))
      end

      def state(header)
        { adr: { value: header[:adr] }, title: { value: header[:title].to_s },
          superseded_by: header[:superseded_by] && { value: header[:superseded_by] },
          settles: header[:settles], status: header[:status].to_s }
      end

      def write(id, state)
        path = @paths[id] ||= new_path(id, field(state, :title))
        lines = File.exist?(path) ? rewritten(path, state) : fresh(state)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{lines.join("\n")}\n")
      end

      def rewritten(path, state)
        Header.rewrite(File.readlines(path, chomp: true), title: field(state, :title), head: head(state))
      end

      def fresh(state)
        Header.skeleton(title: field(state, :title), head: head(state), date: Time.now.strftime("%Y-%m-%d"),
                        settles: field(state, :settles))
      end

      def head(state)
        word = field(state, :status).to_s.capitalize
        successor = field(state, :superseded_by)
        return "#{word}." unless word == "Superseded" && successor && !successor.empty?

        "Superseded by #{successor_link(successor)}."
      end

      def successor_link(number)
        path = @paths[number]
        path ? "[ADR #{number}](#{File.basename(path)})" : "ADR #{number}"
      end

      def new_path(id, title) = File.join(@base, DIRS.first, "#{id}-#{Header.slug(title.to_s)}.md")

      def field(state, name) = plain(state.key?(name) ? state[name] : state[name.to_s])

      # A field as the runtime holds it (a value object, a `{ value: }` or `{ id: }` hash, or a bare
      # string), unwrapped to what it holds.
      def plain(value)
        value = value.value if value.respond_to?(:value)
        return value unless value.is_a?(Hash)

        symbols = value.transform_keys(&:to_sym)
        symbols.key?(:value) ? symbols[:value] : symbols[:id]
      end
    end
  end
end
