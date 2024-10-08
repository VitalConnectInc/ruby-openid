# stdlib
require "fileutils"
require "pathname"
require "tempfile"

# This library
require_relative "../util"
require_relative "../association"
require_relative "interface"

module OpenID
  module Store
    class Filesystem < Interface
      @@FILENAME_ALLOWED = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-".split("")

      # Create a Filesystem store instance, putting all data in +directory+.
      def initialize(directory)
        @nonce_dir = File.join(directory, "nonces")
        @association_dir = File.join(directory, "associations")
        @temp_dir = File.join(directory, "temp")

        ensure_dir(@nonce_dir)
        ensure_dir(@association_dir)
        ensure_dir(@temp_dir)
      end

      # Create a unique filename for a given server url and handle. The
      # filename that is returned will contain the domain name from the
      # server URL for ease of human inspection of the data dir.
      def get_association_filename(server_url, handle)
        raise ArgumentError, "Bad server URL: #{server_url}" unless server_url.index("://")

        proto, rest = server_url.split("://", 2)
        domain = filename_escape(rest.split("/", 2)[0])
        url_hash = safe64(server_url)
        handle_hash = if handle
          safe64(handle)
        else
          ""
        end
        filename = [proto, domain, url_hash, handle_hash].join("-")
        File.join(@association_dir, filename)
      end

      # Store an association in the assoc directory
      def store_association(server_url, association)
        assoc_s = association.serialize
        filename = get_association_filename(server_url, association.handle)
        f, tmp = mktemp

        begin
          begin
            f.write(assoc_s)
            f.fsync
          ensure
            f.close
          end

          begin
            File.rename(tmp, filename)
          rescue Errno::EEXIST
            begin
              File.unlink(filename)
            rescue Errno::ENOENT
              # do nothing
            end

            File.rename(tmp, filename)
          end
        rescue StandardError
          remove_if_present(tmp)
          raise
        end
      end

      # Retrieve an association
      def get_association(server_url, handle = nil)
        # the filename with empty handle is the prefix for the associations
        # for a given server url
        filename = get_association_filename(server_url, handle)
        return _get_association(filename) if handle

        assoc_filenames = Dir.glob(filename.to_s + "*")

        assocs = assoc_filenames.collect do |f|
          _get_association(f)
        end

        assocs = assocs.find_all { |a| !a.nil? }
        assocs = assocs.sort_by { |a| a.issued }

        return if assocs.empty?

        assocs[-1]
      end

      def _get_association(filename)
        assoc_file = File.open(filename, "r")
      rescue Errno::ENOENT
        nil
      else
        begin
          assoc_s = assoc_file.read
        ensure
          assoc_file.close
        end

        begin
          association = Association.deserialize(assoc_s)
        rescue StandardError
          remove_if_present(filename)
          return
        end

        # clean up expired associations
        return association unless association.expires_in == 0

        remove_if_present(filename)
        nil
      end

      # Remove an association if it exists, otherwise do nothing.
      def remove_association(server_url, handle)
        assoc = get_association(server_url, handle)

        return false if assoc.nil?

        filename = get_association_filename(server_url, handle)
        remove_if_present(filename)
      end

      # Return whether the nonce is valid
      def use_nonce(server_url, timestamp, salt)
        return false if (timestamp - Time.now.to_i).abs > Nonce.skew

        if server_url and !server_url.empty?
          proto, rest = server_url.split("://", 2)
        else
          proto = ""
          rest = ""
        end
        raise "Bad server URL" unless proto && rest

        domain = filename_escape(rest.split("/", 2)[0])
        url_hash = safe64(server_url)
        salt_hash = safe64(salt)

        nonce_fn = format("%08x-%s-%s-%s-%s", timestamp, proto, domain, url_hash, salt_hash)

        filename = File.join(@nonce_dir, nonce_fn)

        begin
          fd = File.new(filename, File::CREAT | File::EXCL | File::WRONLY, 0o200)
          fd.close
          true
        rescue Errno::EEXIST
          false
        end
      end

      # Remove expired entries from the database. This is potentially expensive,
      # so only run when it is acceptable to take time.
      def cleanup
        cleanup_associations
        cleanup_nonces
      end

      def cleanup_associations
        association_filenames = Dir[File.join(@association_dir, "*")]
        count = 0
        association_filenames.each do |af|
          f = File.open(af, "r")
        rescue Errno::ENOENT
          next
        else
          begin
            assoc_s = f.read
          ensure
            f.close
          end
          begin
            association = OpenID::Association.deserialize(assoc_s)
          rescue StandardError
            remove_if_present(af)
            next
          else
            if association.expires_in == 0
              remove_if_present(af)
              count += 1
            end
          end
        end
        count
      end

      def cleanup_nonces
        nonces = Dir[File.join(@nonce_dir, "*")]
        now = Time.now.to_i

        count = 0
        nonces.each do |filename|
          nonce = filename.split("/")[-1]
          timestamp = nonce.split("-", 2)[0].to_i(16)
          nonce_age = (timestamp - now).abs
          if nonce_age > Nonce.skew
            remove_if_present(filename)
            count += 1
          end
        end
        count
      end

      protected

      # Create a temporary file and return the File object and filename.
      def mktemp
        f = Tempfile.new("tmp", @temp_dir)
        [f, f.path]
      end

      # create a safe filename from a url
      def filename_escape(s)
        s = "" if s.nil?
        s.each_char.flat_map do |c|
          if @@FILENAME_ALLOWED.include?(c)
            c
          else
            c.bytes.map do |b|
              "_%02X" % b
            end
          end
        end.join
      end

      def safe64(s)
        s = OpenID::CryptUtil.sha1(s)
        s = OpenID::Util.to_base64(s)
        s.tr!("+", "_")
        s.tr!("/", ".")
        s.delete!("=")
        s
      end

      # remove file if present in filesystem
      def remove_if_present(filename)
        begin
          File.unlink(filename)
        rescue Errno::ENOENT
          return false
        end
        true
      end

      # ensure that a path exists
      def ensure_dir(dir_name)
        FileUtils.mkdir_p(dir_name)
      end
    end
  end
end
