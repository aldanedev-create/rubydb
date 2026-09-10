class Repository < ActiveRecord::Base
  has_many :issues, dependent: :destroy
  has_many :commits, dependent: :destroy

  validates :name, presence: true, uniqueness: true
end
