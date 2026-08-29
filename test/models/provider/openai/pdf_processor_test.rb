require "test_helper"

class Provider::Openai::PdfProcessorTest < ActiveSupport::TestCase
  setup do
    @pdf_content = "%PDF-1.4 fake bytes".b
  end

  test "extracts only allowlisted error fields into span output when the API call fails" do
    error = StandardError.new("boom")
    def error.response_body
      {
        "error" => { "type" => "invalid_request_error", "message" => "invalid request", "code" => "bad_pdf" },
        "request" => { "messages" => "statement text that should never leak" }
      }
    end
    def error.response_headers
      { "x-request-id" => "req_abc123" }
    end

    captured_output = nil
    trace = stub_trace { |output| captured_output = output }

    assert_raises(StandardError) do
      build_processor(error, trace).process
    end

    assert_equal(
      { type: "invalid_request_error", message: "invalid request", code: "bad_pdf", request_id: "req_abc123" },
      captured_output[:error_detail]
    )
  end

  test "error_detail is nil in span output when the error exposes no response_body" do
    error = StandardError.new("boom")

    captured_output = nil
    trace = stub_trace { |output| captured_output = output }

    assert_raises(StandardError) do
      build_processor(error, trace).process
    end

    assert_nil captured_output[:error_detail]
  end

  test "error_detail falls back to a placeholder when reading response_body itself raises" do
    error = StandardError.new("boom")
    def error.response_body
      raise "response_body accessor exploded"
    end

    captured_output = nil
    trace = stub_trace { |output| captured_output = output }

    assert_raises(StandardError) do
      build_processor(error, trace).process
    end

    assert_match(/detail unavailable/i, captured_output[:error_detail])
  end

  test "text mode exercises only text extraction" do
    expected = Provider::LlmConcept::PdfProcessingResult.new(
      summary: "Synthetic PDF",
      document_type: "other",
      extracted_data: {}
    )
    processor = Provider::Openai::PdfProcessor.new(
      mock,
      model: "gpt-4.1",
      pdf_content: @pdf_content,
      max_response_tokens: 512,
      processing_mode: :text
    )
    processor.expects(:process_with_text_extraction).returns(expected)
    processor.expects(:process_with_vision).never

    assert_equal expected, processor.process
  end

  test "vision mode exercises only vision processing" do
    expected = Provider::LlmConcept::PdfProcessingResult.new(
      summary: "Synthetic PDF",
      document_type: "other",
      extracted_data: {}
    )
    processor = Provider::Openai::PdfProcessor.new(
      mock,
      model: "gpt-4.1",
      pdf_content: @pdf_content,
      max_response_tokens: 512,
      processing_mode: :vision
    )
    processor.expects(:process_with_text_extraction).never
    processor.expects(:process_with_vision).returns(expected)

    assert_equal expected, processor.process
  end

  test "text mode uses Sure's strict schema with OpenAI" do
    client = mock("openai_client")
    client.expects(:chat).with do |request|
      parameters = request[:parameters]
      structured_output?(parameters[:response_format])
    end.returns(pdf_response)

    processor = Provider::Openai::PdfProcessor.new(
      client,
      model: "gpt-5.6-terra",
      pdf_content: @pdf_content,
      max_response_tokens: 512,
      processing_mode: :text
    )
    processor.stubs(:extract_text_from_pdf).returns("Synthetic document text")

    assert_equal "Synthetic PDF", processor.process.summary
  end

  test "vision mode uses Sure's strict schema, high image detail, and max_completion_tokens with OpenAI" do
    client = mock("openai_client")
    client.expects(:chat).with do |request|
      parameters = request[:parameters]
      image = parameters.dig(:messages, 1, :content, 0, :image_url)
      parameters[:max_completion_tokens] == 512 &&
        !parameters.key?(:max_tokens) &&
        image[:detail] == "high" &&
        structured_output?(parameters[:response_format])
    end.returns(pdf_response)

    processor = vision_processor(client)
    processor.stubs(:convert_pdf_to_images).returns([ "encoded-page" ])

    assert_equal "Synthetic PDF", processor.process.summary
  end

  test "vision mode keeps max_tokens for custom OpenAI-compatible providers" do
    client = mock("openai_client")
    client.expects(:chat).with do |request|
      parameters = request[:parameters]
      parameters[:max_tokens] == 512 &&
        !parameters.key?(:max_completion_tokens) &&
        !parameters.key?(:response_format)
    end.returns(pdf_response)

    processor = vision_processor(client, custom_provider: true)
    processor.stubs(:convert_pdf_to_images).returns([ "encoded-page" ])

    assert_equal "Synthetic PDF", processor.process.summary
  end

  test "official OpenAI rejects a response that does not match Sure's schema" do
    client = stub(chat: {
      "choices" => [
        { "message" => { "content" => { document_type: "other", summary: "Incomplete", extracted_data: {} }.to_json } }
      ]
    })
    processor = vision_processor(client)
    processor.stubs(:convert_pdf_to_images).returns([ "encoded-page" ])

    error = assert_raises(Provider::Openai::Error) { processor.process }
    assert_match(/Sure's schema/, error.message)
  end

  private
    def vision_processor(client, custom_provider: false)
      Provider::Openai::PdfProcessor.new(
        client,
        model: "gpt-5.6-terra",
        pdf_content: @pdf_content,
        custom_provider: custom_provider,
        max_response_tokens: 512,
        processing_mode: :vision
      )
    end

    def pdf_response
      {
        "choices" => [
          {
            "message" => {
              "content" => {
                document_type: "other",
                summary: "Synthetic PDF",
                extracted_data: empty_extracted_data
              }.to_json
            }
          }
        ]
      }
    end

    def empty_extracted_data
      Provider::LlmConcept::PDF_PROCESSING_EXTRACTED_DATA_KEYS.index_with(nil)
    end

    def structured_output?(format)
      format&.dig(:type) == "json_schema" &&
        format.dig(:json_schema, :name) == Provider::Openai::PdfProcessor::OUTPUT_SCHEMA_NAME &&
        format.dig(:json_schema, :strict) == true &&
        format.dig(:json_schema, :schema) == Provider::LlmConcept.pdf_processing_json_schema
    end

    def build_processor(error, trace)
      client = mock
      client.expects(:chat).raises(error)

      processor = Provider::Openai::PdfProcessor.new(
        client,
        model: "gpt-4.1",
        pdf_content: @pdf_content,
        langfuse_trace: trace,
        max_response_tokens: 1000
      )
      processor.stubs(:extract_text_from_pdf).returns("Statement text")
      processor
    end

    def stub_trace
      span = mock
      span.expects(:end).with { |args| yield(args[:output]); true }
      trace = mock
      trace.stubs(:span).returns(span)
      trace
    end
end
