source "https://rubygems.org"

gemspec

%w[hecksties hecks_workshop hecks_ai bluebook hecksagon].each do |component|
  gemspec path: component if File.exist?("#{component}/#{component}.gemspec")
end

group :development, :test do
  gem "rake"
  gem "rspec", "~> 3.0"
  gem "webrick"
  gem "railties", "~> 8.0"
  gem "activemodel", ">= 6.0", "< 10.0"
  gem "sqlite3", ">= 1.4", "< 3.0"
  gem "rdoc", ">= 6.4", "< 6.7"
  gem "sdoc"
  gem "mongo"
  gem "reek"
  gem "flay"
  gem "flog"
  gem "debride"
  gem "fasterer"
  gem "bundler-audit"
end
