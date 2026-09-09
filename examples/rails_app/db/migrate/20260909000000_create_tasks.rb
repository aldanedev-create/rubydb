# frozen_string_literal: true

class CreateTasks < ActiveRecord::Migration[7.2]
  def change
    create_table :tasks do |table|
      table.string :title, null: false
      table.boolean :completed, null: false, default: false
      table.timestamps
    end

    add_index :tasks, :completed
  end
end
