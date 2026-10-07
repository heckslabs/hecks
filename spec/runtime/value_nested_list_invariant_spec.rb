require "spec_helper"

# A value object's list of value objects is checked member by member on input, however deep it
# sits: the same invariants refuse whether the list is on a command or inside another value object.
RSpec.describe Hecks::Runtime::Value, ".build with lists nested in value objects" do
  let(:article) do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Hecks.bluebook("NestedListInvariants") do
        aggregate("Article") do
          identified_by :slug

          attribute :slug, Slug
          attribute :body, Body

          value_object("Slug") { attribute :value, String }
          value_object("Body") { attribute :blocks, list_of(Block) }
          value_object("Block") do
            attribute :kind, String
            attribute :spans, list_of(Span)
            invariant("a block is a known kind") { ["paragraph", "divider"].include?(kind) }
          end
          value_object("Span") do
            attribute :text, String
            attribute :marks, list_of(Mark)
            attribute :href, String, optional: true
            invariant("a span has text") { !text.to_s.empty? }
            invariant("a link, once given, is not blank") { href.unset? || !href.to_s.empty? }
          end
          value_object("Mark") do
            attribute :name, String
            invariant("a mark is bold or italic") { ["bold", "italic"].include?(name) }
          end
        end
      end
    end
    registry.bluebook("NestedListInvariants").aggregate("Article")
  end

  def build_body(blocks) = described_class.build(article.value_object("Body"), { blocks: blocks }, article)

  def paragraph(*spans) = { kind: "paragraph", spans: spans }

  it "accepts a body whose every member is valid" do
    body = build_body([paragraph({ text: "hi", marks: [{ name: "bold" }] }), { kind: "divider", spans: [] }])

    expect(body.blocks.size).to eq(2)
  end

  it "reads an optional field the caller left out as nil in an invariant" do
    expect { build_body([paragraph({ text: "x", marks: [] })]) }.not_to raise_error
  end

  it "still checks an optional field that was sent" do
    expect { build_body([paragraph({ text: "x", marks: [], href: "" })]) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /a link, once given, is not blank/)
  end

  it "refuses a member of the list inside the value object" do
    expect { build_body([{ kind: "carousel", spans: [] }]) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /a block is a known kind/)
  end

  it "refuses a member two lists down" do
    expect { build_body([paragraph({ text: "", marks: [] })]) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /a span has text/)
  end

  it "refuses a member three lists down" do
    expect { build_body([paragraph({ text: "x", marks: [{ name: "sparkle" }] })]) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /a mark is bold or italic/)
  end

  it "refuses a later member as readily as the first" do
    expect { build_body([paragraph({ text: "x", marks: [] }), { kind: "carousel", spans: [] }]) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /a block is a known kind/)
  end
end
