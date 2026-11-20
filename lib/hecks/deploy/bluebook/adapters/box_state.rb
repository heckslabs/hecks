# frozen_string_literal: true

require "hecks/hecks/adapters/shell"
require_relative "box_state/unreadable"
require_relative "box_state/roll_script"
require_relative "box_state/aws"
require_relative "box_state/containers"

module Hecks
  module Adapters
    # The `BoxState` port's adapter: answers `BoxRoll`'s `BoxState` query with what a project's app
    # box holds now.
    #
    # It reads and reports, and judges nothing: whether the box may be rolled is the roll's rule.
    # The stack names come from the text of the project's generated `deploy-box.sh`, and each fact
    # from one `aws` read. Nothing on the box changes; the one command it runs there lists the
    # containers, and it carries {Aws::COMMENT} so a later read does not take it for a roll. Two
    # reads sent before either lists the box's commands would each still see only real rolls.
    class BoxState
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `shell:` stands in for the program runner
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @shell = settings[:shell] || Shell.new
      end

      # Reads the box of one project.
      #
      # @param held [Hash] the query's `project`, and `script` when another `deploy-box.sh` is named
      # @return [Hash] the `BoxState` row: `box`, `running`, `commit`, `restore_point`, `rolling`
      # @raise [Unreadable] when the script, the instance or the box cannot be read
      def box_state(**held) = survey(held).first

      # Answers a `StableRoll`'s `ReadBox`: the same read, with the tag its service runs now.
      #
      # @param held [Hash] the `StableRoll` record: `project`, `service`, and `script` when set
      # @return [Hash{Symbol => Hash}] `box`, `running`, `box_commit`, `restore_point`, `rolling`
      #   and `previous_tag`, with the record's `project` and `service` for the policy that begins
      #   the roll, each wrapped as a value; `previous_tag` is empty when the service is not on
      #   the box
      # @raise [Unreadable] when the script, the instance or the box cannot be read
      def read_box(**held)
        state, containers = survey(held)
        service = plain(held[:service])
        state.merge!(box_commit: state.delete(:commit), previous_tag: containers.tag_of(service),
                     project: plain(held[:project]), service: service)
        state.transform_values { |value| { value: value } }
      end

      private

      # The `BoxState` row of the project, and the containers it was read from.
      def survey(held)
        names = RollScript.new(plain(held[:project]), plain(held[:script])).names
        aws = Aws.new(@shell, names[:region])
        box = aws.instance(names[:box_stack])
        state, containers = read(aws, box, names)
        [{ box: box, **state }, containers]
      end

      # The box's commands are listed before the listing is sent, so it is never counted.
      def read(aws, box, names)
        rolling = aws.rolling?(box)
        containers = Containers.new(aws.on_box(box, Containers.listing(names[:directory])))
        [{ running: containers.running, commit: containers.commit,
           restore_point: aws.restore_point(names[:rds_stack]), rolling: rolling }, containers]
      end

      def plain(argument) = argument.is_a?(Hash) ? argument.transform_keys(&:to_sym)[:value] : argument
    end
  end
end
