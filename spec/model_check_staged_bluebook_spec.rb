require "spec_helper"
require "hecks"
require "hecks/tools/model_check"
require "tmpdir"

# `hecks model_check` runs on directories, so accepted bluebook lines are staged as a file in a
# temporary directory and checked there (ADR 0194, decision 10): a self-contained staged file
# passes, and one whose reference names no aggregate is reported.

# A self-contained staged file: two aggregates, the second referencing the first.
STAGED_DISCOVERY_LINES = <<~RUBY.freeze
  Hecks.bluebook "Staged" do
    vision "Discovery points accepted in an interview, staged for the check."
    core

    aggregate "Customer" do
      identified_by :ref
      attribute :ref, Ref
      value_object("Ref") { attribute :value, String }

      command "Register" do
        role "Tester"
        goal "Bring a customer into being"
        attribute :ref, Ref
        emits "Registered"
      end
    end

    aggregate "Order" do
      identified_by :ref
      attribute :ref, Ref
      reference_to Customer
      value_object("Ref") { attribute :value, String }

      command "Place" do
        role "Tester"
        goal "Place an order for a customer"
        attribute :ref, Ref
        reference_to Customer
        emits "Placed"
      end
    end
  end
RUBY

RSpec.describe "model_check over a staged bluebook file" do
  # Stages `lines` as the one file of a scratch directory and returns the status the check
  # exits with; a check that returns without exiting gives :returned.
  def staged_exit_status(lines)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "staged.bluebook"), lines)
      Hecks::Tools::ModelCheck.call([dir], program: "hecks model_check")
      :returned
    rescue SystemExit => e
      e.status
    end
  end

  it "accepts a valid staged file and exits 0", :aggregate_failures do
    status = nil
    expect { status = staged_exit_status(STAGED_DISCOVERY_LINES) }.to output.to_stdout
    expect(status).to eq(0)
  end

  it "reports a staged reference to an aggregate the file does not declare", :aggregate_failures do
    status = nil
    ghost  = STAGED_DISCOVERY_LINES.gsub("reference_to Customer", "reference_to Ghost")
    expect { status = staged_exit_status(ghost) }
      .to output(/Staged:Order#attributes\[1\]: no Aggregate with bluebook.*Staged:Ghost/).to_stderr
    expect(status).to eq(1)
  end
end
