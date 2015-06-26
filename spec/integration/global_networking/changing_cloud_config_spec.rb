require 'spec_helper'

describe 'Changing cloud config', type: :integration do
  with_reset_sandbox_before_each

  before do
    target_and_login
    create_and_upload_test_release
    upload_stemcell
  end

  describe 'changing the cloud config while deploying' do
    it 'should continue to use the original cloud config' do
      cloud_config = Bosh::Spec::NetworkingManifest.cloud_config(available_ips: 1)
      deployment_manifest = Bosh::Spec::NetworkingManifest.deployment_manifest(instances: 1)

      upload_cloud_config(cloud_config_hash: cloud_config)
      task_id = Bosh::Spec::DeployHelper.start_deploy(deployment_manifest)

      upload_a_different_cloud_config

      Bosh::Spec::DeployHelper.wait_for_deploy_to_succeed(task_id)
    end

    it 'should successfully finish errand' do
      cloud_config = Bosh::Spec::NetworkingManifest.cloud_config(available_ips: 1)
      manifest_with_errand = Bosh::Spec::NetworkingManifest.errand_manifest(instances: 1)
      upload_cloud_config(cloud_config_hash: cloud_config)
      deploy_simple_manifest(manifest_hash: manifest_with_errand)

      errand_succeeded = nil
      errand_thread = Thread.new do
        _, errand_succeeded = run_errand(manifest_with_errand, 'errand_job')
      end

      upload_a_different_cloud_config

      errand_thread.join
      expect(errand_succeeded).to eq(true)
    end
  end

  describe 'changing the cloud config with health monitor running' do
    before { current_sandbox.health_monitor_process.start }
    after { current_sandbox.health_monitor_process.stop }

    it 'resurrects vm with old cloud config' do
      cloud_config = Bosh::Spec::NetworkingManifest.cloud_config(available_ips: 1)
      deployment_manifest = Bosh::Spec::NetworkingManifest.deployment_manifest(instances: 1)

      upload_cloud_config(cloud_config_hash: cloud_config)
      deploy_simple_manifest(manifest_hash: deployment_manifest)

      original_vm = director.vm('foobar/0')

      upload_a_different_cloud_config

      original_vm.kill_agent
      resurrected_vm = director.wait_for_vm('foobar/0', 300)
      expect(resurrected_vm.cid).to_not eq(original_vm.cid)

      expect(original_vm.ips).to eq(resurrected_vm.ips)
    end
  end

  def upload_a_different_cloud_config
    new_cloud_config = Bosh::Spec::NetworkingManifest.cloud_config(available_ips: 0)
    new_cloud_config['networks'].first['name'] = 'other'
    new_cloud_config['resource_pools'].first['network'] = 'other'
    new_cloud_config['compilation']['network'] = 'other'
    upload_cloud_config(cloud_config_hash: new_cloud_config)
  end
end
