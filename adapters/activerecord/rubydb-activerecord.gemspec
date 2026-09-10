# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rubydb-activerecord"
  spec.version = "0.1.1"
  spec.authors = ["Aldane Hutchinson"]
  spec.email = ["aldanehutchinson5@gmail.com"]

  spec.summary = "ActiveRecord adapter for RubyDB"
  spec.description = "ActiveRecord adapter for the RubyDB database"
  spec.homepage = "https://github.com/aldanedev-create/rubydb"
  spec.license = "MIT"
  # rubydb itself requires Ruby 3.3 or newer. Keep the adapter's runtime
  # contract aligned so Bundler cannot select an unsupported combination.
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/adapters/activerecord"
  spec.metadata["bug_tracker_uri"] = "https://github.com/aldanedev-create/rubydb/issues"
  spec.metadata["changelog_uri"] = "https://github.com/aldanedev-create/rubydb/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "https://github.com/aldanedev-create/rubydb/tree/main/docs"

  spec.files = Dir.glob("lib/**/*.rb") + %w[README.md rubydb-activerecord.gemspec]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.1", "< 8.1"
  spec.add_dependency "rubydb", "~> 0.1.0"

  spec.add_development_dependency "rake", "~> 13.2"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.60"
end
