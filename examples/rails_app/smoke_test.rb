# frozen_string_literal: true

require_relative "config/environment"
require_relative "app/models/task"

raise "tasks table is missing" unless ActiveRecord::Base.connection.table_exists?("tasks")

task = Task.create!(title: "RubyDB ActiveRecord smoke test")
loaded = Task.where(title: task.title).first
raise "ActiveRecord query failed: #{Task.all.map(&:attributes).inspect}" unless loaded && loaded.title == task.title

puts "Rails + RubyDB smoke test passed: task ##{task.id}"
