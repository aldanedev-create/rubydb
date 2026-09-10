# frozen_string_literal: true

require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../../../lib", __dir__))
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "rubydb"
require "active_record"
require "active_record/connection_adapters/rubydb_adapter"

RSpec.describe ActiveRecord::ConnectionAdapters::RubyDBAdapter do
  def migration_version
    "#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}"
  end

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

  it "preserves false and zero values in ActiveRecord results" do
    connection = ActiveRecord::Base.connection
    connection.execute("CREATE TABLE flags (id INTEGER PRIMARY KEY, enabled BOOLEAN NOT NULL, attempts INTEGER NOT NULL)")
    connection.execute("INSERT INTO flags (id, enabled, attempts) VALUES (1, FALSE, 0)")

    result = connection.exec_query("SELECT enabled, attempts FROM flags WHERE id = 1")

    expect(result.first).to include("enabled" => false, "attempts" => 0)
  end

  it "runs a Rails migration that creates a table, adds a column, and adds an index" do
    migration = Class.new(ActiveRecord::Migration[migration_version]) do
      def change
        create_table :projects do |table|
          table.string :name, null: false
        end
        add_column :projects, :active, :boolean, default: true, null: false
        add_index :projects, :name, unique: true
      end
    end

    migration.new.migrate(:up)
    connection = ActiveRecord::Base.connection

    expect(connection.table_exists?(:projects)).to be(true)
    expect(connection.columns(:projects).map(&:name)).to include("id", "name", "active")
    expect(connection.indexes(:projects)).to include(an_object_having_attributes(name: "idx_projects_name", unique: true))
    schema = connection.dump_schema
    expect(schema).to include('t.boolean "active", default: true, null: false')
    expect(schema).to include('add_index "projects", ["name"], unique: true')
    expect(schema).not_to include('t.integer "id"')

    migration.new.migrate(:down)
    expect(connection.table_exists?(:projects)).to be(false)
  end

  it "executes an ActiveRecord association join with qualified filtering" do
    stub_const("RubydbAccount", Class.new(ActiveRecord::Base) do
      self.table_name = "accounts"
      has_many :rubydb_projects, class_name: "RubydbProject", foreign_key: :account_id
    end)
    stub_const("RubydbProject", Class.new(ActiveRecord::Base) do
      self.table_name = "projects"
      belongs_to :rubydb_account, class_name: "RubydbAccount", foreign_key: :account_id
    end)

    connection = ActiveRecord::Base.connection
    connection.execute("CREATE TABLE accounts (id INTEGER PRIMARY KEY, email VARCHAR(255) NOT NULL)")
    connection.execute("CREATE TABLE projects (id INTEGER PRIMARY KEY, account_id INTEGER NOT NULL, name VARCHAR(255) NOT NULL)")
    account = RubydbAccount.create!(id: 1, email: "ada@example.test")
    RubydbProject.create!(id: 10, account_id: account.id, name: "RubyDB")

    projects = RubydbProject.joins(:rubydb_account).where(accounts: { email: "ada@example.test" }).to_a

    expect(projects.map(&:attributes)).to include(hash_including("id" => 10, "name" => "RubyDB", "account_id" => 1))
  end

  it "loads nested associations and ordered join results from populated tables" do
    stub_const("RubydbAuthor", Class.new(ActiveRecord::Base) do
      self.table_name = "authors"
      has_many :rubydb_books, class_name: "RubydbBook", foreign_key: :author_id
    end)
    stub_const("RubydbBook", Class.new(ActiveRecord::Base) do
      self.table_name = "books"
      belongs_to :rubydb_author, class_name: "RubydbAuthor", foreign_key: :author_id
      has_many :rubydb_reviews, class_name: "RubydbReview", foreign_key: :book_id
    end)
    stub_const("RubydbReview", Class.new(ActiveRecord::Base) do
      self.table_name = "reviews"
      belongs_to :rubydb_book, class_name: "RubydbBook", foreign_key: :book_id
    end)

    connection = ActiveRecord::Base.connection
    connection.execute("CREATE TABLE authors (id INTEGER PRIMARY KEY, email VARCHAR(255) NOT NULL)")
    connection.execute("CREATE TABLE books (id INTEGER PRIMARY KEY, author_id INTEGER NOT NULL, title VARCHAR(255) NOT NULL)")
    connection.execute("CREATE TABLE reviews (id INTEGER PRIMARY KEY, book_id INTEGER NOT NULL, rating INTEGER NOT NULL)")
    author = RubydbAuthor.create!(id: 1, email: "ada@example.test")
    other = RubydbAuthor.create!(id: 2, email: "other@example.test")
    first = RubydbBook.create!(id: 10, author_id: author.id, title: "A")
    second = RubydbBook.create!(id: 11, author_id: author.id, title: "B")
    RubydbBook.create!(id: 12, author_id: other.id, title: "C")
    RubydbReview.create!(id: 20, book_id: first.id, rating: 5)
    RubydbReview.create!(id: 21, book_id: second.id, rating: 4)

    loaded = RubydbAuthor.includes(rubydb_books: :rubydb_reviews)
                          .where(email: "ada@example.test").to_a
    joined_titles = RubydbBook.joins(:rubydb_author)
                              .where(rubydb_authors: { email: "ada@example.test" })
                              .order(title: :desc).pluck(:title)

    expect(loaded.first.rubydb_books.map(&:title)).to contain_exactly("A", "B")
    expect(loaded.first.rubydb_books.flat_map { |book| book.rubydb_reviews.map(&:rating) })
      .to contain_exactly(5, 4)
    expect(joined_titles).to eq(["B", "A"])
  end

  it "round-trips a migration on a populated table" do
    connection = ActiveRecord::Base.connection
    connection.execute("CREATE TABLE accounts (id INTEGER PRIMARY KEY, email VARCHAR(255) NOT NULL)")
    connection.execute("INSERT INTO accounts (id, email) VALUES (1, 'ada@example.test')")

    migration = Class.new(ActiveRecord::Migration[migration_version]) do
      def change
        add_column :accounts, :status, :string, default: "new", null: false
        add_index :accounts, :status
      end
    end

    migration.new.migrate(:up)
    loaded = connection.select_one("SELECT status FROM accounts WHERE id = 1")

    expect(loaded["status"] || loaded[:status]).to eq("new")
    expect(connection.indexes(:accounts)).to include(an_object_having_attributes(columns: ["status"]))

    migration.new.migrate(:down)
    expect(connection.columns(:accounts).map(&:name)).not_to include("status")
  end
end
