# frozen_string_literal: true

class OkxItemsController < ApplicationController
  before_action :set_okx_item, only: %i[update destroy sync setup_accounts complete_account_setup]
  before_action :require_admin!

  def create
    @okx_item = Current.family.okx_items.build(okx_item_params)
    @okx_item.name = t(".default_name") if @okx_item.name.blank?

    if @okx_item.save
      @okx_item.set_okx_institution_defaults!
      @okx_item.sync_later
      render_panel(notice: t(".success"))
    else
      render_panel(error: @okx_item.errors.full_messages.join(", "), status: :unprocessable_entity)
    end
  end

  def update
    if @okx_item.update(okx_item_params)
      render_panel(notice: t(".success"))
    else
      render_panel(error: @okx_item.errors.full_messages.join(", "), status: :unprocessable_entity)
    end
  end

  def destroy
    @okx_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success")
  end

  def sync
    @okx_item.sync_later unless @okx_item.syncing?
    redirect_back_or_to settings_providers_path
  end

  def setup_accounts
    @okx_accounts = @okx_item.okx_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).order(:name)
  end

  def complete_account_setup
    setup_params = complete_account_setup_params

    if setup_params[:sync_start_date].present?
      date = begin
        Date.parse(setup_params[:sync_start_date].to_s)
      rescue ArgumentError
        nil
      end
      @okx_item.update!(sync_start_date: date) if date && date <= Date.current
    end

    created = []
    Array(setup_params[:selected_accounts]).reject(&:blank?).each do |id|
      provider_account = @okx_item.okx_accounts.find_by(id: id)
      next unless provider_account

      begin
        provider_account.with_lock do
          next if provider_account.account

          requested_name = setup_params[:account_names]&.[](provider_account.id.to_s).to_s.strip
          provider_account.update!(name: requested_name) if requested_name.present? && requested_name != provider_account.name
          account = Account.create_from_okx_account(provider_account)
          provider_link = provider_account.ensure_account_provider!(account)

          if provider_link
            created << account
          else
            account.destroy!
          end
        end
      rescue StandardError => e
        Rails.logger.error("Failed to setup OkxAccount #{id}: #{e.message}")
        next
      end

      provider_account.reload
      OkxAccount::HoldingsProcessor.new(provider_account).process
    end

    @okx_item.update!(pending_account_setup: @okx_item.okx_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).exists?)
    @okx_item.sync_later if created.any?
    redirect_to accounts_path, notice: t(".success", count: created.size), status: :see_other
  end

  private

    def set_okx_item
      @okx_item = Current.family.okx_items.find(params[:id])
    end

    def okx_item_params
      permitted = params.require(:okx_item).permit(:name, :sync_start_date, :api_key, :api_secret, :passphrase)
      if @okx_item&.persisted?
        %i[api_key api_secret passphrase].each { |field| permitted.delete(field) if permitted[field].blank? }
      end
      permitted
    end

    def complete_account_setup_params
      params.permit(:sync_start_date, selected_accounts: [], account_names: {})
    end

    def render_panel(notice: nil, error: nil, status: :ok)
      unless turbo_frame_request?
        return redirect_to settings_providers_path, notice: notice, alert: error, status: :see_other
      end

      flash.now[:notice] = notice if notice
      @okx_items = Current.family.okx_items.active.ordered
      streams = [ turbo_stream.replace("okx-providers-panel", partial: "settings/providers/okx_panel", locals: { okx_items: @okx_items, error_message: error }) ]
      streams.concat(flash_notification_stream_items)
      render turbo_stream: streams, status: status
    end
end
