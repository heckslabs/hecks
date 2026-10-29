# frozen_string_literal: true

require_relative "tree"
require_relative "typing"
require_relative "lookup"
require_relative "refusals"

module Hecks
  module Projections
    module CiPipeline
      class Table
        # Joins the declared member rows into a tree of workflows, jobs and steps: each row is
        # joined to its workflow and job by name, and each closed-set value is checked against
        # the CiPipeline bluebook's vocabulary. A row that names what is not declared is refused,
        # with what is declared listed.
        class Rows
          include Lookup
          include Refusals

          # The chapter value objects whose pattern a field's text must match, by name.
          PATTERNS = { workflow: %w[Workflow WorkflowName], secret: %w[Workflow SecretName],
                       env: %w[JobSpec EnvName], output: %w[JobSpec OutputKey], step_id: %w[JobSpec StepId],
                       shard_axis: %w[JobSpec ShardAxis] }.freeze

          # The row objects in the order they are joined, each with the method that joins one row.
          JOINS = { "Trigger" => :join_trigger, "Secret" => :join_secret, "Job" => :join_job,
                    "Need" => :join_need, "Output" => :join_output, "Env" => :join_env,
                    "Step" => :join_step, "StepInput" => :join_input }.freeze

          # @return [Array<Tree::Workflow>] the workflows, in the order declared
          attr_reader :workflows

          # @param rows [Hash{String => Array<Hash{Symbol => Object}>}] each object's declared rows
          # @param vocabulary [Hash{Symbol => Object}] the closed sets and patterns
          # @param problems [Array<String>] collects each problem found, one line each
          def initialize(rows, vocabulary, problems)
            @vocabulary = vocabulary
            @problems = problems
            @typed = type_all(rows, Typing.new(problems))
            @workflows = []
            @typed.fetch("Workflow").each { |row| @workflows << build_workflow(row) }
            JOINS.each { |object, join| @typed.fetch(object).each { |row| send(join, row) } }
          end

          private

          def type_all(rows, typing)
            rows.to_h { |object, members| [object, members.each_with_index.map { |row, i| typing.call(object, row, i) }] }
          end

          def build_workflow(row)
            check_pattern(row, :workflow, :name, "a workflow is named by its file")
            twice(row, @workflows.any? { |workflow| workflow.name == row[:name] })
            fields = row.slice(:label, :name, :display_name, :note, :concurrency_group, :cancel_in_progress)
            Tree::Workflow.new(**fields, triggers: [], secrets: [], jobs: [])
          end

          def join_trigger(row)
            workflow = workflow_of(row) or return
            refuse_event(row)
            twice(row, workflow.triggers.include?(row[:event]))
            workflow.triggers << row[:event]
          end

          def join_secret(row)
            workflow = workflow_of(row) or return
            check_pattern(row, :secret, :name, "a secret is named in capitals")
            twice(row, workflow.secrets.any? { |secret| secret.name == row[:name] })
            workflow.secrets << Tree::Secret.new(row[:name], row[:required])
          end

          def join_job(row)
            workflow = workflow_of(row) or return
            twice(row, workflow.jobs.any? { |job| job.name == row[:name] })
            check_pattern(row, :shard_axis, :shard_axis, "a matrix is named in lower case") unless row[:shard_axis].empty?
            fields = row.slice(:label, :name, :runner, :timeout_minutes, :permissions, :condition, :shard_total,
                               :shard_axis, :note)
            workflow.jobs << Tree::Job.new(**fields, needs: [], outputs: [], env: [], steps: [])
          end

          def join_need(row)
            job = job_of(row) or return
            refuse_unknown_need(row)
            twice(row, job.needs.include?(row[:needs]))
            job.needs << row[:needs]
          end

          def join_output(row) = join_pair(row, :output, :outputs, "an output is named by a key")

          def join_env(row) = join_pair(row, :env, :env, "a variable is named in capitals")

          def join_pair(row, pattern, list, reason)
            job = job_of(row) or return
            check_pattern(row, pattern, :key, reason)
            twice(row, job[list].any? { |pair| pair.key == row[:key] })
            job[list] << Tree::Pair.new(row[:key], row[:value])
          end

          def join_step(row)
            job = job_of(row) or return
            twice(row, job.steps.any? { |step| step.name == row[:name] })
            check_pattern(row, :step_id, :id, "an id is lower case") unless row[:id].empty?
            refuse_uses(row)
            fields = row.slice(:label, :name, :title, :id, :uses, :run, :condition, :note)
            job.steps << Tree::Step.new(**fields, inputs: [])
          end

          def join_input(row)
            job = job_of(row) or return
            step = step_of(job, row) or return
            twice(row, step.inputs.any? { |pair| pair.key == row[:key] })
            refuse_input_of_command(row) if step.uses.empty?
            step.inputs << Tree::Pair.new(row[:key], row[:value])
          end
        end
      end
    end
  end
end
