class SyncOkxConnectionJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform(okx_item_id)
    item = OkxItem.active.find_by(id: okx_item_id)
    item&.sync_later unless item&.syncing?
  rescue StandardError => e
    DebugLogEntry.capture(
      category: "provider_sync", level: "error", message: "Scheduled OKX sync could not be started",
      source: self.class.name, provider_key: "okx", family: item&.family,
      metadata: { okx_item_id: okx_item_id, error_class: e.class.name, error: e.message }
    )
    raise
  end
end
