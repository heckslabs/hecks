module Hecks
  module Bluebook
    module DSL
      # The aggregate kinds: `aggregate "GateRun", kind: "Run"` evaluates the kind's own text,
      # written in the bluebook's words, around the aggregate's body. A kind is data, the file
      # `lib/hecks/language/kinds/<kind>.kind`, not code: `{Name}` in it stands for the aggregate's
      # name and `{Stem}` for that name without the kind, and a `# body` line marks where the
      # aggregate's own body is evaluated.
      module Kinds
        DIRECTORY = File.expand_path("../../language/kinds", __dir__).freeze
        BODY_MARK = /^# body\n/

        module_function

        # The block an aggregate is built from: its own body, or, for a kind, that body inside the
        # kind's text.
        #
        # @param name [String] the aggregate's name
        # @param kind [String, nil] the kind written after `kind:`, if any
        # @yield the aggregate's own body; may be omitted
        # @return [Proc, nil] the block to evaluate on the aggregate's builder
        # @raise [Malformed] if the kind has no file
        def wrap(name, kind, &body)
          return body unless kind

          before, after = halves(kind, name)
          file = path(kind)
          proc do
            instance_eval(before, file, 1)
            instance_eval(&body) if body
            instance_eval(after, file, before.lines.size + 2)
          end
        end

        # @return [Array(String, String)] the kind's text, names filled in, split at the body
        def halves(kind, name)
          before, after = File.read(path(kind)).split(BODY_MARK, 2)
          [before, after].map { |text| fill(text, name, kind) }
        rescue Errno::ENOENT
          raise Malformed, "#{name} declares kind #{kind.inspect}, which has no file at #{path(kind)}"
        end

        # @return [String] the kind's text with `{Name}` and `{Stem}` replaced
        def fill(text, name, kind)
          text.gsub("{Name}", name.to_s).gsub("{Stem}", name.to_s.delete_suffix(kind.to_s))
        end

        # @return [String] the file that holds a kind
        def path(kind) = File.join(DIRECTORY, "#{kind.to_s.downcase}.kind")
      end
    end
  end
end
