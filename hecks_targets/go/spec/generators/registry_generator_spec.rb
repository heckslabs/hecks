require "spec_helper"
require "go_hecks"

RSpec.describe GoHecks::RegistryGenerator do
  let(:generator) { described_class.new }
  let(:output) { generator.generate }

  it "declares runtime package" do
    expect(output).to include("package runtime")
  end

  it "imports sync for thread safety" do
    expect(output).to include('"sync"')
  end

  describe "ModuleInfo struct" do
    it "defines Name field" do
      expect(output).to include("Name       string")
    end

    it "defines Aggregates field" do
      expect(output).to include("Aggregates []string")
    end

    it "defines Commands field" do
      expect(output).to include("Commands   []string")
    end

    it "defines Boot function field" do
      expect(output).to include("Boot       func(*Application)")
    end
  end

  describe "Register function" do
    it "defines Register with ModuleInfo parameter" do
      expect(output).to include("func Register(info ModuleInfo)")
    end

    it "uses mutex for thread safety" do
      expect(output).to include("registryMu.Lock()")
      expect(output).to include("defer registryMu.Unlock()")
    end
  end

  describe "Modules function" do
    it "defines Modules returning a map" do
      expect(output).to include("func Modules() map[string]ModuleInfo")
    end

    it "returns a copy for safe concurrent access" do
      expect(output).to include("result := make(map[string]ModuleInfo, len(modules))")
    end

    it "uses read lock" do
      expect(output).to include("registryMu.RLock()")
    end
  end
end
