require "spec_helper"
require_relative "support/lib_loading_slice"

# Slice 3 of 3 of "every lib file loads standalone in a fresh process"; the slices and the checks
# they share are in spec/support/lib_loading_slice.rb.
RSpec.describe "load hygiene, lib files, slice 3 of 3", :io do
  include LibLoadingSlice

  it "loads its slice of the lib files standalone, in a fresh process" do
    broken = broken_features(slice_of_features(2, 3))

    expect(broken).to be_empty, standalone_failure_message(broken)
  end
end
