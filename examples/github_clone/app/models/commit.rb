class Commit < ActiveRecord::Base
  belongs_to :repository

  validates :sha, :message, :author, presence: true
end
