require_relative "kvform"
require_relative "util"
require_relative "cryptutil"
require_relative "message"

module OpenID
  def self.get_secret_size(assoc_type)
    if assoc_type == "HMAC-SHA1"
      20
    elsif assoc_type == "HMAC-SHA256"
      32
    else
      raise ArgumentError("Unsupported association type: #{assoc_type}")
    end
  end

  # An Association holds the shared secret between a relying party and
  # an OpenID provider.
  class Association
    attr_reader :handle, :secret, :issued, :lifetime, :assoc_type

    FIELD_ORDER =
      %i[version handle secret issued lifetime assoc_type]

    # Load a serialized Association
    def self.deserialize(serialized)
      parsed = Util.kv_to_seq(serialized)
      parsed_fields = parsed.map { |k, _v| k.to_sym }
      if parsed_fields != FIELD_ORDER
        raise ProtocolError, "Unexpected fields in serialized association " \
          "(Expected #{FIELD_ORDER.inspect}, got #{parsed_fields.inspect})"
      end
      version, handle, secret64, issued_s, lifetime_s, assoc_type =
        parsed.map { |_field, value| value }
      if version != "2"
        raise ProtocolError, "Attempted to deserialize unsupported version " \
          "(#{parsed[0][1].inspect})"
      end

      new(
        handle,
        Util.from_base64(secret64),
        Time.at(issued_s.to_i),
        lifetime_s.to_i,
        assoc_type,
      )
    end

    # Create an Association with an issued time of now
    def self.from_expires_in(expires_in, handle, secret, assoc_type)
      issued = Time.now
      new(handle, secret, issued, expires_in, assoc_type)
    end

    def initialize(handle, secret, issued, lifetime, assoc_type)
      @handle = handle
      @secret = secret
      @issued = issued
      @lifetime = lifetime
      @assoc_type = assoc_type
    end

    # Serialize the association to a form that's consistent across
    # JanRain OpenID libraries.
    def serialize
      data = {
        version: "2",
        handle: handle,
        secret: Util.to_base64(secret),
        issued: issued.to_i.to_s,
        lifetime: lifetime.to_i.to_s,
        assoc_type: assoc_type,
      }

      Util.truthy_assert(data.length == FIELD_ORDER.length)

      pairs = FIELD_ORDER.map { |field| [field.to_s, data[field]] }
      Util.seq_to_kv(pairs, true)
    end

    # The number of seconds until this association expires
    def expires_in(now = nil)
      now = if now.nil?
        Time.now.to_i
      else
        now.to_i
      end
      time_diff = (issued.to_i + lifetime) - now
      return 0 if time_diff < 0

      time_diff
    end

    # Generate a signature for a sequence of [key, value] pairs
    def sign(pairs)
      kv = Util.seq_to_kv(pairs)
      case assoc_type
      when "HMAC-SHA1"
        CryptUtil.hmac_sha1(@secret, kv)
      when "HMAC-SHA256"
        CryptUtil.hmac_sha256(@secret, kv)
      else
        raise ProtocolError, "Association has unknown type: " \
          "#{assoc_type.inspect}"
      end
    end

    # Generate the list of pairs that form the signed elements of the
    # given message
    def make_pairs(message)
      signed = message.get_arg(OPENID_NS, "signed")
      raise ProtocolError, "Missing signed list" if signed.nil?

      signed_fields = signed.split(",", -1)
      data = message.to_post_args
      signed_fields.map { |field| [field, data.fetch("openid." + field, "")] }
    end

    # Return whether the message's signature passes
    def check_message_signature(message)
      message_sig = message.get_arg(OPENID_NS, "sig")
      raise ProtocolError, "#{message} has no sig." if message_sig.nil?

      calculated_sig = get_message_signature(message)
      CryptUtil.const_eq(calculated_sig, message_sig)
    end

    # Get the signature for this message
    def get_message_signature(message)
      Util.to_base64(sign(make_pairs(message)))
    end

    def ==(other)
      (other.class == self.class and
       other.handle == handle and
       other.secret == secret and

       # The internals of the time objects seemed to differ
       # in an opaque way when serializing/unserializing.
       # I don't think this will be a problem.
       other.issued.to_i == issued.to_i and

       other.lifetime == lifetime and
       other.assoc_type == assoc_type)
    end

    # Add a signature (and a signed list) to a message.
    def sign_message(message)
      if message.has_key?(OPENID_NS, "sig") or
          message.has_key?(OPENID_NS, "signed")
        raise ArgumentError, "Message already has signed list or signature"
      end

      extant_handle = message.get_arg(OPENID_NS, "assoc_handle")
      raise ArgumentError, "Message has a different association handle" if extant_handle and extant_handle != handle

      signed_message = message.copy
      signed_message.set_arg(OPENID_NS, "assoc_handle", handle)
      message_keys = signed_message.to_post_args.keys

      signed_list = []
      message_keys.each do |k|
        signed_list << k[7..-1] if k.start_with?("openid.")
      end

      signed_list << "signed"
      signed_list.sort!

      signed_message.set_arg(OPENID_NS, "signed", signed_list.join(","))
      sig = get_message_signature(signed_message)
      signed_message.set_arg(OPENID_NS, "sig", sig)
      signed_message
    end
  end

  class AssociationNegotiator
    attr_reader :allowed_types

    def self.get_session_types(assoc_type)
      case assoc_type
      when "HMAC-SHA1"
        %w[DH-SHA1 no-encryption]
      when "HMAC-SHA256"
        %w[DH-SHA256 no-encryption]
      else
        raise ProtocolError, "Unknown association type #{assoc_type.inspect}"
      end
    end

    def self.check_session_type(assoc_type, session_type)
      return if get_session_types(assoc_type).include?(session_type)

      raise ProtocolError, "Session type #{session_type.inspect} not " \
        "valid for association type #{assoc_type.inspect}"
    end

    def initialize(allowed_types)
      self.allowed_types = (allowed_types)
    end

    def copy
      Marshal.load(Marshal.dump(self))
    end

    def allowed_types=(allowed_types)
      allowed_types.each do |assoc_type, session_type|
        self.class.check_session_type(assoc_type, session_type)
      end
      @allowed_types = allowed_types
    end

    def add_allowed_type(assoc_type, session_type = nil)
      if session_type.nil?
        session_types = self.class.get_session_types(assoc_type)
      else
        self.class.check_session_type(assoc_type, session_type)
        session_types = [session_type]
      end
      for session_type in session_types do
        @allowed_types << [assoc_type, session_type]
      end
    end

    def allowed?(assoc_type, session_type)
      @allowed_types.include?([assoc_type, session_type])
    end

    def get_allowed_type
      @allowed_types.empty? ? nil : @allowed_types[0]
    end
  end

  DefaultNegotiator =
    AssociationNegotiator.new([
      %w[HMAC-SHA1 DH-SHA1],
      %w[HMAC-SHA1 no-encryption],
      %w[HMAC-SHA256 DH-SHA256],
      %w[HMAC-SHA256 no-encryption],
    ])

  EncryptedNegotiator =
    AssociationNegotiator.new([
      %w[HMAC-SHA1 DH-SHA1],
      %w[HMAC-SHA256 DH-SHA256],
    ])
end
