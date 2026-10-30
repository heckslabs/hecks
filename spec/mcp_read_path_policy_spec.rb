require "spec_helper"

# `path` is denied by name for every command, since it can name a place to write. The read-only
# questions that take one file of the checkout are the exception, and the exception still confines
# the path to the checkout (ADR 0089).
RSpec.describe Hecks::Adapters::Driving::McpScope::ArgumentPolicy do
  let(:label) { "commands mode" }

  it "admits a path inside the checkout for a read-only question" do
    expect { described_class.admit!({ "path" => "lib/hecks/hecks/codebase.bluebook" }, label, "inspection_run.read_source") }
      .not_to raise_error
  end

  it "admits the same path for the outline question" do
    expect { described_class.admit!({ "path" => "lib/hecks/hecks/codebase.bluebook" }, label, "inspection_run.outline") }
      .not_to raise_error
  end

  it "accepts the Capitalised question name the door also takes" do
    expect { described_class.admit!({ "path" => "lib/hecks/hecks/codebase.bluebook" }, label, "InspectionRun.read_source") }
      .not_to raise_error
  end

  it "refuses a path outside the checkout for a read-only question" do
    expect { described_class.admit!({ "path" => "/etc/passwd" }, label, "inspection_run.read_source") }
      .to raise_error(Hecks::Runtime::TypeMismatch, /resolves inside/)
  end

  it "refuses a parent-directory escape for a read-only question" do
    expect { described_class.admit!({ "path" => "../../../../etc/passwd" }, label, "inspection_run.read_source") }
      .to raise_error(Hecks::Runtime::TypeMismatch, /resolves inside/)
  end

  it "still refuses path for a command that is not a read-only question" do
    expect { described_class.admit!({ "path" => "lib/hecks/hecks/codebase.bluebook" }, label, "model_check_run.model_check") }
      .to raise_error(Hecks::Runtime::TypeMismatch, /never passes it on/)
  end

  it "still refuses path when no question is named" do
    expect { described_class.admit!({ "path" => "lib/hecks/hecks/codebase.bluebook" }, label) }
      .to raise_error(Hecks::Runtime::TypeMismatch, /never passes it on/)
  end

  it "admits the line window for a read-only question" do
    args = { "path" => "lib/hecks/hecks/codebase.bluebook", "from" => 1, "to" => 5, "top" => 20 }
    expect { described_class.admit!(args, label, "inspection_run.read_source") }.not_to raise_error
  end

  it "still refuses from for a command that is not a read-only question" do
    expect { described_class.admit!({ "from" => 1 }, label, "model_check_run.model_check") }
      .to raise_error(Hecks::Runtime::TypeMismatch, /"from" is refused/)
  end
end
