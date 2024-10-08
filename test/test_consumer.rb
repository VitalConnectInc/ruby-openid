# test helpers
require_relative "test_helper"
require_relative "testutil"

# this library
require "ruby-openid2"
require "openid/consumer"

module OpenID
  class Consumer
    module TestConsumer
      class TestLastEndpoint < Minitest::Test
        def test_set_get
          session = {}
          consumer = Consumer.new(session, nil)
          consumer.send(:last_requested_endpoint=, :endpoint)
          ep = consumer.send(:last_requested_endpoint)

          assert_equal(:endpoint, ep)
          ep = consumer.send(:last_requested_endpoint)

          assert_equal(:endpoint, ep)
          consumer.send(:cleanup_last_requested_endpoint)
          ep = consumer.send(:last_requested_endpoint)

          assert_nil(ep)
        end
      end

      class TestBegin < Minitest::Test
        attr_accessor :user_input,
          :anonymous,
          :services,
          :discovered_identifier,
          :checkid_request,
          :service

        def setup
          @discovered_identifier = "http://discovered/"
          @user_input = "user.input"
          @service = :service
          @services = [@service]
          @session = {}
          @anonymous = false
          @checkid_request = :checkid_request
        end

        def consumer
          test = self
          consumer = Consumer.new(@session, nil)
          consumer.extend(InstanceDefExtension)
          consumer.instance_def(:discover) do |identifier|
            test.assert_equal(test.user_input, identifier)
            [test.discovered_identifier, test.services]
          end
          consumer.instance_def(:begin_without_discovery) do |service, sent_anonymous|
            test.assert_equal(test.service, service)
            test.assert_equal(test.anonymous, sent_anonymous)
            test.checkid_request
          end
          consumer
        end

        def test_begin
          checkid_request = consumer.begin(@user_input, @anonymous)

          assert_equal(:checkid_request, checkid_request)
          assert_equal(
            ["OpenID::Consumer::DiscoveredServices::" \
              "OpenID::Consumer::"],
            @session.keys.sort!,
          )
        end

        def test_begin_failure
          @services = []
          assert_raises(DiscoveryFailure) do
            consumer.begin(@user_input, @anonymous)
          end
        end

        def test_begin_fallback
          @services = %i[service1 service2]
          consumer = self.consumer
          @service = :service1
          consumer.begin(@user_input, @anonymous)
          @service = :service2
          consumer.begin(@user_input, @anonymous)
          @service = :service1
          consumer.begin(@user_input, @anonymous)
          @service = :service2
          consumer.begin(@user_input, @anonymous)
        end
      end

      class TestBeginWithoutDiscovery < Minitest::Test
        attr_reader :assoc

        def setup
          @session = {}
          @assoc = :assoc
          @service = OpenIDServiceEndpoint.new
          @claimed_id = "http://claimed.id/"
          @service.claimed_id = @claimed_id
          @anonymous = false
        end

        def consumer
          test = self
          assoc_manager = Object.new
          assoc_manager.extend(InstanceDefExtension)
          assoc_manager.instance_def(:get_association) do
            test.assoc
          end

          consumer = Consumer.new(@session, nil)
          consumer.extend(InstanceDefExtension)
          consumer.instance_def(:association_manager) do |_service|
            assoc_manager
          end
          consumer
        end

        def call_begin_without_discovery
          result = consumer.begin_without_discovery(@service, @anonymous)

          assert_instance_of(CheckIDRequest, result)
          assert_equal(@anonymous, result.anonymous)
          assert_equal(@service, consumer.send(:last_requested_endpoint))
          assert_equal(result.instance_variable_get(:@assoc), @assoc)
          result
        end

        def cid_name
          Consumer.openid1_return_to_claimed_id_name
        end

        def nonce_name
          Consumer.openid1_return_to_nonce_name
        end

        def test_begin_without_openid1
          result = call_begin_without_discovery

          assert_equal(@claimed_id, result.return_to_args[cid_name])
          assert_equal(
            [cid_name, nonce_name].sort!,
            result.return_to_args.keys.sort!,
          )
        end

        def test_begin_without_openid1_anonymous
          @anonymous = true
          assert_raises(ArgumentError) do
            call_begin_without_discovery
          end
        end

        def test_begin_without_openid2
          @service.type_uris = [OPENID_2_0_TYPE]
          result = call_begin_without_discovery

          assert_empty(result.return_to_args)
        end

        def test_begin_without_openid2_anonymous
          @anonymous = true
          @service.type_uris = [OPENID_2_0_TYPE]
          result = call_begin_without_discovery

          assert_empty(result.return_to_args)
        end
      end

      class TestComplete < Minitest::Test
        def setup
          @session = {}
          @consumer = Consumer.new(@session, nil)
        end

        def test_bad_mode
          response = @consumer.complete(
            {
              "openid.ns" => OPENID2_NS,
              "openid.mode" => "bad",
            },
            nil,
          )

          assert_equal(FAILURE, response.status)
        end

        def test_missing_mode
          response = @consumer.complete({"openid.ns" => OPENID2_NS}, nil)

          assert_equal(FAILURE, response.status)
        end

        def test_cancel
          response = @consumer.complete({"openid.mode" => "cancel"}, nil)

          assert_equal(CANCEL, response.status)
        end

        def test_setup_needed_openid1
          response = @consumer.complete({"openid.mode" => "setup_needed"}, nil)

          assert_equal(FAILURE, response.status)
        end

        def test_setup_needed_openid2
          setup_url = "http://setup.url/"
          args = {"openid.ns" => OPENID2_NS, "openid.mode" => "setup_needed", "openid.user_setup_url" => setup_url}
          response = @consumer.complete(args, nil)

          assert_equal(SETUP_NEEDED, response.status)
          assert_equal(setup_url, response.setup_url)
        end

        def test_idres_setup_needed_openid1
          setup_url = "http://setup.url/"
          args = {
            "openid.user_setup_url" => setup_url,
            "openid.mode" => "id_res",
          }
          response = @consumer.complete(args, nil)

          assert_equal(SETUP_NEEDED, response.status)
          assert_equal(setup_url, response.setup_url)
        end

        def test_error
          contact = "me"
          reference = "thing thing"
          args = {
            "openid.mode" => "error",
            "openid.contact" => contact,
            "openid.reference" => reference,
          }
          response = @consumer.complete(args, nil)

          assert_equal(FAILURE, response.status)
          assert_equal(contact, response.contact)
          assert_equal(reference, response.reference)

          args["openid.ns"] = OPENID2_NS
          response = @consumer.complete(args, nil)

          assert_equal(FAILURE, response.status)
          assert_equal(contact, response.contact)
          assert_equal(reference, response.reference)
        end

        def test_idres_openid1
          args = {
            "openid.mode" => "id_res",
          }

          endpoint = OpenIDServiceEndpoint.new
          endpoint.claimed_id = :test_claimed_id

          idres = Object.new
          idres.extend(InstanceDefExtension)
          idres.instance_def(:endpoint) { endpoint }
          idres.instance_def(:signed_fields) { :test_signed_fields }

          test = self
          @consumer.extend(InstanceDefExtension)
          @consumer.instance_def(:handle_idres) do |message, return_to|
            test.assert_equal(args, message.to_post_args)
            test.assert_equal(:test_return_to, return_to)
            idres
          end

          response = @consumer.complete(args, :test_return_to)

          assert_equal(SUCCESS, response.status, response.message)
          assert_equal(:test_claimed_id, response.identity_url)
          assert_equal(endpoint, response.endpoint)

          error_message = "In Soviet Russia, id_res handles you!"
          @consumer.instance_def(:handle_idres) do |_message, _return_to|
            raise ProtocolError, error_message
          end
          response = @consumer.complete(args, :test_return_to)

          assert_equal(FAILURE, response.status)
          assert_equal(error_message, response.message)
        end
      end
    end
  end
end
