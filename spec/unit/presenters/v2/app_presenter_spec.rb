require 'spec_helper'

module CloudController::Presenters::V2
  RSpec.describe AppPresenter do
    subject { described_class.new }

    let(:controller) { 'controller' }
    let(:opts) { {} }
    let(:depth) { 'depth' }
    let(:parents) { 'parents' }
    let(:orphans) { 'orphans' }
    let(:relations_presenter) { instance_double(RelationsPresenter, to_hash: relations_hash) }
    let(:relations_hash) { { 'relationship_key' => 'relationship_value' } }
    let(:user) { VCAP::CloudController::User.make }

    describe '#entity_hash' do
      before do
        set_current_user_as_admin
        allow(RelationsPresenter).to receive(:new).and_return(relations_presenter)
      end

      let(:space) { VCAP::CloudController::Space.make }
      let(:stack) { VCAP::CloudController::Stack.make }
      let(:app) do
        a = VCAP::CloudController::AppFactory.make(
          name:                       'app-name',
          production:                 false,
          space:                      space,
          stack:                      stack,
          detected_buildpack:         'detected-buildpack',
          environment_json:           { 'key' => 'val' },
          memory:                     500,
          instances:                  2,
          disk_quota:                 2000,
          command:                    'start command',
          console:                    false,
          staging_task_id:            'staging-id',
          health_check_type:          'port',
          health_check_timeout:       50,
          diego:                      true,
          docker_image:               nil,
          enable_ssh:                 true,
          docker_credentials_json:    nil,
          ports:                      [1234, 5678],
          package_hash:               'asdf'
        )
        a.app.lifecycle_data.update(buildpack: 'http://some-buildpack.io')
        a.update(
          package_state:              'STAGED',
          staging_failed_reason:      'StagerError',
          staging_failed_description: 'staging-failed-description',
        )
        a
      end

      before do
        app.current_droplet.update(detected_start_command: 'detected-start-command')
      end

      it 'returns the app entity and associated urls' do
        expect(subject.entity_hash(controller, app, opts, depth, parents, orphans)).to eq(
          {
            'name'                       => 'app-name',
            'production'                 => false,
            'space_guid'                 => space.guid,
            'stack_guid'                 => stack.guid,
            'buildpack'                  => 'http://some-buildpack.io',
            'detected_buildpack'         => 'detected-buildpack',
            'environment_json'           => { 'key' => 'val' },
            'memory'                     => 500,
            'instances'                  => 2,
            'disk_quota'                 => 2000,
            'state'                      => 'STOPPED',
            'command'                    => 'start command',
            'console'                    => false,
            'debug'                      => nil,
            'staging_task_id'            => 'staging-id',
            'package_state'              => 'STAGED',
            'health_check_type'          => 'port',
            'health_check_timeout'       => 50,
            'staging_failed_reason'      => 'StagerError',
            'staging_failed_description' => 'staging-failed-description',
            'diego'                      => true,
            'docker_image'               => nil,
            'package_updated_at'         => app.package_updated_at,
            'detected_start_command'     => 'detected-start-command',
            'enable_ssh'                 => true,
            'docker_credentials_json'    => { 'redacted_message' => '[PRIVATE DATA HIDDEN]' },
            'ports'                      => [1234, 5678],
            'version'                    => app.version,
            'relationship_key'           => 'relationship_value'
          }
        )

        expect(relations_presenter).to have_received(:to_hash).with(controller, app, opts, depth, parents, orphans)
      end

      describe 'censoring' do
        before do
          set_current_user(user)
        end

        it 'censors docker_credentials_json, environment_json' do
          expect(subject.entity_hash(controller, app, opts, depth, parents, orphans)).to include(
            {
              'environment_json'           => { 'redacted_message' => '[PRIVATE DATA HIDDEN]' },
              'docker_credentials_json'    => { 'redacted_message' => '[PRIVATE DATA HIDDEN]' },
            }
          )
        end

        context 'when the user is an admin' do
          before do
            set_current_user_as_admin
          end

          it 'only censors docker_credentials_json' do
            expect(subject.entity_hash(controller, app, opts, depth, parents, orphans)).to include(
              {
                'environment_json'           => { 'key' => 'val' },
                'docker_credentials_json'    => { 'redacted_message' => '[PRIVATE DATA HIDDEN]' },
              }
            )
          end
        end

        context 'when the user is a space developer' do
          before do
            app.organization.add_user(user)
            app.space.add_developer(user)
          end

          it 'only censors docker_credentials_json' do
            expect(subject.entity_hash(controller, app, opts, depth, parents, orphans)).to include(
              {
                'environment_json'           => { 'key' => 'val' },
                'docker_credentials_json'    => { 'redacted_message' => '[PRIVATE DATA HIDDEN]' },
              }
            )
          end
        end
      end
    end
  end
end
