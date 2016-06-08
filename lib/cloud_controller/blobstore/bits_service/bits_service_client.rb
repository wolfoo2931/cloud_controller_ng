module CloudController
  module Blobstore
    class BitsServiceClient
      def initialize(bits_client:, resource_type:)
        raise StandardError 'Must specify resource type' unless resource_type.present?
        @resource_type = resource_type
        @resource_type_singular = @resource_type.to_s.singularize
        @bits_client = bits_client
      end

      def local?
        false
      end

      def exists?(key)
        raise NotImplementedError
      end

      def cp_r_to_blobstore(source_dir)
        raise NotImplementedError
      end

      def cp_to_blobstore(_, _)
        raise NotImplementedError
      end

      def cp_file_between_keys(source_key, destination_key)
        raise NotImplementedError
      end

      def download_from_blobstore(source_key, destination_path, mode: nil)
        raise NotImplementedError
      end

      def delete(key)
        raise NotImplementedError
      end

      def blob(key)
        OpenStruct.new({
          guid: key,
          public_download_url: @bits_client.download_url(@resource_type, key),
          internal_download_url: @bits_client.internal_download_url(@resource_type, key)
        })
      end

      def delete_blob(blob)
        @bits_client.public_send("delete_#{@resource_type_singular}", blob.guid)
      end

      def delete_all(_=nil)
        raise NotImplementedError
      end

      def delete_all_in_path(path)
        if :buildpack_cache != @resource_type
          raise NotImplementedError
        else
          @bits_client.delete_buildpack_cache(path)
        end
      end
    end
  end
end
