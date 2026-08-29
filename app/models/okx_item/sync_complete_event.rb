class OkxItem::SyncCompleteEvent
  def initialize(okx_item)
    @okx_item = okx_item
  end

  def broadcast
    @okx_item.accounts.each(&:broadcast_sync_complete)
    @okx_item.family.broadcast_sync_complete
  end
end
