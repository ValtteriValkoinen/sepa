require 'test_helper'

class NordeaRenewCertApplicationRequestTest < ActiveSupport::TestCase
  setup do
    params = nordea_renew_certificate_params

    # Convert the keys here since the conversion is usually done by the client and these tests
    # bypass the client
    params[:own_signing_certificate] = x509_certificate(params[:own_signing_certificate])
    params[:signing_private_key]     = rsa_key(params[:signing_private_key])

    application_request = Sepa::SoapBuilder.new(params).application_request
    @doc                = Nokogiri::XML(application_request.to_xml)
  end

  test "validates against schema" do
    errors = []

    Dir.chdir(SCHEMA_PATH) do
      xsd = Nokogiri::XML::Schema(IO.read('cert_application_request.xsd'))
      xsd.validate(@doc).each do |error|
        errors << error
      end
    end

    assert errors.empty?, "The following schema validations failed:\n#{errors.join("\n")}"
  end
end
