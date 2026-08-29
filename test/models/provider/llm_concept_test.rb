require "test_helper"

class Provider::LlmConceptTest < ActiveSupport::TestCase
  test "PDF processing schema requires the exact Sure result shape" do
    schema = Provider::LlmConcept.pdf_processing_json_schema
    extracted_data = schema.dig(:properties, :extracted_data)

    assert_equal %w[document_type summary extracted_data], schema[:required]
    assert_equal false, schema[:additionalProperties]
    assert_equal Provider::LlmConcept::PDF_PROCESSING_EXTRACTED_DATA_KEYS, extracted_data[:required]
    assert_equal false, extracted_data[:additionalProperties]
  end

  test "validates a complete PDF processing result" do
    assert Provider::LlmConcept.valid_pdf_processing_result?(pdf_result)
  end

  test "rejects missing, additional, or incorrectly typed PDF fields" do
    missing = valid_extracted_data.except("currency")
    additional = valid_extracted_data.merge("unexpected" => true)
    invalid_date = valid_extracted_data.merge("statement_period_start" => "03/01/2026")
    invalid_count = valid_extracted_data.merge("transaction_count" => -1)
    invalid_balance = valid_extracted_data.merge("closing_balance" => "1500.00")

    [ missing, additional, invalid_date, invalid_count, invalid_balance ].each do |data|
      assert_not Provider::LlmConcept.valid_pdf_processing_result?(pdf_result(extracted_data: data))
    end
  end

  test "bank statement schema requires the exact Sure extraction shape" do
    schema = Provider::LlmConcept.bank_statement_json_schema
    period = schema.dig(:properties, :statement_period)
    transaction = schema.dig(:properties, :transactions, :items)

    assert_equal Provider::LlmConcept::BANK_STATEMENT_KEYS, schema[:required]
    assert_equal false, schema[:additionalProperties]
    assert_equal Provider::LlmConcept::BANK_STATEMENT_PERIOD_KEYS, period[:required]
    assert_equal false, period[:additionalProperties]
    assert_equal Provider::LlmConcept::BANK_STATEMENT_TRANSACTION_KEYS, transaction[:required]
    assert_equal false, transaction[:additionalProperties]
  end

  test "validates a complete bank statement extraction payload" do
    assert Provider::LlmConcept.valid_bank_statement_extraction_payload?(valid_bank_statement_payload)
  end

  test "rejects incomplete or incorrectly typed bank statement extraction payloads" do
    payloads = [
      valid_bank_statement_payload.except("bank_name"),
      valid_bank_statement_payload.merge("unexpected" => true),
      valid_bank_statement_payload.merge("statement_period" => { "start_date" => "03/01/2026", "end_date" => nil }),
      valid_bank_statement_payload.merge("opening_balance" => "1000.00"),
      valid_bank_statement_payload.merge("transactions" => [ valid_transaction.except("reference") ]),
      valid_bank_statement_payload.merge("transactions" => [ valid_transaction.merge("date" => "03/05/2026") ]),
      valid_bank_statement_payload.merge("transactions" => [ valid_transaction.merge("amount" => "-4.50") ])
    ]

    payloads.each do |payload|
      assert_not Provider::LlmConcept.valid_bank_statement_extraction_payload?(payload)
    end
  end

  private
    def pdf_result(extracted_data: valid_extracted_data)
      Provider::LlmConcept::PdfProcessingResult.new(
        document_type: "bank_statement",
        summary: "Bank of Example statement.",
        extracted_data: extracted_data
      )
    end

    def valid_extracted_data
      {
        "institution_name" => "Bank of Example",
        "statement_period_start" => "2026-03-01",
        "statement_period_end" => "2026-03-31",
        "transaction_count" => 42,
        "opening_balance" => 1000.0,
        "closing_balance" => 1500.0,
        "currency" => "USD",
        "account_holder" => "Account Holder"
      }
    end

    def valid_bank_statement_payload
      {
        "bank_name" => "Bank of Example",
        "account_holder" => "Account Holder",
        "account_number" => "1234",
        "statement_period" => { "start_date" => "2026-03-01", "end_date" => "2026-03-31" },
        "opening_balance" => 1000.0,
        "closing_balance" => 1500.0,
        "transactions" => [ valid_transaction ]
      }
    end

    def valid_transaction
      {
        "date" => "2026-03-05",
        "description" => "Coffee",
        "amount" => -4.5,
        "reference" => nil,
        "category" => nil
      }
    end
end
