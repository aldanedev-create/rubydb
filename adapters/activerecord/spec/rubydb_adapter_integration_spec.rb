# frozen_string_literal: true

require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../../../lib", __dir__))
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "rubydb"
require "active_record"
require "active_record/connection_adapters/rubydb_adapter"

RSpec.describe ActiveRecord::ConnectionAdapters::RubyDBAdapter do
  let(:model) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "accounts"
    end
  end

  around do |example|
    Dir.mktmpdir("rubydb-active-record") do |directory|
      engine = RubyDB::Storage::Engine.new(File.join(directory, "accounts.rdb"), auto_cleanup: false, auto_vacuum: false)
      ActiveRecord::Base.establish_connection(adapter: "rubydb", engine: engine)
      example.run
    ensure
      ActiveRecord::Base.connection_pool.disconnect! if ActiveRecord::Base.connected?
      engine&.close
    end
  end

  it "creates and finds an ActiveRecord model through the embedded engine" do
    connection = ActiveRecord::Base.connection
    connection.execute("CREATE TABLE accounts (id INTEGER PRIMARY KEY, email VARCHAR(255) NOT NULL, active BOOLEAN NOT NULL)")

    created = model.create!(id: 1, email: "ada@example.test", active: true)
    loaded = model.find(created.id)

    expect(loaded.attributes).to include("id" => 1, "email" => "ada@example.test", "active" => true)
  end
end
