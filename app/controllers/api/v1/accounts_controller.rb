# frozen_string_literal: true

class Api::V1::AccountsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: :credit_card_snapshot

  def index
    @per_page = safe_per_page_param

    @pagy, @accounts = pagy(
      accounts_scope.alphabetically,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue => e
    Rails.logger.error "AccountsController#index error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def show
    unless valid_uuid?(params[:id])
      render json: {
        error: "not_found",
        message: "Account not found"
      }, status: :not_found
      return
    end

    @account = accounts_scope.find(params[:id])

    render :show
  rescue ActiveRecord::RecordNotFound
    render json: {
      error: "not_found",
      message: "Account not found"
    }, status: :not_found
  rescue => e
    Rails.logger.error "AccountsController#show error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def credit_card_snapshot
    unless valid_uuid?(params[:id])
      render_not_found
      return
    end

    @account = current_resource_owner.family.accounts
                                     .writable_by(current_resource_owner)
                                     .visible
                                     .find(params[:id])
    unless @account.credit_card? && @account.currency == "RUB"
      render_validation_error("Account is not a RUB credit card")
      return
    end

    snapshot = normalized_credit_card_snapshot
    return if performed?

    unless @account.balance.round(2) == snapshot.fetch(:total_debt).round(2)
      render_validation_error("Credit card balance does not match total debt")
      return
    end

    Account.transaction do
      @account.credit_card.update!(
        available_credit: snapshot.fetch(:available_credit),
        minimum_payment: snapshot.fetch(:minimum_payment)
      )
      @account.update!(notes: merged_credit_card_snapshot_notes(snapshot))
    end

    @account.reload
    render :show
  rescue ActiveRecord::RecordNotFound
    render_not_found
  rescue ActionController::ParameterMissing => e
    render_validation_error(e.message)
  rescue ArgumentError
    render_validation_error("Credit card snapshot is invalid")
  rescue ActiveRecord::RecordInvalid => e
    render_validation_error(e.record.errors.full_messages.join(", "))
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def normalized_credit_card_snapshot
      raw = params.require(:credit_card_snapshot).permit(
        :provider,
        :snapshot_date,
        :credit_limit,
        :total_debt,
        :available_credit,
        :minimum_payment,
        :grace_period_payment,
        :payment_due_date,
        :current_month_spending,
        :reward_miles,
        :source_reference,
        card_last4s: []
      )
      raise ArgumentError unless raw[:provider] == "tbank"

      snapshot_date = Date.iso8601(raw.fetch(:snapshot_date))
      payment_due_date = Date.iso8601(raw.fetch(:payment_due_date))
      raise ArgumentError if payment_due_date < snapshot_date

      monetary = {
        credit_limit: nonnegative_decimal(raw, :credit_limit),
        total_debt: nonnegative_decimal(raw, :total_debt),
        available_credit: nonnegative_decimal(raw, :available_credit),
        minimum_payment: nonnegative_decimal(raw, :minimum_payment),
        grace_period_payment: nonnegative_decimal(raw, :grace_period_payment),
        current_month_spending: nonnegative_decimal(raw, :current_month_spending)
      }
      credit_limit = monetary.fetch(:credit_limit)
      raise ArgumentError if monetary.values_at(
        :total_debt,
        :available_credit,
        :minimum_payment,
        :grace_period_payment
      ).any? { |value| value > credit_limit }

      card_last4s = Array(raw[:card_last4s]).map(&:to_s).uniq.sort
      raise ArgumentError unless card_last4s.size.between?(1, 10)
      raise ArgumentError unless card_last4s.all? { |value| value.match?(/\A\d{4}\z/) }

      reward_miles = Integer(raw.fetch(:reward_miles).to_s, 10)
      raise ArgumentError if reward_miles.negative?
      source_reference = raw.fetch(:source_reference).to_s
      raise ArgumentError unless source_reference.match?(/\A[a-f0-9]{16,64}\z/)

      {
        provider: "tbank",
        snapshot_date: snapshot_date,
        payment_due_date: payment_due_date,
        card_last4s: card_last4s,
        reward_miles: reward_miles,
        source_reference: source_reference,
        **monetary
      }
    end

    def nonnegative_decimal(raw, key)
      value = BigDecimal(raw.fetch(key).to_s)
      raise ArgumentError if value.negative? || value > BigDecimal("999999999999.99")

      value
    end

    def merged_credit_card_snapshot_notes(snapshot)
      start_marker = "[family-connectors:tbank-credit-snapshot]"
      end_marker = "[/family-connectors:tbank-credit-snapshot]"
      existing = @account.notes.to_s.gsub(
        /#{Regexp.escape(start_marker)}.*?#{Regexp.escape(end_marker)}/m,
        ""
      ).strip
      managed = [
        start_marker,
        "Snapshot date: #{snapshot.fetch(:snapshot_date).iso8601}",
        "Credit limit: #{decimal_string(snapshot.fetch(:credit_limit))} RUB",
        "Total debt: #{decimal_string(snapshot.fetch(:total_debt))} RUB",
        "Available credit: #{decimal_string(snapshot.fetch(:available_credit))} RUB",
        "Minimum payment: #{decimal_string(snapshot.fetch(:minimum_payment))} RUB",
        "Grace-period payment: #{decimal_string(snapshot.fetch(:grace_period_payment))} RUB",
        "Payment due date: #{snapshot.fetch(:payment_due_date).iso8601}",
        "Cards: #{snapshot.fetch(:card_last4s).map { |value| "·#{value}" }.join(", ")}",
        "Current-month spending: #{decimal_string(snapshot.fetch(:current_month_spending))} RUB",
        "Reward miles: #{snapshot.fetch(:reward_miles)}",
        "Source reference: #{snapshot.fetch(:source_reference)}",
        end_marker
      ].join("\n")

      [ existing.presence, managed ].compact.join("\n\n")
    end

    def decimal_string(value)
      value.to_s("F")
    end

    def render_not_found
      render json: { error: "not_found", message: "Account not found" }, status: :not_found
    end

    def render_validation_error(message)
      render json: {
        error: "validation_failed",
        message: message,
        errors: [ message ]
      }, status: :unprocessable_entity
    end

    def accounts_scope
      scope = current_resource_owner.family.accounts
                                    .accessible_by(current_resource_owner)
                                    .includes(:accountable, account_providers: :provider)
      include_disabled_accounts? ? scope : scope.visible
    end

    def include_disabled_accounts?
      ActiveModel::Type::Boolean.new.cast(params[:include_disabled])
    end
end
