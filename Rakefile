# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require 'rbconfig'

RSpec::Core::RakeTask.new(:spec)

task default: %i[spec rubocop]

desc 'Run all tests'
task test: :spec

desc 'Run unit tests only'
RSpec::Core::RakeTask.new(:'test:unit') do |t|
  t.pattern = 'test/unit/**/*_spec.rb'
end

desc 'Run integration tests only'
RSpec::Core::RakeTask.new(:'test:integration') do |t|
  t.pattern = 'test/integration/**/*_spec.rb'
end

begin
  require 'rubocop/rake_task'
  RuboCop::RakeTask.new
rescue LoadError
  # rubocop not installed
end

namespace :test do
  desc 'Run concurrency tests'
  RSpec::Core::RakeTask.new(:concurrency) do |t|
    t.pattern = 'test/concurrency/**/*_spec.rb'
  end

  desc 'Run crash tests'
  RSpec::Core::RakeTask.new(:crash) do |t|
    t.pattern = 'test/crash/**/*_spec.rb'
  end

  desc 'Run chaos tests'
  RSpec::Core::RakeTask.new(:chaos) do |t|
    t.pattern = 'test/chaos/**/*_spec.rb'
  end
end

desc 'Run benchmarks'
task :benchmark do
  Dir['benchmarks/**/*.rb'].each { |f| load f }
end

desc 'Run the concurrent workload and durability verification'
task :workload do
  abort 'Concurrent workload failed' unless system(RbConfig.ruby, 'benchmarks/concurrent_workload.rb')
end
