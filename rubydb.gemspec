# frozen_string_literal: true

require_relative "lib/rubydb/version"

Gem::Specification.new do |spec|
  spec.name = "rubydb"
  spec.version = RubyDB::VERSION
  spec.authors = ["Aldane Hutchinson"]
  spec.email = ["aldanehutchinson5@gmail.com"]

  spec.summary = "A developer-first relational database for Ruby"
  spec.description = <<~DESC
    RubyDB is a developer-first relational database foundation written in Ruby.
    It combines SQLite-like simplicity with a growing SQL, WAL, MVCC, server,
    replication, and Rails integration surface. Production deployment is
    limited to the capabilities and validation documented by the project.
  DESC
  spec.homepage = "https://github.com/aldanedev-create/rubydb"
  spec.license = "MIT"
  # The implementation is currently compatible with the workspace Ruby runtime used for
  # local development and CI. This is a practical compatibility target until the
  # project adds a narrower support matrix and explicit Ruby-version policy.
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/aldanedev-create/rubydb/tree/main"
  spec.metadata["changelog_uri"] = "https://github.com/aldanedev-create/rubydb/blob/main/CHANGELOG.md"

  # RubyGems signing is opt-in for release builders. The private key and
  # certificate are supplied through protected CI paths and never committed.
  signing_key = ENV["RUBYDB_GEM_SIGNING_KEY"]
  certificate = ENV["RUBYDB_GEM_CERT"]
  if signing_key || certificate
    raise "RUBYDB_GEM_SIGNING_KEY and RUBYDB_GEM_CERT must be provided together" unless signing_key && certificate
    raise "RubyGems signing key not found: #{signing_key}" unless File.file?(signing_key)
    raise "RubyGems certificate not found: #{certificate}" unless File.file?(certificate)

    spec.signing_key = signing_key
    spec.cert_chain = [File.read(certificate)]
  end

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    tracked_files = `git ls-files -z`.split("\x0")
    accelerator_files = Dir[
      "accelerator/bin/rubydb-accelerator-*",
      "accelerator/bin/SHA256SUMS",
      "accelerator/cmd/**/*.go",
      "accelerator/internal/**/*.go",
      "accelerator/go.mod"
    ]
    runtime_files = Dir["lib/rubydb/accelerator.rb", "lib/rubydb/accelerator/**/*.rb", "lib/rubydb/cli/commands/accelerator.rb", "lib/rubydb/storage/snapshot_reader.rb"]
    physical_execution_files = Dir["lib/rubydb/execution/physical_plan.rb", "lib/rubydb/execution/cost_model.rb", "lib/rubydb/execution/operator_selection.rb", "lib/rubydb/execution/accelerator_dispatch.rb"]
    (tracked_files + accelerator_files + runtime_files + physical_execution_files).uniq.select { |f| File.file?(f) }.reject do |f|
      f.match?(%r{^(test|spec|features|benchmarks|fuzz|chaos|examples|adapters/python)/}) || f.end_with?("_test.go")
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "digest", "~> 3.1"
  spec.add_dependency "json", "~> 2.7"
  spec.add_dependency "date", "~> 3.3"
  spec.add_dependency "time", "~> 0.4"
  spec.add_dependency "bigdecimal", ">= 3.1"
  spec.add_dependency "concurrent-ruby", ">= 1.2"
  spec.add_dependency "base64", ">= 0.2"
end
