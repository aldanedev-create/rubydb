# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rubydb-activerecord"
  spec.version = "0.1.0"
  spec.authors = ["Aldane Hutchinson"]
  spec.email = ["aldanehutchinson5@gmail.com"]

  spec.summary = "ActiveRecord adapter for RubyDB"
  spec.description = "ActiveRecord adapter for the RubyDB database"
  spec.homepage = "https://github.com/aldanedev-create/rubydb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.glob("lib/**/*.rb") + %w[README.md]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", "~> 7.2.0"
  spec.add_dependency "rubydb", "~> 0.1.0"

  spec.add_development_dependency "rake", "~> 13.2"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.60"
end
