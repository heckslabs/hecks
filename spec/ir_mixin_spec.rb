require "spec_helper"

# The mixin that owns IR EMISSION, tested on its own rather than only
# through the golden fixtures — the fixtures prove the six converted
# constructs still emit byte-identically, which is the important
# guarantee, but they cannot show that the two SHAPES are handled the
# same way or that an undeclared construct fails loudly.
RSpec.describe Hecks::IR do
  # A construct that is an ordinary object — Bluebook/Aggregate/Policy/
  # ReadModel are all this shape.
  def instance_shaped
    Class.new do
      include Hecks::IR

      emits_ir(name: :name, loud: :loud?, computed: -> { "#{name}!" })

      attr_reader :name

      def initialize(name) = @name = name
      def loud? = true
    end
  end

  # A construct that is a CLASS, declared by subclassing — Command,
  # Entity and ValueObject are all this shape, because a bluebook names
  # them as types and a type has to be a real constant.
  def class_shaped
    Class.new do
      extend Hecks::IR

      emits_ir(name: :hecks_name, size: :size)

      class << self
        attr_accessor :hecks_name, :size

        def declare(name:, size:)
          shape = Class.new(self)
          shape.hecks_name = name
          shape.size = size
          shape
        end
      end
    end
  end

  describe "the instance shape" do
    it "emits declared fields in declaration order" do
      expect(instance_shaped.new("Order").to_h.keys).to eq(%i[name loud computed])
    end

    it "sends a Symbol, predicates included" do
      expect(instance_shaped.new("Order").to_h).to include(name: "Order", loud: true)
    end

    it "evaluates a Proc against the construct itself" do
      expect(instance_shaped.new("Order").to_h[:computed]).to eq("Order!")
    end
  end

  describe "the class shape" do
    # The load-bearing one: every declared value object and command IS a
    # `Class.new(Base)`, so a spec declared on the base has to reach the
    # anonymous subclass or nothing would emit at all.
    it "inherits the declaration into an anonymous subclass" do
      declared = class_shaped.declare(name: "Money", size: 2)

      expect(declared.to_h).to eq(name: "Money", size: 2)
    end
  end

  describe "many/one" do
    let(:child) do
      Class.new do
        include Hecks::IR

        emits_ir(n: :n)

        attr_reader :n

        def initialize(n) = @n = n
      end
    end

    it "recurses into a list with many" do
      parent = Class.new do
        include Hecks::IR

        emits_ir(kids: many(:kids))
        attr_reader :kids

        def initialize(kids) = @kids = kids
      end

      expect(parent.new([child.new(1), child.new(2)]).to_h).to eq(kids: [{ n: 1 }, { n: 2 }])
    end

    it "recurses into a single child with one" do
      parent = Class.new do
        include Hecks::IR

        emits_ir(kid: one(:kid))
        attr_reader :kid

        def initialize(kid) = @kid = kid
      end

      expect(parent.new(child.new(7)).to_h).to eq(kid: { n: 7 })
    end

    # A lifecycle is genuinely optional on an aggregate, so this is the
    # ordinary case rather than an edge one.
    it "answers nil for an absent child rather than raising" do
      parent = Class.new do
        include Hecks::IR

        emits_ir(kid: one(:kid))
        def kid = nil
      end

      expect(parent.new.to_h).to eq(kid: nil)
    end
  end

  it "refuses to emit a construct that never declared its shape" do
    silent = Class.new { include Hecks::IR }

    expect { silent.new.to_h }.to raise_error(Hecks::IR::Undeclared, /never declared its shape/)
  end

  # The point of declaring emission as DATA rather than writing it out:
  # anything that wants to know what a construct carries can now ask,
  # instead of reading a method body.
  describe "the declaration is readable" do
    it "reports the emitted shape of a real construct" do
      spec = Hecks::Bluebook::Aggregate.ir_spec

      expect(spec.keys).to include(:name, :attributes, :commands, :lifecycle)
      expect(spec[:attributes]).to be_a(Hecks::IR::Many)
      expect(spec[:lifecycle]).to be_a(Hecks::IR::One)
    end
  end
end
