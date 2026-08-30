# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Accounts', type: :request do
  let(:family) do
    Family.create!(
      name: 'API Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:user) do
    family.users.create!(
      email: 'api-user@example.com',
      password: 'password123',
      password_confirmation: 'password123'
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'API Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'web'
    )
  end

  let(:api_key_without_read_scope) do
    key = ApiKey.generate_secure_key
    # Valid persisted API keys can only be read/read_write; this intentionally
    # bypasses validations to document the runtime insufficient-scope response.
    ApiKey.new(
      user: user,
      name: 'No Read Docs Key',
      key: key,
      scopes: %w[write],
      source: 'web'
    ).tap { |api_key| api_key.save!(validate: false) }
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let!(:checking_account) do
    Account.create!(
      family: family,
      name: 'Checking Account',
      balance: 1500.50,
      currency: 'USD',
      accountable: Depository.create!
    )
  end

  let!(:savings_account) do
    Account.create!(
      family: family,
      name: 'Savings Account',
      balance: 10000.00,
      currency: 'USD',
      accountable: Depository.create!
    )
  end

  let!(:credit_card) do
    Account.create!(
      family: family,
      name: 'Credit Card',
      balance: -500.00,
      currency: 'USD',
      accountable: CreditCard.create!
    )
  end

  path '/api/v1/accounts' do
    get 'List accounts' do
      tags 'Accounts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :include_disabled, in: :query, type: :boolean, required: false,
                description: 'Include disabled accounts in the response. Defaults to false.'

      response '200', 'accounts listed' do
        schema '$ref' => '#/components/schemas/AccountCollection'

        run_test!
      end

      response '200', 'accounts paginated' do
        schema '$ref' => '#/components/schemas/AccountCollection'

        let(:page) { 1 }
        let(:per_page) { 2 }

        run_test!
      end
    end
  end

  path '/api/v1/accounts/{id}' do
    parameter name: :id, in: :path, required: true, description: 'Account ID',
              schema: { type: :string, format: :uuid }

    get 'Retrieve an account' do
      tags 'Accounts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :include_disabled, in: :query, type: :boolean, required: false,
                description: 'Allow retrieving a disabled account. Defaults to false.'

      let(:id) { checking_account.id }

      response '200', 'account retrieved' do
        schema '$ref' => '#/components/schemas/AccountDetail'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { checking_account.id }
        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { checking_account.id }
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '404', 'account not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/accounts/{id}/credit_card_snapshot' do
    parameter name: :id, in: :path, required: true, description: 'Credit-card account ID',
              schema: { type: :string, format: :uuid }

    patch 'Update a reviewed T-Bank credit-card snapshot' do
      tags 'Accounts'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :credit_card_snapshot, in: :body, required: true, schema: {
        type: :object,
        required: %w[credit_card_snapshot],
        properties: {
          credit_card_snapshot: {
            type: :object,
            required: %w[provider snapshot_date credit_limit total_debt available_credit minimum_payment grace_period_payment payment_due_date card_last4s current_month_spending reward_miles source_reference],
            properties: {
              provider: { type: :string, enum: %w[tbank] },
              snapshot_date: { type: :string, format: :date },
              credit_limit: { type: :string },
              total_debt: { type: :string },
              available_credit: { type: :string },
              minimum_payment: { type: :string },
              grace_period_payment: { type: :string },
              payment_due_date: { type: :string, format: :date },
              card_last4s: {
                type: :array,
                minItems: 1,
                maxItems: 10,
                items: { type: :string, pattern: '^\\d{4}$' }
              },
              current_month_spending: { type: :string },
              reward_miles: { type: :integer, minimum: 0 },
              source_reference: { type: :string, pattern: '^[a-f0-9]{16,64}$' }
            }
          }
        }
      }

      let(:id) { tbank_credit_card.id }
      let(:tbank_credit_card) do
        Account.create!(
          family: family,
          owner: user,
          name: 'T-Bank Credit Card',
          balance: 120_569,
          currency: 'RUB',
          accountable: CreditCard.create!
        )
      end
      let(:credit_card_snapshot) do
        {
          credit_card_snapshot: {
            provider: 'tbank',
            snapshot_date: '2026-08-31',
            credit_limit: '640000',
            total_debt: '120569',
            available_credit: '519667.35',
            minimum_payment: '7000',
            grace_period_payment: '120332.65',
            payment_due_date: '2026-09-22',
            card_last4s: %w[3154 9146],
            current_month_spending: '24265',
            reward_miles: 9780,
            source_reference: 'aaaaaaaaaaaaaaaa'
          }
        }
      end

      response '200', 'credit-card snapshot updated' do
        schema '$ref' => '#/components/schemas/AccountDetail'
        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { nil }
        run_test!
      end

      response '422', 'snapshot rejected' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:id) { checking_account.id }
        run_test!
      end
    end
  end
end
