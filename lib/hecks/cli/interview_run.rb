require_relative "../../hecks"
require_relative "domain_stub"
require_relative "domain_writer"
require_relative "interview_agent"
require_relative "interview_session"

module Hecks
  module CLI
    # The command behind `hecks interview <Name>` (ADR 0088): boots the SME chapter on demand, holds
    # the interview at the terminal, then writes the first domain, or the next interview's proposed
    # additions, and says what to type next. Nothing is written unless the interview concludes.
    module InterviewRun
      SME = File.expand_path("../sme", __dir__)

      module_function

      # @param name [String] the domain being discovered, as its bluebook will spell it
      # @param adapter [String, nil] a persistence adapter from `DomainStub::ADAPTERS`
      # @param dir [String, nil] where the domain goes; the snake-cased name here when nil
      # @param expert [String, nil] who is interviewed; asked for when nil
      # @param use_ai [Boolean] false runs the plain prompts (`--no-ai`)
      # @param input [#gets] where the developer types
      # @param output [#puts, #print] where the session speaks
      # @param agent [#question, #proposals, nil] an interviewer to use instead of the real one
      # @param runtime [Runtime, nil] a booted SME chapter to use instead of booting one
      # @return [String] the report that was printed, or "" when nothing was written
      # @raise [ArgumentError] when the name or adapter is refused, or a file would be replaced
      def call(name:, adapter: nil, dir: nil, expert: nil, use_ai: true, input: $stdin, output: $stdout, agent: nil, # rubocop:disable Metrics/ParameterLists -- one keyword per setting the command takes
               runtime: nil)
        DomainStub.support_files(name: name, adapter: adapter)
        target = File.expand_path(dir || DomainStub.directory(name), Dir.pwd)
        expert = who(expert, input, output)
        result = InterviewSession.new(runtime: runtime || Hecks.boot(SME), agent: interviewer(use_ai, agent, output),
                                      input: input, output: output, reference: next_reference(target),
                                      subject: name, expert: expert).call
        return "" unless result.status == :concluded

        write_domain(result.interview, adapter, target, output)
      end

      # Writes the files the interview decided and prints the report.
      #
      # @api private
      def write_domain(interview, adapter, target, output)
        report(target, DomainWriter.write!(files(interview, adapter, target), target))
          .tap { |text| output.puts(text) }
      end

      # @api private
      def who(expert, input, output)
        return expert unless expert.to_s.strip.empty?

        output.print("Who is the expert? ")
        input.gets.to_s.strip.then { |text| text.empty? ? "the expert" : text }
      end

      # @api private
      def interviewer(use_ai, agent, output)
        return nil unless use_ai
        return agent if agent
        return InterviewAgent.claude if InterviewAgent.claude_available?

        output.puts("`claude` is not installed, so this runs without the AI. Use --no-ai to skip this note.")
        nil
      end

      # The first interview names a domain; a later one finds a bluebook there and offers additions.
      # @api private
      def files(interview, adapter, target)
        return InterviewDraft.additions(interview) unless Dir.glob(File.join(target, "bluebook", "*.bluebook")).empty?

        InterviewDraft.files(interview, adapter: adapter)
      end

      # @api private
      def next_reference(target)
        "INT-#{Dir.glob(File.join(target, "interviews", "INT-*.md")).length + 1}"
      end

      # @api private
      def report(target, written)
        where = target.delete_prefix("#{Dir.pwd}/")
        lines = ["wrote #{written.length} #{written.length == 1 ? "file" : "files"} in #{where}/:"] +
                written.sort.map { |path| "  #{path}" }
        (lines + next_steps(written, where)).join("\n")
      end

      # @api private
      def next_steps(written, where)
        if written.any? { |path| path.start_with?("bluebook/") }
          ["", "next:", "  hecks docs #{where}/bluebook", "  hecks console subject=#{where}"]
        else
          ["", "next:", "  merge the proposed additions in #{where}/#{written.first} into the domain's bluebook"]
        end
      end
    end
  end
end
