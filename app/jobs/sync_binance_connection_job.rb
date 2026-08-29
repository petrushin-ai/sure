class SyncBinanceConnectionJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform(binance_item_id)
    item = BinanceItem.active.find_by(id: binance_item_id)
    return unless item
    return if item.syncing?

    item.sync_later
  rescue => e
    DebugLogEntry.capture(
      category: "provider_sync",
      level: "error",
      message: "Scheduled Binance connection sync could not be started",
      source: self.class.name,
      provider_key: "binance",
      family: item&.family,
      metadata: { binance_item_id: binance_item_id, error_class: e.class.name, error: e.message }
    )
    raise
  end
end
