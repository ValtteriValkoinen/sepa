module Sepa
  class Response
    include ActiveModel::Validations
    include Utilities
    include ErrorMessages

    attr_reader :soap, :error, :command

    validate  :document_must_validate_against_schema
    validate  :client_errors
    validate  :validate_response_code
    validate  :validate_hashes
    validate  :verify_signature
    validate  :verify_certificate

    def initialize(hash = {})
      @soap = hash[:response]
      @command = hash[:command]
      @error = hash[:error]
      @encryption_private_key = hash[:encryption_private_key]
    end

    def doc
      @doc ||= xml_doc @soap
    end

    # Verifies that all digest values in the response match the actual ones.
    # Takes an optional verbose parameter to show which digests didn't match
    # i.e. verbose: true
    def hashes_match?(options = {})
      digests = find_digest_values

      return false if digests.empty?

      nodes = find_nodes_to_verify(digests)

      verified_digests = digests.select do |uri, digest|
        uri = uri.sub(/^#/, '')
        digest == nodes[uri]
      end

      return true if digests == verified_digests

      unverified_digests = digests.select do |uri, digest|
        uri = uri.sub(/^#/, '')
        digest != nodes[uri]
      end

      if options[:verbose]
        puts "These digests failed to verify: #{unverified_digests}"
      end

      false
    end

    # Verifies the signature by extracting the public key from the certificate
    # embedded in the soap header and verifying the signature value with that.
    def signature_is_valid?
      validate_signature(doc, certificate, :exclusive)
    end

    # Gets the application response from the response as an xml document
    def application_response
      @application_response ||= extract_application_response(BXD)
    end

    def file_references
      return unless @command == :download_file_list

      @file_references ||= begin
        xml = xml_doc content
        descriptors = xml.css('FileDescriptor')
        descriptors.map { |descriptor| descriptor.at('FileReference').content }
      end
    end

    def certificate
      @certificate ||= begin
        extract_cert(doc, 'BinarySecurityToken', OASIS_SECEXT)
      end
    end

    def content
      @content ||= begin
        xml = xml_doc(application_response)

        case @command
        when :download_file
          content_node = xml.at('xmlns|Content', xmlns: XML_DATA)
          content_node.content if content_node
        when :download_file_list
          content_node = xml.remove_namespaces!.at('FileDescriptors')
          content_node.to_xml if content_node
        when :get_user_info
          canonicalized_node(xml, XML_DATA, 'UserFileTypes')
        when :upload_file
          signature_node = xml.at('xmlns|Signature', xmlns: DSIG)
          if signature_node
            signature_node.remove
            xml.canonicalize
          end
        end
      end
    end

    def to_s
      @soap
    end

    def bank_encryption_certificate; end

    def bank_signing_certificate; end

    def bank_root_certificate; end

    def own_encryption_certificate; end

    def own_signing_certificate; end

    def ca_certificate; end

    def response_code
      node = doc.at('xmlns|ResponseCode', xmlns: BXD)
      node.content if node
    end

    private

      # Finds all reference nodes with digest values in the document and returns
      # a hash with uri as the key and digest as the value.
      def find_digest_values
        references = {}
        reference_nodes = doc.css('xmlns|Reference', xmlns: DSIG)

        reference_nodes.each do |node|
          uri = node.attr('URI')
          digest_value = node.at('xmlns|DigestValue', xmlns: DSIG).content

          references[uri] = digest_value
        end

        references
      end

      # Finds nodes to verify by comparing their id's to the uris' in the
      # references hash.
      def find_nodes_to_verify(references)
        nodes = {}

        references.each do |uri, _digest_value|
          uri = uri.sub(/^#/, '')
          node = find_node_by_uri(uri)

          nodes[uri] = calculate_digest(node)
        end

        nodes
      end

      def document_must_validate_against_schema
        return if @error || command.to_sym == :get_bank_certificate

        check_validity_against_schema(doc, 'soap.xsd')
      end

      def extract_application_response(namespace)
        ar_node = doc.at('xmlns|ApplicationResponse', xmlns: namespace)
        if ar_node
          decode(ar_node.content)
        end
      end

      def client_errors
        client_error = error.to_s
        errors.add(:base, client_error) unless client_error.empty?
      end

      def find_node_by_uri(uri)
        doc.at("[xmlns|Id='#{uri}']", xmlns: OASIS_UTILITY)
      end

      def validate_response_code
        return if @error

        unless %w(00 24).include? response_code
          errors.add(:base, NOT_OK_RESPONSE_CODE_ERROR_MESSAGE)
        end
      end

      def validate_hashes
        return if @error
        return unless response_code_is_ok?
        unless hashes_match?
          errors.add(:base, HASH_ERROR_MESSAGE)
        end
      end

      def verify_signature
        return if @error
        return unless response_code_is_ok?

        unless signature_is_valid?
          errors.add(:base, SIGNATURE_ERROR_MESSAGE)
        end
      end

      def verify_certificate
        return if @error
        return unless response_code_is_ok?

        unless certificate_is_trusted?
          errors.add(:base, 'The certificate in the response is not trusted')
        end
      end

      def response_code_is_ok?
        return true if %w(00 24).include? response_code

        false
      end

  end
end
