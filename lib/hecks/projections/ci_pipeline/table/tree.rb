# frozen_string_literal: true

module Hecks
  module Projections
    module CiPipeline
      class Table
        # The workflows a table of rows joins into: each workflow holds its triggers, secrets and
        # jobs, each job its needs, outputs, environment and steps, each step its `with:` inputs.
        module Tree
          # One workflow file with the rows that belong to it.
          Workflow = Struct.new(:label, :name, :display_name, :note, :concurrency_group, :cancel_in_progress,
                                :triggers, :secrets, :jobs, keyword_init: true)

          # One secret a called workflow takes.
          Secret = Struct.new(:name, :required)

          # One job with the rows that belong to it.
          Job = Struct.new(:label, :name, :runner, :timeout_minutes, :permissions, :condition, :shard_total,
                           :shard_axis, :note, :needs, :outputs, :env, :steps, keyword_init: true)

          # One step with its `with:` inputs.
          Step = Struct.new(:label, :name, :title, :id, :uses, :run, :condition, :note, :inputs, keyword_init: true)

          # A key and its value: a job output, an environment variable or a step input.
          Pair = Struct.new(:key, :value)
        end
      end
    end
  end
end
