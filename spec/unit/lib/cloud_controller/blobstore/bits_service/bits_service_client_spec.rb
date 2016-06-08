require 'spec_helper'
require 'cloud_controller/blobstore/bits_service/bits_service_client'
require_relative '../client_shared'

module CloudController
  module Blobstore
    describe BitsServiceClient do
      let(:bits_client) { double(:bits_client) }
      let(:resource_type) { [:buildpacks, :droplets, :packages].sample }
      let(:resource_type_singular) { resource_type.to_s.singularize }
      let(:key) { SecureRandom.uuid }

      subject(:client) { BitsServiceClient.new(bits_client: bits_client, resource_type: resource_type) }

      describe '#local?' do
        it 'is not local' do
          expect(client.local?).to be_falsey
        end
      end

      describe '#blob' do
        before do
          allow(bits_client).to receive(:download_url).with(resource_type, key).and_return('the-correct-path')
          allow(bits_client).to receive(:internal_download_url).with(resource_type, key).and_return('the-internal-url')
        end

        it 'returns the correct blob' do
          blob = client.blob(key)

          expect(blob.guid).to eq(key)
          expect(blob.public_download_url).to eq('the-correct-path')
          expect(blob.internal_download_url).to eq('the-internal-url')
        end
      end

      describe '#delete_blob' do
        it 'deletes the right blob using the bits_client' do
          expect(bits_client).to receive("delete_#{resource_type_singular}").with(key)
          client.delete_blob(double(:blob, guid: key))
        end
      end

      describe '#delete_all_in_path' do
        context 'the resource_type is :buildpack_cache' do
          let(:resource_type) { :buildpack_cache }

          it 'delegates to the client' do
            expect(bits_client).to receive('delete_buildpack_cache').with(key)
            client.delete_all_in_path(key)
          end
        end

        context 'the resource_type is any of [:buildpacks, :droplets, :packages]' do
          it 'raises an error' do
            expect { client.delete_all_in_path('some-key') }.to raise_error(NotImplementedError)
          end
        end
      end
    end
  end
end
