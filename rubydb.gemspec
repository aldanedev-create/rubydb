# frozen_string_literal: true

require_relative 'lib/rubydb/version'

Gem::Specification.new do |spec|
  spec.name = 'rubydb'
  spec.version = RubyDB::VERSION
  spec.authors = ['Your Name']
  spec.email = ['you@example.com']

  spec.summary = 'A developer-first relational database for Ruby'
  spec.description = <<~DESC
    RubyDB is a production-capable, developer-first relational database 
    written in Ruby. It combines SQLite-like simplicity with PostgreSQL-like 
    production capabilities, with first-class Ruby and Rails integration.
  DESC
  spec.homepage = 'https://github.com/yourusername/rubydb'
  spec.license = 'MIT'
  # The implementation is currently compatible with the workspace Ruby runtime used for
  # local development and CI. This is a practical compatibility target until the
  # project adds a narrower support matrix and explicit Ruby-version policy.
  spec.required_ruby_version = '>= 3.3.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/yourusername/rubydb'
  spec.metadata['changelog_uri'] = 'https://github.com/yourusername/rubydb/blob/main/CHANGELOG.md'

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      f.match(%r{^(test|spec|features|benchmarks|fuzz|chaos|examples)/})
    end
  end
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'digest', '~> 3.1'
  spec.add_dependency 'json', '~> 2.7'
  spec.add_dependency 'date', '~> 3.3'
  spec.add_dependency 'time', '~> 0.4'
end