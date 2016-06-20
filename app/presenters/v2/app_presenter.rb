require 'presenters/v3/base_presenter'

module CloudController
  module Presenters
    module V2
      class AppPresenter < BasePresenter
        extend PresenterProvider

        REDACTED_HASH_MESSAGE = {
          'redacted_message'.freeze => VCAP::CloudController::Presenters::V3::BasePresenter::REDACTED_MESSAGE
        }.freeze

        present_for_class 'VCAP::CloudController::App'

        attr_accessor :app

        def entity_hash(controller, obj, opts, depth, parents, orphans=nil)
          @app = obj

          entity = {
            'name'                       => app.name,
            'production'                 => app.production,
            'space_guid'                 => app.space.guid,
            'stack_guid'                 => app.stack.guid,
            'buildpack'                  => MultiJson.load(app.buildpack.to_json),
            'detected_buildpack'         => app.detected_buildpack,
            'environment_json'           => redacted_env,
            'memory'                     => app.memory,
            'instances'                  => app.instances,
            'disk_quota'                 => app.disk_quota,
            'state'                      => app.state,
            'version'                    => app.version,
            'command'                    => app.command,
            'console'                    => app.console,
            'debug'                      => app.debug,
            'staging_task_id'            => app.staging_task_id,
            'package_state'              => app.package_state,
            'health_check_type'          => app.health_check_type,
            'health_check_timeout'       => app.health_check_timeout,
            'staging_failed_reason'      => app.staging_failed_reason,
            'staging_failed_description' => app.staging_failed_description,
            'diego'                      => app.diego,
            'docker_image'               => app.docker_image,
            'package_updated_at'         => app.package_updated_at,
            'detected_start_command'     => app.detected_start_command,
            'enable_ssh'                 => app.enable_ssh,
            'docker_credentials_json'    => REDACTED_HASH_MESSAGE,
            'ports'                      => app.ports_with_defaults
          }

          entity.merge!(RelationsPresenter.new.to_hash(controller, obj, opts, depth, parents, orphans))
        end

        private

        def redacted_env
          if VCAP::CloudController::SecurityContext.admin? || app.space.has_developer?(VCAP::CloudController::SecurityContext.current_user)
            app.environment_json
          else
            REDACTED_HASH_MESSAGE
          end
        end
      end
    end
  end
end
