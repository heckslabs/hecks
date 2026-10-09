require_relative "../evaluator"
require_relative "../resolver"

module Hecks
  module Bluebook
    module Expression
      module AstJson
        # One emitting lambda per node class, in the order `AstJson` tries them: `BOOL` for
        # boolean-position `Evaluator` nodes, `RESOLVER` for `Resolver` nodes. A node with no entry
        # raises in `AstJson`, so a new node kind cannot be dropped silently.
        module Emitters
          # A node whose only child is its receiver.
          def self.receiver_only(tag)
            ->(node) { { "op" => tag, "receiver" => AstJson.emit_resolver(node.receiver) } }
          end

          # A receiver followed by plain readers, each emitted under its own name.
          def self.receiver_with(tag, *readers)
            lambda do |node|
              row = receiver_only(tag).call(node)
              readers.each { |reader| row[reader.to_s] = node.public_send(reader) }
              row
            end
          end

          # A node holding one literal value.
          def self.literal(tag) = ->(node) { { "op" => tag, "value" => node.value } }

          # A node with a left and a right child, each emitted by `emitter`.
          def self.binary(tag, emitter)
            lambda do |node|
              { "op" => tag, "left" => AstJson.public_send(emitter, node.left),
                "right" => AstJson.public_send(emitter, node.right) }
            end
          end

          BOOL = {
            Evaluator::Or      => binary("or", :emit_bool),
            Evaluator::And     => binary("and", :emit_bool),
            Evaluator::Not     => ->(node) { { "op" => "not", "expr" => AstJson.emit_bool(node.node) } },
            Evaluator::Compare => lambda { |node|
              { "op" => "compare", "cmp" => AstJson.emit_comparison(node.operator),
                "left" => AstJson.emit_resolver(node.left), "right" => AstJson.emit_resolver(node.right) }
            },
            Evaluator::Include => ->(node) { AstJson.emit_include(node) },
            Evaluator::Resolve => ->(node) { AstJson.emit_resolver(node.expr) }
          }.freeze

          RESOLVER = {
            Resolver::IntegerLiteral => literal("int"),
            Resolver::FloatLiteral   => literal("float"),
            Resolver::StringLiteral  => literal("str"),
            Resolver::BoolLiteral    => literal("bool"),
            Resolver::NilLiteral     => ->(_node) { { "op" => "nil" } },
            # Segments, as `find.path` has, so a reader need not split a dotted string.
            Resolver::Lookup         => ->(node) { { "op" => "lookup", "path" => node.path.split(".") } },
            Resolver::Addition       => binary("add", :emit_resolver),
            Resolver::SignTest       => lambda { |node|
              { "op" => "sign_test", "cmp" => AstJson.emit_comparison(node.operator),
                "receiver" => AstJson.emit_resolver(node.receiver) }
            },
            Resolver::Empty          => receiver_only("empty"),
            Resolver::ToS            => receiver_only("to_s"),
            Resolver::Modulo         => lambda { |node|
              { "op" => "modulo", "receiver" => AstJson.emit_resolver(node.receiver),
                "divisor" => AstJson.emit_resolver(node.divisor) }
            },
            Resolver::Size           => receiver_only("size"),
            Resolver::BlockPredicate => lambda { |node|
              { "op" => "block_predicate", "mode" => node.mode.to_s, "receiver" => AstJson.emit_resolver(node.receiver),
                "param" => node.param.to_s, "predicate" => AstJson.emit_bool(node.predicate) }
            },
            Resolver::Find           => lambda { |node|
              { "op" => "find", "receiver" => AstJson.emit_resolver(node.receiver), "param" => node.param.to_s,
                "predicate" => AstJson.emit_bool(node.predicate), "path" => node.path.map(&:to_s) }
            },
            Resolver::ArrayLiteral   => lambda { |node|
              { "op" => "array", "elements" => node.elements.map { |element| AstJson.emit_resolver(element) } }
            },
            Resolver::MatchesRegex   => receiver_with("matches_regex", :pattern, :flags),
            Resolver::Presence       => receiver_with("presence", :negated),
            Resolver::Assignment     => receiver_with("assignment", :negated),
            Resolver::Split          => receiver_with("split", :separator),
            Resolver::Strip          => lambda { |node|
              { "op" => "strip", "receiver" => AstJson.emit_resolver(node.receiver), "side" => node.side.to_s }
            },
            Resolver::StartsWith     => receiver_with("starts_with", :substring),
            Resolver::EndsWith       => receiver_with("ends_with", :substring),
            Resolver::First          => receiver_only("first"),
            Resolver::Last           => receiver_only("last")
          }.freeze
        end
      end
    end
  end
end
