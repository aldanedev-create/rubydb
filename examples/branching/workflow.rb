# frozen_string_literal: true

# Branch a logical database state, add a feature change, and check it out.
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "tmpdir"
require "rubydb"

Dir.mktmpdir("rubydb-branching") do |directory|
  engine = RubyDB::Storage::Engine.new(File.join(directory, "branching.rdb"), auto_cleanup: false, auto_vacuum: false)
  begin
    columns = [
      RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
      RubyDB::Catalog::Column.new(:name, :varchar, null: false)
    ]
    engine.create_table(:users, columns)
    engine.insert_row(:users, columns, {id: 1, name: "Ada"})

    manager = RubyDB::Branching::BranchManager.new(engine, branch_dir: File.join(directory, "branches"))
    created = manager.create_branch("feature", from: "main", description: "Add Grace")
    raise created[:error] unless created[:success]

    checked_out = manager.checkout("feature")
    raise checked_out[:error] unless checked_out[:success]
    manager.commit(operation: "insert", table: "users", values: {id: 2, name: "Grace"})
    checked_out = manager.checkout("feature")
    raise checked_out[:error] unless checked_out[:success]

    rows = engine.select_rows(:users, columns).sort_by do |row|
      (row[:id] || row["id"] || row[:_row_id] || row["_row_id"]).to_i
    end
    raise "feature branch was not applied" unless rows.length == 2
    puts "Current branch: #{manager.current_branch_name}"
    puts "Feature rows: #{rows.inspect}"
  ensure
    engine.close
  end
end
