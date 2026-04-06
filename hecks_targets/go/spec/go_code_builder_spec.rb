require "spec_helper"
require "go_hecks"

RSpec.describe GoHecks::GoCodeBuilder do
  subject(:builder) { described_class.new("domain") }

  describe "#to_s" do
    it "outputs a package declaration" do
      expect(builder.to_s).to start_with("package domain\n")
    end

    it "renders a single import without parens" do
      builder.imports('"fmt"')
      expect(builder.to_s).to include("import \"fmt\"\n")
    end

    it "renders multiple imports in a grouped block" do
      builder.imports('"fmt"', '"time"')
      out = builder.to_s
      expect(out).to include("import (")
      expect(out).to include("\t\"fmt\"")
      expect(out).to include("\t\"time\"")
    end

    it "deduplicates imports" do
      builder.imports('"fmt"', '"fmt"')
      expect(builder.to_s.scan('"fmt"').size).to eq(1)
    end
  end

  describe "#struct" do
    it "generates a struct with json-tagged fields" do
      builder.struct("Pizza") do |s|
        s.field("Name", "string", json: "name")
        s.field("Size", "int", json: "size")
      end
      out = builder.to_s
      expect(out).to include("type Pizza struct {")
      expect(out).to include("\tName string `json:\"name\"`")
      expect(out).to include("\tSize int `json:\"size\"`")
    end

  end

  describe "#const_block" do
    it "generates a const block" do
      builder.const_block do |c|
        c.value("StatusActive", '"active"')
        c.value("StatusDone", '"done"')
      end
      out = builder.to_s
      expect(out).to include("const (")
      expect(out).to include("\tStatusActive = \"active\"")
      expect(out).to include("\tStatusDone = \"done\"")
    end
  end

  describe "#receiver" do
    it "generates a pointer receiver method" do
      builder.receiver("Pizza", "Validate", "error") do |m|
        m.line("return nil")
      end
      expect(builder.to_s).to include("func (p *Pizza) Validate() error {")
      expect(builder.to_s).to include("\treturn nil")
    end
  end

  describe "#one_liner" do
    it "generates a single-line receiver method" do
      builder.one_liner("Pizza", "Name", "string", 'return p.Name')
      expect(builder.to_s).to include('func (p *Pizza) Name() string { return p.Name }')
    end

    it "generates a value receiver when pointer is false" do
      builder.one_liner("Event", "EventName", "string", 'return "Created"', pointer: false)
      expect(builder.to_s).to include('func (e Event) EventName() string { return "Created" }')
    end
  end

  describe "#func" do
    it "generates a standalone function" do
      builder.func("NewPizza(name string)", nil, "*Pizza") do |m|
        m.line("return &Pizza{Name: name}")
      end
      expect(builder.to_s).to include("func NewPizza(name string) *Pizza {")
    end
  end

end
