# frozen_string_literal: true

class OkxItem < ApplicationRecord
  include Syncable, OkxItem::Provided, OkxItem::Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :api_key, deterministic: true
    encrypts :api_secret
    encrypts :passphrase
    encrypts :raw_payload
  end

  belongs_to :family
  has_many :okx_accounts, dependent: :destroy
  has_many :accounts, through: :okx_accounts

  validates :name, :api_key, :api_secret, :passphrase, presence: true
  validate :api_key_unique_within_family

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }

  before_validation :strip_connection_fields

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_okx_data
    raise "OKX credentials not configured" unless okx_provider

    OkxItem::Importer.new(self, provider: okx_provider).import
  rescue StandardError => e
    DebugLogEntry.capture(
      category: "provider_sync", level: "error", message: "OKX import failed",
      source: self.class.name, provider_key: "okx", family: family,
      metadata: { okx_item_id: id, error_class: e.class.name, error: e.message }
    )
    raise
  end

  def process_accounts
    okx_accounts.joins(:account).merge(Account.visible).map do |provider_account|
      OkxAccount::Processor.new(provider_account).process
    end
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.visible.map do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
    end
  end

  def upsert_okx_snapshot!(payload)
    update!(raw_payload: payload)
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def credentials_configured?
    api_key.present? && api_secret.present? && passphrase.present?
  end

  def linked_accounts_count
    okx_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    okx_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    okx_accounts.count
  end

  def institution_display_name
    name.presence || institution_name.presence || institution_domain
  end

  def sync_status_summary
    return I18n.t("okx_items.okx_item.sync_status.no_accounts") if total_accounts_count.zero?
    return I18n.t("okx_items.okx_item.sync_status.all_synced", count: linked_accounts_count) if unlinked_accounts_count.zero?

    I18n.t("okx_items.okx_item.sync_status.partial_sync", linked_count: linked_accounts_count, unlinked_count: unlinked_accounts_count)
  end

  def set_okx_institution_defaults!
    update!(
      institution_name: "OKX",
      institution_domain: "okx.com",
      institution_url: "https://www.okx.com",
      institution_color: "#000000"
    )
  end

  private

    def strip_connection_fields
      %i[name api_key api_secret passphrase].each do |field|
        public_send("#{field}=", public_send(field).to_s.strip) if public_send("#{field}_changed?") && !public_send(field).nil?
      end
    end

    def api_key_unique_within_family
      return if family_id.blank? || api_key.blank?

      duplicate = self.class.active.where(family_id: family_id, api_key: api_key).where.not(id: id).exists?
      errors.add(:api_key, :taken) if duplicate
    end
end
