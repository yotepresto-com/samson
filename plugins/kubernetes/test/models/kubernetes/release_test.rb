# frozen_string_literal: true
require_relative '../../test_helper'

SingleCov.covered!

describe Kubernetes::Release do
  let(:build)  { builds(:docker_build) }
  let(:user)   { users(:deployer) }
  let(:release) do
    Kubernetes::Release.new(
      user: user,
      project: project,
      git_sha: build.git_sha,
      git_ref: 'master',
      deploy: deploys(:succeeded_test)
    )
  end
  let(:deploy_group) { deploy_groups(:pod1) }
  let(:project) { projects(:test) }
  let(:app_server) { kubernetes_roles(:app_server) }
  let(:resque_worker) { kubernetes_roles(:resque_worker) }
  let(:role_config_file) { read_kubernetes_sample_file('kubernetes_deployment.yml') }

  describe 'validations' do
    it 'is valid by default' do
      assert_valid(release)
    end
  end

  describe "#user" do
    it "is normal user when findable" do
      release.user.class.must_equal User
    end

    it "is NullUser when user was deleted so we can still display the user" do
      release.user_id = 1234
      release.user.class.must_equal NullUser
    end
  end

  describe '#create_release' do
    def assert_create_fails(&block)
      refute_difference 'Kubernetes::Release.count' do
        assert_raises Samson::Hooks::UserError, KeyError, &block
      end
    end

    def assert_create_succeeds(params)
      release = nil
      assert_difference 'Kubernetes::Release.count', +1 do
        release = Kubernetes::Release.create_release(params)
      end
      release
    end

    before { Kubernetes::TemplateFiller.any_instance.stubs(:set_image_pull_secrets) }

    it 'creates with 1 role' do
      expect_file_contents_from_repo
      release = assert_create_succeeds(release_params)
      release.release_docs.count.must_equal 1
      release.release_docs.first.kubernetes_role.id.must_equal app_server.id
      release.release_docs.first.kubernetes_role.name.must_equal app_server.name
    end

    it 'creates with multiple roles' do
      2.times { expect_file_contents_from_repo }
      release = assert_create_succeeds(multiple_roles_release_params)
      release.release_docs.count.must_equal 2
      release.release_docs.first.kubernetes_role.name.must_equal app_server.name
      release.release_docs.first.replica_target.must_equal 1
      release.release_docs.first.limits_cpu.must_equal 1
      release.release_docs.first.limits_memory.must_equal 50
      release.release_docs.second.kubernetes_role.name.must_equal resque_worker.name
      release.release_docs.second.replica_target.must_equal 2
      release.release_docs.second.limits_cpu.must_equal 2
      release.release_docs.second.limits_memory.must_equal 100
    end

    it "fails to save with missing deploy groups" do
      assert_create_fails do
        Kubernetes::Release.create_release(release_params.except(:deploy_groups))
      end
    end

    it "fails to save with empty deploy groups" do
      assert_create_fails do
        Kubernetes::Release.create_release(release_params.tap { |params| params[:deploy_groups].clear })
      end
    end

    it "fails to save with missing roles" do
      assert_create_fails do
        params = release_params.tap { |params| params[:deploy_groups].each { |dg| dg.delete(:roles) } }
        Kubernetes::Release.create_release(params)
      end
    end

    it "fails to save with empty roles" do
      assert_create_fails do
        params = release_params.tap { |params| params[:deploy_groups].each { |dg| dg[:roles].clear } }
        Kubernetes::Release.create_release(params)
      end
    end

    describe "blue green" do
      before { release.deploy.stage.blue_green = true }

      it 'creates first as blue' do
        expect_file_contents_from_repo
        assert_create_succeeds(release_params).blue_phase.must_equal true
      end

      it 'creates followup as green' do
        expect_file_contents_from_repo
        release.blue_phase = true
        Kubernetes::Release.any_instance.expects(:previous_successful_release).returns(release)
        assert_create_succeeds(release_params).blue_phase.must_equal false
      end
    end
  end

  describe "#clients" do
    it "is empty when there are no deploy groups" do
      release.clients.must_equal []
    end

    it "returns scoped queries" do
      release = kubernetes_releases(:test_release)
      stub_request(:get, %r{namespaces/pod1/pods\?labelSelector=release_id=\d+,deploy_group_id=\d+}).to_return(body: {
        resourceVersion: "1",
        items: [{}, {}]
      }.to_json)
      release.clients.map { |c, q| c.get_pods(q) }.first.size.must_equal 2
    end

    it "can scope queries by resource namespace" do
      release = kubernetes_releases(:test_release)
      Kubernetes::Resource::Deployment.any_instance.stubs(namespace: "default")
      stub_request(:get, %r{http://foobar.server/api/v1/namespaces/default/pods}).to_return(body: {
        resourceVersion: "1",
        items: [{}, {}]
      }.to_json)
      release.clients.map { |c, q| c.get_pods(q) }.first.size.must_equal 2
    end

    it "scoped statefulset for previous release since they do not update their labels when using patch" do
      resource = {spec: {template: {metadata: {labels: {release_id: 123 }}}}}
      Kubernetes::Resource.expects(:build).returns(stub(
        is_a?: true, patch_replace?: true, resource: resource, namespace: 'pod1'
      ))
      release = kubernetes_releases(:test_release)
      release.clients[0][1].must_equal namespace: "pod1", label_selector: "release_id=123,deploy_group_id=431971589"
    end
  end

  describe ".pod_selector" do
    it "generates a query that selects all pods for this deploy group" do
      Kubernetes::Release.pod_selector(123, deploy_group.id, query: true).must_equal(
        "release_id=123,deploy_group_id=#{deploy_group.id}"
      )
    end

    it "generates raw labels" do
      Kubernetes::Release.pod_selector(123, deploy_group.id, query: false).must_equal(
        release_id: 123,
        deploy_group_id: deploy_group.id
      )
    end
  end

  describe "#url" do
    it "builds" do
      release.id = 123
      release.url.must_equal "http://www.test-url.com/projects/foo/kubernetes/releases/123"
    end
  end

  describe "#builds" do
    it "finds builds accross projects" do
      release.project = nil
      release.builds.must_equal [build]
    end
  end

  describe "#previous_successful_release" do
    before { release.deploy = deploys(:failed_staging_test) }

    it "finds successful release" do
      release.previous_successful_release.must_equal kubernetes_releases(:test_release)
    end

    it "is nil when non was found" do
      deploys(:succeeded_test).delete
      release.previous_successful_release.must_be_nil
    end

    it "is ignores failed releases" do
      deploys(:succeeded_test).job.update_column(:status, 'failed')
      release.previous_successful_release.must_be_nil
    end
  end

  describe "#blue_green_color" do
    it "is false when not using blue_green" do
      refute release.blue_green_color
    end

    describe "when using blue_green" do
      before { release.deploy.stage.blue_green = true }

      it "is blue when in blue phase" do
        release.blue_phase = true
        release.blue_green_color.must_equal 'blue'
      end

      it "is green when not in blue phase" do
        release.blue_phase = false
        release.blue_green_color.must_equal 'green'
      end
    end
  end

  def expect_file_contents_from_repo
    GitRepository.any_instance.expects(:file_content).returns(role_config_file)
  end

  def release_params
    {
      git_sha: build.git_sha,
      git_ref: build.git_ref,
      project: project,
      user: user,
      deploy: deploys(:succeeded_test),
      deploy_groups: [
        {
          deploy_group: deploy_group,
          roles: [
            {
              role: app_server,
              replicas: 1,
              requests_cpu: 0.5,
              requests_memory: 20,
              limits_cpu: 1,
              limits_memory: 50
            }
          ]
        }
      ]
    }
  end

  def multiple_roles_release_params
    release_params.tap do |params|
      params[:deploy_groups].each do |dg|
        dg[:roles].push(
          role: resque_worker,
          replicas: 2,
          limits_cpu: 2,
          limits_memory: 100,
          requests_cpu: 1,
          requests_memory: 50
        )
      end
    end
  end
end
