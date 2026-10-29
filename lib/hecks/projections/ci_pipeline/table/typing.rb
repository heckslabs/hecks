# frozen_string_literal: true

module Hecks
  module Projections
    module CiPipeline
      class Table
        # Checks the fields of each declared row and their types, and fills the defaults, so a row
        # reaches the join as a hash of every field its object may carry.
        class Typing
          # The fields a row of each object may carry, with the Ruby class each takes (`:bool` is
          # true or false). The order is the order the objects are joined in.
          SHAPES = {
            "Workflow"  => { name: String, display_name: String, note: String, concurrency_group: String,
                            cancel_in_progress: :bool },
            "Trigger"   => { workflow: String, event: String },
            "Secret"    => { workflow: String, name: String, required: :bool },
            "Job"       => { workflow: String, name: String, runner: String, timeout_minutes: Integer,
                       permissions: String, condition: String, shard_total: Integer, shard_axis: String,
                       note: String },
            "Need"      => { workflow: String, job: String, needs: String },
            "Output"    => { workflow: String, job: String, key: String, value: String },
            "Env"       => { workflow: String, job: String, key: String, value: String },
            "Step"      => { workflow: String, job: String, name: String, title: String, id: String, uses: String,
                        run: String, condition: String, note: String },
            "StepInput" => { workflow: String, job: String, step: String, key: String, value: String }
          }.freeze

          # The fields a row must name; every other field has a default.
          REQUIRED = {
            "Workflow" => %i[name display_name], "Trigger" => %i[workflow event],
            "Secret" => %i[workflow name], "Job" => %i[workflow name runner timeout_minutes],
            "Need" => %i[workflow job needs], "Output" => %i[workflow job key value],
            "Env" => %i[workflow job key value], "Step" => %i[workflow job name],
            "StepInput" => %i[workflow job step key value]
          }.freeze

          # The shard total of a job that is not split into legs.
          UNSHARDED = 1

          # The fields whose values name the row, in the order a label lists them.
          IDENTITY = %i[workflow job step name event needs key].freeze

          # @param problems [Array<String>] collects each problem found, one line each
          def initialize(problems)
            @problems = problems
          end

          # @param object [String] the row object's name, such as `Step`
          # @param member [Hash{Symbol => Object}] the declared fields of one row
          # @param index [Integer] the row's position, for a label when the row names nothing
          # @return [Hash{Symbol => Object}] the row's `:label`, and each field, defaults filled
          def call(object, member, index)
            label = label_of(object, member, index)
            shape = SHAPES.fetch(object)
            refuse(label, member, shape, REQUIRED.fetch(object))
            fields = shape.to_h { |key, type| [key, member.fetch(key) { default(object, key, type) }] }
            { label: label, **fields }
          end

          private

          def refuse(label, member, shape, required)
            (member.keys - shape.keys).each do |key|
              problem(label, "has no field #{key}; fields are #{shape.keys.join(", ")}")
            end
            member.slice(*shape.keys).each { |key, value| check_type(label, key, value, shape.fetch(key)) }
            (required - member.keys).each { |key| problem(label, "has no #{key}") }
          end

          def label_of(object, member, index)
            identity = member.values_at(*IDENTITY).compact
            "#{object} #{identity.empty? ? "row #{index + 1}" : identity.join("/")}"
          end

          def default(object, key, type)
            return UNSHARDED if object == "Job" && key == :shard_total

            { String => "", Integer => nil, bool: false }.fetch(type)
          end

          def check_type(label, key, value, expected)
            return if expected == :bool ? [true, false].include?(value) : value.is_a?(expected)

            problem(label, "has #{key} #{value.inspect}; #{key} is #{expected == :bool ? "true or false" : "a #{expected}"}")
          end

          def problem(label, text) = @problems << "#{label} #{text}"
        end
      end
    end
  end
end
