require "spec_helper"

# `BluebookBuilder#build` ends with `MetaValidator.call`, so the graph a registry holds is not the
# builder's: it is what the meta-domain assembles after the chapter's own declarations are
# dispatched into it. These specs hold that product to the builder's IR, so loading by dispatch
# loses nothing the DSL said.
RSpec.describe "a chapter loaded by dispatching its own declarations" do
  DISPATCH_CORPUS = {
    "Pizzas"   => "examples/pizzas/bluebook/pizzas.bluebook",
    "Banking"  => InMemoryDomain::BANKING_BLUEBOOK_DIR,
    "TillRoom" => "spec/fixtures/till.bluebook",
    "Wire"     => "spec/fixtures/settlement.bluebook"
  }.freeze

  def load_chapter(file)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      load_bluebook_files(File.absolute_path(file, InMemoryDomain::ROOT))
    end
    registry
  end

  def plain(node)
    case node
    when Hash then node.to_h { |key, value| [key.to_s, plain(value)] }
    when Array then node.map { |element| plain(element) }
    when Symbol then node.to_s
    else node
    end
  end

  def differences(built, product, path = "")
    return [] if built == product
    return hash_differences(built, product, path) if both?(built, product, Hash)
    return array_differences(built, product, path) if both?(built, product, Array) && built.size == product.size

    ["#{path}: built #{built.inspect[0, 60]}, product #{product.inspect[0, 60]}"]
  end

  def hash_differences(built, product, path)
    built.keys.flat_map { |key| differences(built[key], product[key], "#{path}.#{key}") }
  end

  def array_differences(built, product, path)
    built.each_with_index.flat_map { |held, i| differences(held, product[i], "#{path}[#{i}]") }
  end

  def both?(left, right, kind) = left.is_a?(kind) && right.is_a?(kind)

  def report(found) = "#{found.size} differences, first ten:\n#{found.first(10).join("\n")}"

  DISPATCH_CORPUS.each do |name, file|
    it "#{name} comes out as the builder made it", :aggregate_failures do
      built = Hecks::Bluebook::MetaValidator.while_disabled { load_chapter(file).bluebook(name) }
      product = load_chapter(file).bluebook(name)
      found = differences(plain(built.to_h), plain(product.to_h))

      expect(found).to be_empty, report(found)
    end
  end

  # The language's own `member` rows quote their cells (`at: "1"`, `required: "true"`); a quoted
  # cell is a String in the builder and stays one in the product.
  %w[Bluebook World Hecksagon].each do |name|
    it "#{name}, the language itself, comes out as the builder made it" do
      built = Hecks::Bluebook::MetaValidator.load_grammar_into(Hecks::Runtime::Registry.new).bluebook(name)
      product = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook(name)
      found = differences(plain(built.to_h), plain(product.to_h))

      expect(found).to be_empty, report(found)
    end
  end
end
