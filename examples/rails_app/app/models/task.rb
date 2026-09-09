# frozen_string_literal: true

class Task < ActiveRecord::Base
  validates :title, presence: true

  scope :open, -> { where(completed: false) }
end
