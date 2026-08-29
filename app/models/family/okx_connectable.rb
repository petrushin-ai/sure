module Family::OkxConnectable
  extend ActiveSupport::Concern

  included do
    has_many :okx_items, dependent: :destroy
  end

  def can_connect_okx?
    true
  end

  def has_okx_credentials?
    okx_items.active.any?(&:credentials_configured?)
  end
end
