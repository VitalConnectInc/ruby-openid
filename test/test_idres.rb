# test helpers
require_relative "test_helper"
require_relative "testutil"
require_relative "util"

# this library
require "ruby-openid2"
require "openid/consumer/idres"
require "openid/protocolerror"
require "openid/store/memory"
require "openid/store/nonce"

module OpenID
  class Consumer
    class IdResHandler
      # Subclass of IdResHandler that doesn't do verification upon
      # construction. All of the tests call this, except for the ones
      # explicitly for id_res.
      class IdResHandler < OpenID::Consumer::IdResHandler
        def id_res
        end
      end

      class CheckForFieldsTest < Minitest::Test
        include ProtocolErrorMixin

        BASE_FIELDS = %w[return_to assoc_handle sig signed]
        OPENID2_FIELDS = BASE_FIELDS + ["op_endpoint"]
        OPENID1_FIELDS = BASE_FIELDS + ["identity"]

        OPENID1_SIGNED = %w[return_to identity]
        OPENID2_SIGNED =
          OPENID1_SIGNED + %w[
            response_nonce
            claimed_id
            assoc_handle
            op_endpoint
          ]

        def mkMsg(ns, fields, signed_fields)
          msg = Message.new(ns)
          fields.each do |field|
            msg.set_arg(OPENID_NS, field, "don't care")
          end
          msg.set_arg(OPENID_NS, "signed", signed_fields.join(",")) if fields.member?("signed")
          msg
        end

        1.times do # so as not to bleed into the outer namespace
          n = 0
          [
            [],
            ["foo"],
            %w[bar baz],
          ].each do |signed_fields|
            test = lambda do
              msg = mkMsg(OPENID2_NS, OPENID2_FIELDS, signed_fields)
              idres = IdResHandler.new(msg, nil)

              assert_equal(signed_fields, idres.send(:signed_list))
              # Do it again to make sure logic for caching is correct
              assert_equal(signed_fields, idres.send(:signed_list))
            end
            define_method("test_signed_list_#{n += 1}", test)
          end
        end

        # test all missing fields for OpenID 1 and 2
        1.times do
          [
            ["openid1", OPENID1_NS, OPENID1_FIELDS],
            ["openid1", OPENID11_NS, OPENID1_FIELDS],
            ["openid2", OPENID2_NS, OPENID2_FIELDS],
          ].each_with_index do |(ver, ns, all_fields), i|
            all_fields.each do |field|
              test = lambda do
                fields = all_fields.dup
                fields.delete(field)
                msg = mkMsg(ns, fields, [])
                idres = IdResHandler.new(msg, nil)
                assert_protocol_error("Missing required field #{field}") do
                  idres.send(:check_for_fields)
                end
              end
              define_method(:"test_#{i}_#{ver}_check_missing_#{field}", test)
            end
          end
        end

        # Test all missing signed for OpenID 1 and 2
        1.times do
          [
            ["openid1", OPENID1_NS, OPENID1_FIELDS, OPENID1_SIGNED],
            ["openid1", OPENID11_NS, OPENID1_FIELDS, OPENID1_SIGNED],
            [
              "openid2",
              OPENID2_NS,
              OPENID2_FIELDS,
              OPENID2_SIGNED,
            ],
          ].each_with_index do |(ver, ns, all_fields, signed_fields), i|
            signed_fields.each do |signed_field|
              test = lambda do
                fields = signed_fields.dup
                fields.delete(signed_field)
                msg = mkMsg(ns, all_fields, fields)
                # Make sure the signed field is actually in the request
                msg.set_arg(OPENID_NS, signed_field, "don't care")
                idres = IdResHandler.new(msg, nil)
                assert_protocol_error("#{signed_field.inspect} not signed") do
                  idres.send(:check_for_fields)
                end
              end
              define_method(:"test_#{i}_#{ver}_check_missing_signed_#{signed_field}", test)
            end
          end
        end

        def test_112
          args = {
            "openid.assoc_handle" => "fa1f5ff0-cde4-11dc-a183-3714bfd55ca8",
            "openid.claimed_id" => "http://binkley.lan/user/test01",
            "openid.identity" => "http://test01.binkley.lan/",
            "openid.mode" => "id_res",
            "openid.ns" => "http://specs.openid.net/auth/2.0",
            "openid.ns.pape" => "http://specs.openid.net/extensions/pape/1.0",
            "openid.op_endpoint" => "http://binkley.lan/server",
            "openid.pape.auth_policies" => "none",
            "openid.pape.auth_time" => "2008-01-28T20:42:36Z",
            "openid.pape.nist_auth_level" => "0",
            "openid.response_nonce" => "2008-01-28T21:07:04Z99Q=",
            "openid.return_to" => "http://binkley.lan:8001/process?janrain_nonce=2008-01-28T21%3A07%3A02Z0tMIKx",
            "openid.sig" => "YJlWH4U6SroB1HoPkmEKx9AyGGg=",
            "openid.signed" => "assoc_handle,identity,response_nonce,return_to,claimed_id,op_endpoint,pape.auth_time,ns.pape,pape.nist_auth_level,pape.auth_policies",
          }

          assert_equal(args["openid.ns"], OPENID2_NS)
          incoming = Message.from_post_args(args)

          assert(incoming.is_openid2)
          idres = IdResHandler.new(incoming, nil)
          car = idres.send(:create_check_auth_request)
          expected_args = args.dup
          expected_args["openid.mode"] = "check_authentication"
          expected = Message.from_post_args(expected_args)

          assert(expected.is_openid2)
          assert_equal(expected, car)
          assert_equal(expected_args, car.to_post_args)
        end

        def test_no_signed_list
          msg = Message.new(OPENID2_NS)
          idres = IdResHandler.new(msg, nil)
          assert_protocol_error("Response missing signed") do
            idres.send(:signed_list)
          end
        end

        def test_success_openid1
          msg = mkMsg(OPENID1_NS, OPENID1_FIELDS, OPENID1_SIGNED)
          idres = IdResHandler.new(msg, nil)
          idres.send(:check_for_fields)
        end

        def test_success_openid1_1
          msg = mkMsg(OPENID11_NS, OPENID1_FIELDS, OPENID1_SIGNED)
          idres = IdResHandler.new(msg, nil)
          idres.send(:check_for_fields)
        end
      end

      class ReturnToArgsTest < Minitest::Test
        include OpenID::ProtocolErrorMixin

        def check_return_to_args(query)
          idres = IdResHandler.new(Message.from_post_args(query), nil)
          class << idres
            def verify_return_to_base(unused)
            end
          end
          idres.send(:verify_return_to)
        end

        def assert_bad_args(msg, query)
          assert_protocol_error(msg) do
            check_return_to_args(query)
          end
        end

        def test_return_to_args_okay
          check_return_to_args({
            "openid.mode" => "id_res",
            "openid.return_to" => "http://example.com/?foo=bar",
            "foo" => "bar",
          })
        end

        def test_unexpected_arg_okay
          assert_bad_args("Unexpected parameter", {
            "openid.mode" => "id_res",
            "openid.return_to" => "http://example.com/",
            "foo" => "bar",
          })
        end

        def test_return_to_mismatch
          assert_bad_args("Message missing ret", {
            "openid.mode" => "id_res",
            "openid.return_to" => "http://example.com/?foo=bar",
          })

          assert_bad_args("Parameter 'foo' val", {
            "openid.mode" => "id_res",
            "openid.return_to" => "http://example.com/?foo=bar",
            "foo" => "foos",
          })
        end
      end

      class ReturnToVerifyTest < Minitest::Test
        def test_bad_return_to
          return_to = "http://some.url/path?foo=bar"

          m = Message.new(OPENID1_NS)
          m.set_arg(OPENID_NS, "mode", "cancel")
          m.set_arg(BARE_NS, "foo", "bar")

          # Scheme, authority, and path differences are checked by
          # IdResHandler.verify_return_to_base.  Query args checked by
          # IdResHandler.verify_return_to_args.
          [
            # Scheme only
            "https://some.url/path?foo=bar",
            # Authority only
            "http://some.url.invalid/path?foo=bar",
            # Path only
            "http://some.url/path_extra?foo=bar",
            # Query args differ
            "http://some.url/path?foo=bar2",
            "http://some.url/path?foo2=bar",
          ].each do |bad|
            m.set_arg(OPENID_NS, "return_to", bad)
            idres = IdResHandler.new(m, return_to)
            assert_raises(ProtocolError) do
              idres.send(:verify_return_to)
            end
          end
        end

        def test_good_return_to
          base = "http://example.janrain.com/path"
          [
            [base, {}],
            [base + "?another=arg", {"another" => "arg"}],
            [base + "?another=arg#frag", {"another" => "arg"}],
            ["HTTP" + base[4..-1], {}],
            [base.sub("com", "COM"), {}],
            ["http://example.janrain.com:80/path", {}],
            ["http://example.janrain.com/p%61th", {}],
            ["http://example.janrain.com/./path", {}],
          ].each do |return_to, args|
            args["openid.return_to"] = return_to
            msg = Message.from_post_args(args)
            idres = IdResHandler.new(msg, base)
            idres.send(:verify_return_to)
          end
        end
      end

      class DummyEndpoint
        attr_accessor :server_url

        def initialize(server_url)
          @server_url = server_url
        end
      end

      class CheckSigTest < Minitest::Test
        include ProtocolErrorMixin
        include TestUtil

        def setup
          @assoc = GoodAssoc.new("{not_dumb}")
          @store = Store::Memory.new
          @server_url = "http://server.url/"
          @endpoint = DummyEndpoint.new(@server_url)
          @store.store_association(@server_url, @assoc)

          @message = Message.from_post_args({
            "openid.mode" => "id_res",
            "openid.identity" => "=example",
            "openid.sig" => GOODSIG,
            "openid.assoc_handle" => @assoc.handle,
            "openid.signed" => "mode,identity,assoc_handle,signed",
            "frobboz" => "banzit",
          })
        end

        def call_idres_method(method_name)
          idres = IdResHandler.new(@message, nil, @store, @endpoint)
          idres.extend(InstanceDefExtension)
          yield idres
          idres.send(method_name)
        end

        def call_check_sig(&proc)
          call_idres_method(:check_signature, &proc)
        end

        def no_check_auth(idres)
          idres.instance_def(:check_auth) { raise "Called check_auth" }
        end

        def test_sign_good
          call_check_sig(&method(:no_check_auth))
        end

        def test_bad_sig
          @message.set_arg(OPENID_NS, "sig", "bad sig!")
          assert_protocol_error("Bad signature") do
            call_check_sig(&method(:no_check_auth))
          end
        end

        def test_check_auth_ok
          @message.set_arg(OPENID_NS, "assoc_handle", "dumb-handle")
          check_auth_called = false
          call_check_sig do |idres|
            idres.instance_def(:check_auth) do
              check_auth_called = true
            end
          end

          assert(check_auth_called)
        end

        def test_check_auth_ok_no_store
          @store = nil
          check_auth_called = false
          call_check_sig do |idres|
            idres.instance_def(:check_auth) do
              check_auth_called = true
            end
          end

          assert(check_auth_called)
        end

        def test_expired_assoc
          @assoc.expires_in = -1
          @store.store_association(@server_url, @assoc)
          assert_protocol_error("Association with") do
            call_check_sig(&method(:no_check_auth))
          end
        end

        def call_check_auth(&proc)
          assert_log_matches("Using 'check_authentication'") do
            call_idres_method(:check_auth, &proc)
          end
        end

        def test_check_auth_create_fail
          assert_protocol_error("Could not generate") do
            call_check_auth do |idres|
              idres.instance_def(:create_check_auth_request) do
                raise Message::KeyNotFound, "Testing"
              end
            end
          end
        end

        def test_check_auth_okay
          OpenID.extend(OverrideMethodMixin)
          me = self
          send_resp = proc do |req, _server_url|
            me.assert_equal(:req, req)
            :expected_response
          end

          OpenID.with_method_overridden(:make_kv_post, send_resp) do
            call_check_auth do |idres|
              idres.instance_def(:create_check_auth_request) do
                :req
              end

              idres.instance_def(:process_check_auth_response) do |resp|
                me.assert_equal(:expected_response, resp)
              end
            end
          end
        end

        def test_check_auth_process_fail
          OpenID.extend(OverrideMethodMixin)
          me = self
          send_resp = proc do |req, _server_url|
            me.assert_equal(:req, req)
            :expected_response
          end

          OpenID.with_method_overridden(:make_kv_post, send_resp) do
            assert_protocol_error("Testing") do
              call_check_auth do |idres|
                idres.instance_def(:create_check_auth_request) { :req }
                idres.instance_def(:process_check_auth_response) do |resp|
                  me.assert_equal(:expected_response, resp)
                  raise ProtocolError, "Testing"
                end
              end
            end
          end
        end

        1.times do
          # Fields from the signed list
          %w[mode identity assoc_handle].each do |field|
            test = lambda do
              @message.del_arg(OPENID_NS, field)
              assert_raises(Message::KeyNotFound) do
                call_idres_method(:create_check_auth_request) {}
              end
            end
            define_method(:"test_create_check_auth_missing_#{field}", test)
          end
        end

        def test_create_check_auth_request_success
          ca_msg = call_idres_method(:create_check_auth_request) {}
          expected = @message.copy
          expected.set_arg(OPENID_NS, "mode", "check_authentication")

          assert_equal(expected, ca_msg)
        end
      end

      class CheckAuthResponseTest < Minitest::Test
        include TestUtil
        include ProtocolErrorMixin

        def setup
          @message = Message.from_openid_args({
            "is_valid" => "true",
          })
          @assoc = GoodAssoc.new
          @store = Store::Memory.new
          @server_url = "http://invalid/"
          @endpoint = DummyEndpoint.new(@server_url)
          @idres = IdResHandler.new(nil, nil, @store, @endpoint)
        end

        def call_process
          @idres.send(:process_check_auth_response, @message)
        end

        def test_valid
          assert_log_matches { call_process }
        end

        def test_invalid
          %w[false monkeys].each do
            @message.set_arg(OPENID_NS, "is_valid", "false")
            assert_protocol_error("Server #{@server_url} responds") do
              assert_log_matches { call_process }
            end
          end
        end

        def test_valid_invalidate
          @message.set_arg(OPENID_NS, "invalidate_handle", "cheese")
          assert_log_matches("Received 'invalidate_handle'") { call_process }
        end

        def test_invalid_invalidate
          @message.set_arg(OPENID_NS, "invalidate_handle", "cheese")
          %w[false monkeys].each do
            @message.set_arg(OPENID_NS, "is_valid", "false")
            assert_protocol_error("Server #{@server_url} responds") do
              assert_log_matches("Received 'invalidate_handle'") do
                call_process
              end
            end
          end
        end

        def test_invalidate_no_store
          @idres.instance_variable_set(:@store, nil)
          @message.set_arg(OPENID_NS, "invalidate_handle", "cheese")
          assert_log_matches(
            "Received 'invalidate_handle'",
            'Unexpectedly got "invalidate_handle"',
          ) do
            call_process
          end
        end
      end

      class NonceTest < Minitest::Test
        include TestUtil
        include ProtocolErrorMixin

        def setup
          @store = Object.new
          class << @store
            attr_accessor :nonces, :succeed

            def use_nonce(server_url, time, extra)
              @nonces << [server_url, time, extra]
              @succeed
            end
          end
          @store.nonces = []
          @nonce = Nonce.mk_nonce
        end

        def call_check_nonce(post_args, succeed = false)
          response = Message.from_post_args(post_args)
          @store.succeed = succeed unless @store.nil?
          idres = IdResHandler.new(response, nil, @store, nil)
          idres.send(:check_nonce)
        end

        def test_openid1_success
          [
            {},
            {"openid.ns" => OPENID1_NS},
            {"openid.ns" => OPENID11_NS},
          ].each do |args|
            call_check_nonce({"rp_nonce" => @nonce}.merge(args), true)
          end
        end

        def test_openid1_missing
          [
            {},
            {"openid.ns" => OPENID1_NS},
            {"openid.ns" => OPENID11_NS},
          ].each do |args|
            assert_protocol_error("Nonce missing") { call_check_nonce(args) }
          end
        end

        def test_openid2_ignore_rp_nonce
          assert_protocol_error("Nonce missing") do
            call_check_nonce({
              "rp_nonce" => @nonce,
              "openid.ns" => OPENID2_NS,
            })
          end
        end

        def test_openid2_success
          call_check_nonce(
            {
              "openid.response_nonce" => @nonce,
              "openid.ns" => OPENID2_NS,
            },
            true,
          )
        end

        def test_openid1_ignore_response_nonce
          [
            {},
            {"openid.ns" => OPENID1_NS},
            {"openid.ns" => OPENID11_NS},
          ].each do |args|
            assert_protocol_error("Nonce missing") do
              call_check_nonce({"openid.response_nonce" => @nonce}.merge(args))
            end
          end
        end

        def test_no_store
          @store = nil
          call_check_nonce({"rp_nonce" => @nonce})
        end

        def test_already_used
          assert_protocol_error("Nonce already used") do
            call_check_nonce({"rp_nonce" => @nonce}, false)
          end
        end

        def test_malformed_nonce
          assert_protocol_error("Malformed nonce") do
            call_check_nonce({"rp_nonce" => "whee!"})
          end
        end
      end

      class DiscoveryVerificationTest < Minitest::Test
        include ProtocolErrorMixin
        include TestUtil

        def setup
          @endpoint = OpenIDServiceEndpoint.new
        end

        def call_verify(msg_args)
          call_verify_modify(msg_args) {}
        end

        def call_verify_modify(msg_args)
          msg = Message.from_openid_args(msg_args)
          idres = IdResHandler.new(msg, nil, nil, @endpoint)
          idres.extend(InstanceDefExtension)
          yield idres
          idres.send(:verify_discovery_results)
          idres.instance_variable_get(:@endpoint)
        end

        def assert_verify_protocol_error(error_prefix, openid_args)
          assert_protocol_error(error_prefix) { call_verify(openid_args) }
        end

        def test_openid1_no_local_id
          @endpoint.claimed_id = "http://invalid/"

          assert_verify_protocol_error(
            "Missing required field: " \
              "<#{OPENID1_NS}>identity",
            {},
          )
        end

        def test_openid1_no_endpoint
          @endpoint = nil
          assert_raises(ProtocolError) do
            call_verify({"identity" => "snakes on a plane"})
          end
        end

        def test_openid1_fallback_1_0
          [OPENID1_NS, OPENID11_NS].each do |openid1_ns|
            claimed_id = "http://claimed.id/"
            @endpoint = nil
            resp_mesg = Message.from_openid_args({
              "ns" => openid1_ns,
              "identity" => claimed_id,
            })

            # Pass the OpenID 1 claimed_id this way since we're
            # passing None for the endpoint.
            resp_mesg.set_arg(BARE_NS, "openid1_claimed_id", claimed_id)

            # We expect the OpenID 1 discovery verification to try
            # matching the discovered endpoint against the 1.1 type
            # and fall back to 1.0.
            expected_endpoint = OpenIDServiceEndpoint.new
            expected_endpoint.type_uris = [OPENID_1_0_TYPE]
            expected_endpoint.local_id = nil
            expected_endpoint.claimed_id = claimed_id

            hacked_discover = proc do |_claimed_id|
              ["unused", [expected_endpoint]]
            end
            idres = IdResHandler.new(resp_mesg, nil, nil, @endpoint)
            assert_log_matches("Performing discovery") do
              OpenID.with_method_overridden(:discover, hacked_discover) do
                idres.send(:verify_discovery_results)
              end
            end
            actual_endpoint = idres.instance_variable_get(:@endpoint)

            assert_equal(actual_endpoint, expected_endpoint)
          end
        end

        def test_openid2_no_op_endpoint
          assert_protocol_error("Missing required field: " \
            "<#{OPENID2_NS}>op_endpoint") do
            call_verify({"ns" => OPENID2_NS})
          end
        end

        def test_openid2_local_id_no_claimed
          assert_verify_protocol_error(
            "openid.identity is present without",
            {
              "ns" => OPENID2_NS,
              "op_endpoint" => "Phone Home",
              "identity" => "Jorge Lius Borges",
            },
          )
        end

        def test_openid2_no_local_id_claimed
          assert_log_matches do
            assert_protocol_error("openid.claimed_id is present without") do
              call_verify({
                "ns" => OPENID2_NS,
                "op_endpoint" => "Phone Home",
                "claimed_id" => "Manuel Noriega",
              })
            end
          end
        end

        def test_openid2_no_identifiers
          op_endpoint = "Phone Home"
          result_endpoint = assert_log_matches do
            call_verify({
              "ns" => OPENID2_NS,
              "op_endpoint" => op_endpoint,
            })
          end
          assert(result_endpoint.is_op_identifier)
          assert_equal(op_endpoint, result_endpoint.server_url)
          assert_nil(result_endpoint.claimed_id)
        end

        def test_openid2_no_endpoint_does_disco
          endpoint = OpenIDServiceEndpoint.new
          endpoint.claimed_id = "monkeysoft"
          @endpoint = nil
          result = assert_log_matches("No pre-discovered") do
            call_verify_modify({
              "ns" => OPENID2_NS,
              "identity" => "sour grapes",
              "claimed_id" => "monkeysoft",
              "op_endpoint" => "Phone Home",
            }) do |idres|
              idres.instance_def(:discover_and_verify) do |_claimed_id, _endpoints|
                @endpoint = endpoint
              end
            end
          end
          assert_equal(endpoint, result)
        end

        def test_openid2_mismatched_does_disco
          @endpoint.claimed_id = "nothing special, but different"
          @endpoint.local_id = "green cheese"

          endpoint = OpenIDServiceEndpoint.new
          endpoint.claimed_id = "monkeysoft"

          result = assert_log_matches(
            "Error attempting to use stored",
            "Attempting discovery",
          ) do
            call_verify_modify({
              "ns" => OPENID2_NS,
              "identity" => "sour grapes",
              "claimed_id" => "monkeysoft",
              "op_endpoint" => "Green Cheese",
            }) do |idres|
              idres.instance_def(:discover_and_verify) do |_claimed_id, _endpoints|
                @endpoint = endpoint
              end
            end
          end
          assert_same(endpoint, result)
        end

        def test_verify_discovery_single_claimed_id_mismatch
          idres = IdResHandler.new(nil, nil)
          @endpoint.local_id = "my identity"
          @endpoint.claimed_id = "http://i-am-sam/"
          @endpoint.server_url = "Phone Home"
          @endpoint.type_uris = [OPENID_2_0_TYPE]

          to_match = @endpoint.dup
          to_match.claimed_id = "http://something.else/"

          e = assert_raises(ProtocolError) do
            idres.send(:verify_discovery_single, @endpoint, to_match)
          end
          assert_match(/different subjects/, e.to_s)
        end

        def test_openid1_1_verify_discovery_single_no_server_url
          idres = IdResHandler.new(nil, nil)
          @endpoint.local_id = "my identity"
          @endpoint.claimed_id = "http://i-am-sam/"
          @endpoint.server_url = "Phone Home"
          @endpoint.type_uris = [OPENID_1_1_TYPE]

          to_match = @endpoint.dup
          to_match.claimed_id = "http://i-am-sam/"
          to_match.type_uris = [OPENID_1_1_TYPE]
          to_match.server_url = nil

          idres.send(:verify_discovery_single, @endpoint, to_match)
        end

        def test_openid2_use_pre_discovered
          @endpoint.local_id = "my identity"
          @endpoint.claimed_id = "http://i-am-sam/"
          @endpoint.server_url = "Phone Home"
          @endpoint.type_uris = [OPENID_2_0_TYPE]

          result = assert_log_matches do
            call_verify({
              "ns" => OPENID2_NS,
              "identity" => @endpoint.local_id,
              "claimed_id" => @endpoint.claimed_id,
              "op_endpoint" => @endpoint.server_url,
            })
          end
          assert_same(result, @endpoint)
        end

        def test_openid2_use_pre_discovered_wrong_type
          text = "verify failed"
          me = self

          @endpoint.local_id = "my identity"
          @endpoint.claimed_id = "i am sam"
          @endpoint.server_url = "Phone Home"
          @endpoint.type_uris = [OPENID_1_1_TYPE]
          endpoint = @endpoint

          msg = Message.from_openid_args({
            "ns" => OPENID2_NS,
            "identity" => @endpoint.local_id,
            "claimed_id" =>
                                           @endpoint.claimed_id,
            "op_endpoint" =>
                                           @endpoint.server_url,
          })

          idres = IdResHandler.new(msg, nil, nil, @endpoint)
          idres.extend(InstanceDefExtension)
          idres.instance_def(:discover_and_verify) do |claimed_id, to_match|
            me.assert_equal(endpoint.claimed_id, to_match[0].claimed_id)
            me.assert_equal(claimed_id, endpoint.claimed_id)
            raise ProtocolError, text
          end
          assert_log_matches(
            "Error attempting to use stored",
            "Attempting discovery",
          ) do
            assert_protocol_error(text) do
              idres.send(:verify_discovery_results)
            end
          end
        end

        def test_openid1_use_pre_discovered
          @endpoint.local_id = "my identity"
          @endpoint.claimed_id = "http://i-am-sam/"
          @endpoint.server_url = "Phone Home"
          @endpoint.type_uris = [OPENID_1_1_TYPE]

          result = assert_log_matches do
            call_verify({
              "ns" => OPENID1_NS,
              "identity" => @endpoint.local_id,
            })
          end
          assert_same(result, @endpoint)
        end

        def test_openid1_use_pre_discovered_wrong_type
          verified_error = Class.new(Exception)

          @endpoint.local_id = "my identity"
          @endpoint.claimed_id = "i am sam"
          @endpoint.server_url = "Phone Home"
          @endpoint.type_uris = [OPENID_2_0_TYPE]

          assert_log_matches(
            "Error attempting to use stored",
            "Attempting discovery",
          ) do
            assert_raises(verified_error) do
              call_verify_modify({
                "ns" => OPENID1_NS,
                "identity" => @endpoint.local_id,
              }) do |idres|
                idres.instance_def(:discover_and_verify) do |_claimed_id, _endpoints|
                  raise verified_error
                end
              end
            end
          end
        end

        def test_openid2_fragment
          claimed_id = "http://unittest.invalid/"
          claimed_id_frag = claimed_id + "#fragment"

          @endpoint.local_id = "my identity"
          @endpoint.claimed_id = claimed_id
          @endpoint.server_url = "Phone Home"
          @endpoint.type_uris = [OPENID_2_0_TYPE]

          result = assert_log_matches do
            call_verify({
              "ns" => OPENID2_NS,
              "identity" => @endpoint.local_id,
              "claimed_id" => claimed_id_frag,
              "op_endpoint" => @endpoint.server_url,
            })
          end

          %i[local_id server_url type_uris].each do |sym|
            assert_equal(@endpoint.send(sym), result.send(sym))
          end
          assert_equal(claimed_id_frag, result.claimed_id)
        end

        def test_endpoint_without_local_id
          # An endpoint like this with no local_id is generated as a result of
          # e.g. Yadis discovery with no LocalID tag.
          @endpoint.server_url = "http://localhost:8000/openidserver"
          @endpoint.claimed_id = "http://localhost:8000/id/id-jo"

          to_match = OpenIDServiceEndpoint.new
          to_match.server_url = "http://localhost:8000/openidserver"
          to_match.claimed_id = "http://localhost:8000/id/id-jo"
          to_match.local_id = "http://localhost:8000/id/id-jo"

          idres = IdResHandler.new(nil, nil)
          assert_log_matches do
            idres.send(:verify_discovery_single, @endpoint, to_match)
          end
        end
      end

      class IdResTopLevelTest < Minitest::Test
        def test_id_res
          endpoint = OpenIDServiceEndpoint.new
          endpoint.server_url = "http://invalid/server"
          endpoint.claimed_id = "http://my.url/"
          endpoint.local_id = "http://invalid/username"
          endpoint.type_uris = [OPENID_2_0_TYPE]

          assoc = GoodAssoc.new
          store = Store::Memory.new
          store.store_association(endpoint.server_url, assoc)

          signed_fields =
            %w[
              response_nonce
              op_endpoint
              assoc_handle
              identity
              claimed_id
              ns
              return_to
            ]

          return_to = "http://return.to/"
          args = {
            "ns" => OPENID2_NS,
            "return_to" => return_to,
            "claimed_id" => endpoint.claimed_id,
            "identity" => endpoint.local_id,
            "assoc_handle" => assoc.handle,
            "op_endpoint" => endpoint.server_url,
            "response_nonce" => Nonce.mk_nonce,
            "signed" => signed_fields.join(","),
            "sig" => GOODSIG,
          }
          msg = Message.from_openid_args(args)
          idres = OpenID::Consumer::IdResHandler.new(
            msg,
            return_to,
            store,
            endpoint,
          )

          assert_equal(
            idres.signed_fields,
            signed_fields.map { |f| "openid." + f },
          )
        end
      end

      class DiscoverAndVerifyTest < Minitest::Test
        include ProtocolErrorMixin
        include TestUtil
        OpenID.extend(OverrideMethodMixin)

        def test_no_services
          me = self
          disco = proc do |e|
            me.assert_equal(:sentinel, e)
            [:undefined, []]
          end
          endpoint = OpenIDServiceEndpoint.new
          endpoint.claimed_id = :sentinel
          idres = IdResHandler.new(nil, nil)
          assert_log_matches("Performing discovery on") do
            assert_protocol_error("No OpenID information found") do
              OpenID.with_method_overridden(:discover, disco) do
                idres.send(:discover_and_verify, :sentinel, [endpoint])
              end
            end
          end
        end
      end

      class VerifyDiscoveredServicesTest < Minitest::Test
        include ProtocolErrorMixin
        include TestUtil

        def test_no_services
          endpoint = OpenIDServiceEndpoint.new
          endpoint.claimed_id = :sentinel
          idres = IdResHandler.new(nil, nil)
          assert_log_matches("Discovery verification failure") do
            assert_protocol_error("No matching endpoint") do
              idres.send(
                :verify_discovered_services,
                "http://bogus.id/",
                [],
                [endpoint],
              )
            end
          end
        end
      end
    end
  end
end
