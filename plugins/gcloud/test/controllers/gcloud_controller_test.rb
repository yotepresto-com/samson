# frozen_string_literal: true
require_relative '../test_helper'

SingleCov.covered!

describe GcloudController do
  with_env GCLOUD_ACCOUNT: "foo", GCLOUD_PROJECT: "bar"

  as_a_viewer do
    describe "#sync_build" do
      def do_sync
        post :sync_build, params: {id: build.id}
        assert_response :redirect
      end

      let(:build) { builds(:docker_build) }
      let(:gcr_id) { "ee5316fa-5569-aaaa-bbbb-09e0e5b1319a" }
      let(:result) { {results: {images: [{name: "nope", digest: "bar"}, {name: image_name, digest: sha}]}} }
      let(:repo_digest) { "#{image_name}@#{sha}" }
      let(:image_name) { "gcr.io/foo/#{build.image_name}" }
      let(:sha) { "sha256:#{"a" * 64}" }

      before do
        SamsonGcloud.expects(:container_in_beta)
        build.update_column(:external_url, "https://console.cloud.google.com/gcr/builds/#{gcr_id}?project=foobar")
      end

      it "can sync" do
        Samson::CommandExecutor.expects(:execute).returns([true, result.to_json])
        do_sync
        assert flash[:notice]
        build.reload
        build.docker_repo_digest.must_equal repo_digest
        build.external_status.must_equal "succeeded"
      end

      it "fails when gcloud cli fails" do
        Samson::CommandExecutor.expects(:execute).returns([false, result.to_json])
        do_sync
        assert flash[:alert]
      end

      it "fails when image is not found" do
        result[:results][:images].last[:name] = "gcr.io/other"
        Samson::CommandExecutor.expects(:execute).returns([true, result.to_json])
        do_sync
        assert flash[:alert]
      end
    end
  end
end
