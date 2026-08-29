class OkxItem::SyncCompleteEvent
  def initialize(okx_item)
    @okx_item = okx_item
  end

  def broadcast
    @okx_item.accounts.each(&:broadcast_sync_complete)
    @okx_item.broadcast_replace_to(
      @okx_item.family,
      target: "okx_item_#{@okx_item.id}",
      partial: "okx_items/okx_item",
      locals: { okx_item: @okx_item }
    )
    @okx_item.family.broadcast_sync_complete
  end
end
