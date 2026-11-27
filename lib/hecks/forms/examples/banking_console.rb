# The forms app over the Banking example: which bluebooks it exposes. A Forms app is configured in
# Ruby, beside the bluebooks it serves, not in one: `Forms.configure` is no bluebook word.
require_relative "../../forms"

Hecks::Forms.configure "BankingConsole" do
  expose "Banking"
end
