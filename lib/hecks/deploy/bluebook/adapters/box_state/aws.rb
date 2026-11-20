# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    class BoxState
      # The `aws` reads behind a box's state, each one program call with an argument list.
      class Aws
        # The comment on the command this adapter runs on the box, which {#rolling?} leaves out.
        COMMENT = "hecks box state"

        # The states of a command on the box that has not ended.
        UNENDED = %w[Pending InProgress Delayed].freeze

        # A whole number of days, as the database reports how long it keeps its backups.
        DAYS = /\A\d+\z/

        # How many times the box is asked whether the listing has ended.
        ATTEMPTS = 30

        # @param shell [Shell] runs one program and answers what it said
        # @param region [String] the region every call names
        def initialize(shell, region)
          @shell = shell
          @region = region
        end

        # @param stack [String] the box's CloudFormation stack
        # @return [String] the instance the stack runs
        # @raise [Unreadable] when the stack cannot be read or has no instance
        def instance(stack)
          box = output(stack, "InstanceId")
          box.empty? || box == "None" ? raise(Unreadable, "no instance in stack #{stack}") : box
        end

        # @param box [String] the instance
        # @return [Boolean] whether a command other than this adapter's own has not ended there
        # @raise [Unreadable] when the box's commands cannot be listed
        def rolling?(box)
          %w[Pending InProgress].any? do |status|
            !read("ssm", "list-commands", "--instance-id", box, "--filters", "key=Status,value=#{status}",
                  "--query", "Commands[?Comment!='#{COMMENT}'].CommandId").empty?
          end
        end

        # Runs a script on the box, waits for it and answers what it printed.
        #
        # @param box [String] the instance
        # @param script [String] the shell to run there
        # @return [String] the script's standard output
        # @raise [Unreadable] when the command cannot be sent or does not succeed
        def on_box(box, script)
          command = read("ssm", "send-command", "--instance-ids", box, "--document-name", "AWS-RunShellScript",
                         "--comment", COMMENT, "--timeout-seconds", "60", "--parameters",
                         JSON.generate(commands: [script], executionTimeout: ["60"]), "--query", "Command.CommandId")
          state = settled(box, command)
          raise Unreadable, "the box did not answer: command #{command} ended #{state}" unless state == "Success"

          invocation(box, command, "StandardOutputContent")
        end

        # @param stack [String] the database's CloudFormation stack
        # @return [String] the instance, the latest moment it can be restored to and the days its
        #   backups are kept, or an empty string when the backups cannot be read
        def restore_point(stack)
          database = output(stack, "DbEndpoint").split(".").first.to_s
          days, latest = backups(database)
          return "" unless days.to_s.match?(DAYS)

          "#{database} restorable to #{latest} (backups kept #{days} days)"
        end

        private

        def backups(database)
          result = call("rds", "describe-db-instances", "--db-instance-identifier", database, "--query",
                        "DBInstances[0].[BackupRetentionPeriod,LatestRestorableTime]")
          printed = result.ok? ? result.out : ""
          printed.split
        end

        def output(stack, key)
          read("cloudformation", "describe-stacks", "--stack-name", stack, "--query",
               "Stacks[0].Outputs[?OutputKey=='#{key}'].OutputValue")
        end

        def settled(box, command)
          ATTEMPTS.times do
            sleep(ENV.fetch("SSM_POLL_SECS", "2").to_f)
            state = invocation(box, command, "Status")
            return state unless UNENDED.include?(state)
          end
          "unended"
        end

        def invocation(box, command, field)
          read("ssm", "get-command-invocation", "--command-id", command, "--instance-id", box, "--query", field)
        end

        def read(*argv)
          result = call(*argv)
          return result.out.strip if result.ok?

          raise Unreadable, "aws #{argv.first(2).join(" ")} ended #{result.exit_code}: #{result.err.strip}"
        end

        def call(*argv) = @shell.capture("aws", *argv, "--region", @region, "--output", "text")
      end
    end
  end
end
