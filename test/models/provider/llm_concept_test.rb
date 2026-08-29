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
end
