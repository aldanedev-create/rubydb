# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "engine trigger execution" do
  it "fires callable triggers for insert, update, and delete" do
    Dir.mktmpdir do |dir|
      catalog = RubyDB::Catalog::Catalog.new
      catalog.create_database("app")
      engine = RubyDB::Storage::Engine.new(File.join(dir, "db.rdb"), catalog: catalog, auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new("id", :integer)]
      engine.create_table("users", columns)
      events = []
      trigger = RubyDB::Catalog::Trigger.new("audit", %i[insert update delete], "users", ->(**payload) { events << payload[:event] })
      catalog.current_database.add_trigger(trigger)

      engine.insert_row("users", columns, [1])
      expect(events).to eq([:insert])
      expect(engine.update_row("users", 1, { "id" => 2 })).to be(true)
      expect(engine.delete_row("users", 1)).to be(true)
      expect(events).to eq([:insert, :update, :delete])
    ensure
      engine&.close if engine&.open?
    end
  end
end
