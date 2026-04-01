require "spec_helper"
require "hecks_cli"

RSpec.describe "hecks visualize" do
  let(:cli) { Hecks::CLI.new }

  before { allow($stdout).to receive(:puts) }

  BLUEBOOK_DSL = <<~RUBY
    Hecks.domain "TestViz" do
      aggregate "Widget" do
        attribute :name, String
        command "CreateWidget" do
          attribute :name, String
        end
        event "WidgetCreated"
      end
    end
  RUBY

  def run_visualize(cli, extra_options = {})
    output = StringIO.new
    cli.instance_variable_set(:@shell, Thor::Shell::Basic.new)
    allow(cli).to receive(:options).and_return(extra_options)
    allow(cli.shell).to receive(:say) { |msg, *| output.puts(msg) }
    cli.visualize
    output.string
  end

  it "prints mermaid diagrams to stdout by default" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "TestVizBluebook"), BLUEBOOK_DSL)
      Dir.chdir(dir) do
        output = run_visualize(cli, {})
        expect(output).to include("mermaid")
      end
    end
  end

  it "--type structure produces classDiagram" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "TestVizBluebook"), BLUEBOOK_DSL)
      Dir.chdir(dir) do
        output = run_visualize(cli, { type: "structure" })
        expect(output).to include("classDiagram")
        expect(output).not_to include("flowchart")
      end
    end
  end

  it "--type behavior produces flowchart" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "TestVizBluebook"), BLUEBOOK_DSL)
      Dir.chdir(dir) do
        output = run_visualize(cli, { type: "behavior" })
        expect(output).to include("flowchart")
        expect(output).not_to include("classDiagram")
      end
    end
  end

  it "--type ports produces port flowchart" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "TestVizBluebook"), BLUEBOOK_DSL)
      Dir.chdir(dir) do
        output = run_visualize(cli, { type: "ports" })
        expect(output).to include("flowchart LR")
        expect(output).to include("TestViz")
      end
    end
  end

  it "--type flows produces sequenceDiagram" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "TestVizBluebook"), BLUEBOOK_DSL)
      Dir.chdir(dir) do
        output = run_visualize(cli, { type: "flows" })
        expect(output).to include("sequenceDiagram")
      end
    end
  end

  it "--browser creates an HTML tempfile with mermaid" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "TestVizBluebook"), BLUEBOOK_DSL)
      Dir.chdir(dir) do
        html_path = nil
        allow(cli).to receive(:system)

        cli.instance_variable_set(:@shell, Thor::Shell::Basic.new)
        allow(cli).to receive(:options).and_return({ browser: true })
        allow(cli.shell).to receive(:say)

        # Capture the tempfile path via open_in_browser return
        allow(cli).to receive(:open_in_browser).and_wrap_original do |original, content|
          path = original.call(content)
          html_path = path
          path
        end

        cli.visualize

        expect(html_path).not_to be_nil
        expect(File.exist?(html_path)).to be true
        html_content = File.read(html_path)
        expect(html_content).to include("mermaid")
        expect(html_content).to include("<!DOCTYPE html>")
      end
    end
  end

  it "--output writes diagram to file" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "TestVizBluebook"), BLUEBOOK_DSL)
      Dir.chdir(dir) do
        output_file = File.join(dir, "diagram.md")
        cli.instance_variable_set(:@shell, Thor::Shell::Basic.new)
        allow(cli).to receive(:options).and_return({ output: output_file })
        allow(cli.shell).to receive(:say)

        cli.visualize

        expect(File.exist?(output_file)).to be true
        expect(File.read(output_file)).to include("mermaid")
      end
    end
  end
end
