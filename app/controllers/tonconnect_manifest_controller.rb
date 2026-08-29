# frozen_string_literal: true

# Public dApp metadata fetched by TON wallets before they approve a TonConnect
# session. It is host-derived so every HTTPS Sure deployment advertises itself,
# rather than a hard-coded downstream domain.
class TonconnectManifestController < ApplicationController
  skip_authentication
  skip_before_action :require_onboarding_and_upgrade, raise: false
  skip_before_action :set_default_chat, raise: false
  skip_before_action :detect_os, raise: false

  after_action :allow_wallet_fetch

  def show
    base_url = request.base_url

    render json: {
      url: base_url,
      name: Rails.configuration.x.product_name,
      iconUrl: "#{base_url}/apple-touch-icon.png"
    }
  end

  private
    def allow_wallet_fetch
      response.set_header("Access-Control-Allow-Origin", "*")
      response.set_header("Cache-Control", "public, max-age=3600")
    end
end
