# frozen_string_literal: true

require "rbconfig"
require "json"
require "rubygems"

repo = File.expand_path(ARGV.fetch(0))
spec = Gem::Specification.load(File.join(repo, "rubydb.gemspec"))
spec.runtime_dependencies.each { |dependency| dependency.to_spec.activate }
$LOAD_PATH.unshift(File.join(repo, "lib"))
require "rubydb"
require "openssl"

puts JSON.generate({
  prefix: RbConfig::CONFIG.fetch("prefix"),
  ruby_version: RUBY_VERSION,
  ruby_api_version: RbConfig::CONFIG.fetch("ruby_version"),
  rubydb_version: RubyDB::VERSION,
  ruby: RbConfig.ruby,
  load_paths: [RbConfig::CONFIG.fetch("rubylibdir"), RbConfig::CONFIG.fetch("rubyarchdir")],
  platform: Gem::Platform.local.to_s,
  gems: Gem.loaded_specs.values.map do |gem|
    {
      name: gem.name, version: gem.version.to_s, source: gem.full_gem_path,
      specification: gem.loaded_from, default: gem.default_gem?,
      extension: gem.extension_dir, has_extensions: !gem.extensions.empty?,
      licenses: gem.licenses
    }
  end
})
