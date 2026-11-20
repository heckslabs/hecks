# frozen_string_literal: true

require "fileutils"

# Boots the PipelineBoard bluebook and its own hecksagons in a scratch directory with a stand-in
# adapter behind every port that answers a query, so a spec asks a typed query through the
# runtime and no reader runs. A stand-in answers whatever the spec hands it, so the spec decides
# the rows the runtime must build or refuse.
module TypedBoardBoot
  SOURCE = File.expand_path("../../lib/hecks/pipeline_board", __dir__)
  FILES = %w[pipeline_board.bluebook pipeline_board.hecksagon pipeline_board.ports.hecksagon].freeze
  PORT = /\.port "(\w+)" do\n(.*?)\n  end/m
  QUERY = /answers_query "(\w+)"/

  # @return [Hash{Symbol => Object}] what every stand-in answers, by the query's name
  def self.answers = (@answers ||= {})

  ADAPTER = <<~RUBY
    module Hecks
      module Adapters
        class TypedBoard%<port>s
          def initialize(**); end

          %<methods>s
        end
      end
    end
  RUBY

  DECLARATION = <<~RUBY
    require_relative "typed_board_%<file>s"

    Hecks.adapter "TypedBoard%<port>s" do
      port "%<port>s"
    end
  RUBY

  # @return [Hash{String => Array<String>}] each port that answers a query, and its queries
  def typed_board_ports
    declared = File.read(File.join(SOURCE, "pipeline_board.ports.hecksagon")).scan(PORT)
    declared.to_h { |port, body| [port, body.scan(QUERY).flatten] }.reject { |_, queries| queries.empty? }
  end

  # Writes one stand-in adapter and its declaration for a port.
  def write_typed_stand_in(dir, port, queries)
    methods = queries.map { |query| "def #{Hecks::Naming.snake(query)}(**) = ::TypedBoardBoot.answers.fetch(:#{query})" }
    file = port.downcase
    File.write(File.join(dir, "typed_board_#{file}.rb"), format(ADAPTER, port: port, methods: methods.join("\n\n      ")))
    File.write(File.join(dir, "typed_board_#{file}.adapter"), format(DECLARATION, port: port, file: file))
  end

  # @param dir [String] a scratch directory
  # @return [Hecks::Runtime] the booted board, a stand-in behind each port
  def boot_typed_board(dir)
    FILES.each { |file| FileUtils.cp(File.join(SOURCE, file), dir) }
    FileUtils.mkdir_p(File.join(dir, "adapters"))
    typed_board_ports.each { |port, queries| write_typed_stand_in(File.join(dir, "adapters"), port, queries) }
    Hecks.boot(dir, install_driving: false)
  end

  # @param dir [String] a scratch directory
  # @param query [String] a query of the PipelineBoard aggregate
  # @param answer [Object] what the stand-in answers it with
  # @return [Array<Hash>] the rows the runtime built
  def ask_typed_board(dir, query, answer, **arguments)
    TypedBoardBoot.answers[query.to_sym] = answer
    boot_typed_board(dir).query("PipelineBoard::PipelineBoard.#{query}", **arguments)
  end
end
