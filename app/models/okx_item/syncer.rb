class OkxItem::Syncer
  include SyncStats::Collector

  def initialize(okx_item)
    @okx_item = okx_item
  end

  def perform_sync(sync)
    sync.update!(status_text: I18n.t("okx_item.syncer.checking_credentials")) if sync.respond_to?(:status_text)
    unless okx_item.credentials_configured?
      okx_item.update!(status: :requires_update)
      mark_failed(sync, I18n.t("okx_item.syncer.credentials_invalid"))
      return
    end

    sync.update!(status_text: I18n.t("okx_item.syncer.importing_accounts")) if sync.respond_to?(:status_text)
    okx_item.import_latest_okx_data
    okx_item.update!(status: :good) if okx_item.requires_update?

    collect_setup_stats(sync, provider_accounts: okx_item.okx_accounts.to_a)
    unlinked = okx_item.okx_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
    linked = okx_item.okx_accounts.joins(:account_provider).joins(:account).merge(Account.visible)
    okx_item.update!(pending_account_setup: unlinked.any?)
    sync.update!(status_text: I18n.t("okx_item.syncer.accounts_need_setup", count: unlinked.count)) if unlinked.any? && sync.respond_to?(:status_text)

    if linked.any?
      okx_item.process_accounts
      okx_item.schedule_account_syncs(parent_sync: sync, window_start_date: sync.window_start_date, window_end_date: sync.window_end_date)
      account_ids = linked.filter_map { |row| row.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "okx") if account_ids.any?
    end
  rescue StandardError => e
    okx_item.update!(status: :requires_update) if e.is_a?(Provider::Okx::AuthenticationError)
    mark_failed(sync, e.message)
    raise
  end

  def perform_post_sync; end

  private

    attr_reader :okx_item

    def mark_failed(sync, message)
      sync.start! if sync.respond_to?(:may_start?) && sync.may_start?
      sync.fail! if sync.respond_to?(:may_fail?) && sync.may_fail?
      sync.update!(error: message, status_text: message)
    end
end
