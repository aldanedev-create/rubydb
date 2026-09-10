class CreateGithubCloneTables < ActiveRecord::Migration[7.2]
  def change
    create_table :repositories do |table|
      table.string :name, null: false
      table.text :description
      table.timestamps
    end
    add_index :repositories, :name, unique: true

    create_table :issues do |table|
      table.references :repository, null: false, foreign_key: true
      table.string :title, null: false
      table.text :body
      table.timestamps
    end
    add_index :issues, %i[repository_id created_at]

    create_table :commits do |table|
      table.references :repository, null: false, foreign_key: true
      table.string :sha, null: false
      table.string :message, null: false
      table.string :author, null: false
      table.timestamps
    end
    add_index :commits, :sha, unique: true
    add_index :commits, %i[repository_id created_at]
  end
end
