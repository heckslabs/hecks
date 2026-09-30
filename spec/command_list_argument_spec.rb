require "spec_helper"
require "tmpdir"
require "fileutils"

# A command's own `list_of` argument is an Array whatever its element type: a lone scalar is
# refused, and the launcher door folds its list spellings into an Array before the runtime sees
# them. `append:`/`remove:` take one element by design, coerced against the aggregate's own list.
RSpec.describe "a command's list_of argument" do
  BINDER_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Binder" do
      vision "Folders carrying labels."

      aggregate "Folder" do
        description "A folder."
        value_object("FolderName") { attribute :value, String }
        value_object("Label") { attribute :value, String }
        identified_by FolderName, as: :name
        attribute :labels, list_of(Label)

        command "Open" do
          attribute :name, FolderName
          attribute :labels, list_of(Label)
          sets :labels
          emits Opened
        end

        command "Relabel" do
          attribute :labels, list_of(Label)
          sets :labels
          emits Relabeled
        end

        command "Note" do
          attribute :words, list_of(String)
          emits Noted
        end

        command "Attach" do
          attribute :label, String
          sets :labels, append: { value: :label }
          emits Attached
        end

        command "Replace" do
          attribute :only, String
          sets :labels, to: :only
          emits Replaced
        end

        command "Detach" do
          attribute :label, String
          sets :labels, remove: :label
          emits Detached
        end
      end
    end
  RUBY

  around do |example|
    Dir.mktmpdir("binder") do |dir|
      FileUtils.mkdir_p(File.join(dir, "bluebook"))
      File.write(File.join(dir, "bluebook/binder.bluebook"), BINDER_BLUEBOOK)
      @runtime = Hecks.boot(dir, install_facade: false)
      example.run
    end
  end

  def open_folder(labels) = @runtime.dispatch("Binder::Folder.Open", with: { name: { value: rand.to_s }, labels: labels })

  it "takes an Array" do
    expect { open_folder([{ value: "a" }, { value: "b" }]) }.not_to raise_error
    expect { open_folder([]) }.not_to raise_error
    expect { @runtime.dispatch("Binder::Folder.Note", to: open_folder([]).id, with: { words: %w[a b] }) }
      .not_to raise_error
  end

  it "refuses a lone scalar naming the argument and the expected list" do
    expect { open_folder("a") }
      .to raise_error(Hecks::Runtime::TypeMismatch, /Open\.labels expects list_of\(Label\), got "a"/)
    expect { open_folder({ value: "a" }) }.to raise_error(Hecks::Runtime::TypeMismatch, /Open\.labels/)
  end

  it "refuses a lone scalar for a list_of(String) argument" do
    id = open_folder([]).id
    expect { @runtime.dispatch("Binder::Folder.Note", to: id, with: { words: "a,b" }) }
      .to raise_error(Hecks::Runtime::TypeMismatch, /Note\.words expects list_of\(String\), got "a,b"/)
  end

  it "refuses a scalar on a command that only sets the list" do
    id = open_folder([]).id
    expect { @runtime.dispatch("Binder::Folder.Relabel", to: id, with: { labels: "b" }) }
      .to raise_error(Hecks::Runtime::TypeMismatch, /Relabel\.labels expects list_of\(Label\)/)
  end

  it "refuses a plain sets of a list from a lone scalar, though append and remove take one element" do
    id = open_folder([]).id
    expect { @runtime.dispatch("Binder::Folder.Replace", to: id, with: { only: "x" }) }
      .to raise_error(Hecks::Runtime::TypeMismatch, /labels expects list_of\(Label\), got "x"/)
  end

  it "keeps the single-element form for the append and remove effects" do
    id = open_folder([]).id
    @runtime.dispatch("Binder::Folder.Attach", to: id, with: { label: "x" })
    two = @runtime.dispatch("Binder::Folder.Attach", to: id, with: { label: "y" })
    expect(two.state[:labels].size).to eq(2)
    one = @runtime.dispatch("Binder::Folder.Detach", to: id, with: { label: "x" })
    expect(one.state[:labels].size).to eq(1)
  end
end

RSpec.describe Hecks::Facade::CliDoor, "list-of-words arguments" do
  let(:spec) do
    { arguments: [{ path: "labels", type: "String", required: true, list: true, words: true },
                  { path: "counts", type: "Integer", required: false, list: true, words: true },
                  { path: "name", type: "String", required: true }] }
  end

  def args(*words) = described_class.arguments(spec, words)

  it "reads a comma-separated value as a list" do
    expect(args("labels=a,b")[:labels]).to eq(%w[a b])
  end

  it "reads a repeated name as a list" do
    expect(args("labels=a", "labels=b")[:labels]).to eq(%w[a b])
  end

  it "keeps a lone word a one-item list" do
    expect(args("labels=a")[:labels]).to eq(%w[a])
  end

  it "casts each word to the element type" do
    expect(args("counts=1,2", "counts=3")[:counts]).to eq([1, 2, 3])
  end

  it "leaves a scalar argument scalar" do
    expect(args("name=a,b")[:name]).to eq("a,b")
  end
end
