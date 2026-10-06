# frozen_string_literal: true

require_relative "statuses"

module Hecks
  module Adapters
    class DeployToolchain
      # Runs the scripts an ask names: the `Hecks::Tools` tools in this process, and the generated
      # scripts of a project in a child.
      module Scripts
        include Statuses

        # A generated script to run: its file name, how a refusal names it, what its statuses mean,
        # its arguments, and the statuses that are an answer rather than a refusal.
        Script = Struct.new(:name, :label, :statuses, :args, :answering) do
          def initialize(name, label, statuses, args = [], answering = []) = super
        end

        private

        # Runs one generated script, found for the record's project, from its own directory. Answers
        # what it printed, or refuses with its status, that status's meaning and its output.
        def run_script(script, held, env)
          path = script_for(script.name, plain(held[:project]), plain(held[:script]))
          result = Shell.new.capture("bash", path, *script.args, env: env, chdir: File.dirname(path))
          report = printed(result)
          return { report: { value: report } } if result.ok?

          answer_or_refuse(script, result.status.exitstatus, report)
        end

        # What the script printed to either stream, trimmed.
        def printed(result) = [result.out, result.err].map(&:strip).reject(&:empty?).join("\n")

        def answer_or_refuse(script, code, report)
          return { report: { value: report }, status: code } if script.answering.include?(code)

          raise ConsoleCapture::Failure, "#{script.label} ended #{code} (#{script.statuses.fetch(code, "unexpected")})\n#{report}"
        end

        # The script a project runs: the override, else the named one in the project itself, else
        # the only one beneath it (not under `node_modules`, `vendor` or `.git`).
        def script_for(name, project, override)
          return existing_script(override) if override

          root = File.expand_path(project.to_s)
          beside = File.join(root, name)
          return beside if File.file?(beside)

          found = Dir.glob(File.join(root, "**", name)).grep_v(%r{/(node_modules|vendor|\.git)/})
          return found.first if found.one?

          raise ConsoleCapture::Failure, ambiguity(name, root, found.sort)
        end

        def ambiguity(name, root, found)
          return "no #{name} under #{root}; generate the AwsBox recipe or pass script=<path>" if found.empty?

          "#{found.size} #{name} files under #{root}; pass script=<path>: #{found.join(", ")}"
        end

        def existing_script(path)
          script = File.expand_path(path.to_s)
          File.file?(script) ? script : raise(ConsoleCapture::Failure, "no such script: #{script}")
        end

        # The variables the generated script reads, set only when the record asks for them.
        def smoke_env(held)
          { "TASKDEF" => plain(held[:taskdef]), "SKIP_POST_DEPLOY_SMOKE" => flag(held[:skip]),
            "SMOKE_ASYNC" => flag(held[:async]), "DRY_RUN" => flag(held[:dry_run]) }.compact
        end

        def flag(argument) = plain(argument) == true ? "1" : nil

        def child(ask, argv)
          tree = Codebase::Tree.new
          tree.require_checkout!
          run(tree, ask, argv)
        end

        def run(tree, ask, argv)
          result = Codebase::RubyChild.new(tree).capture(SCRIPTS.fetch(ask), *argv)
          raise ConsoleCapture::Failure, message_of(result) unless result.ok?

          { output: { value: result.out } }
        end

        def message_of(result)
          text = [result.err, result.out].map(&:strip).reject(&:empty?).join("\n")
          text.empty? ? "the tool ended with status #{result.status.exitstatus}" : text
        end
      end
    end
  end
end
