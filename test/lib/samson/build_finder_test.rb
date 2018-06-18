# frozen_string_literal: true
require_relative "../../test_helper"

SingleCov.covered!

describe Samson::BuildFinder do
  def setup_using_previous_builds
    previous = deploys(:failed_staging_test)
    previous.update_column(:id, job.deploy.id - 1) # make previous_deploy work
    previous_sha = 'something-else'
    previous.job.update_column(:commit, previous_sha)
    kubernetes_releases(:test_release).update_columns(deploy_id: previous.id, git_sha: previous_sha) # previous deploy
    build.update_columns(docker_repo_digest: 'ababababab', git_sha: previous_sha) # make build succeeded
    job.deploy.update_column(:kubernetes_reuse_build, true)
  end

  def expect_sleep
    finder.unstub(:sleep)
    finder.expects(:sleep)
  end

  let(:output) { StringIO.new }
  let(:out) { output.string }
  let(:build) { builds(:docker_build) }
  let(:job) { jobs(:succeeded_test) }
  let(:build_selectors) { nil }
  let(:finder) { Samson::BuildFinder.new(output, job, 'master', build_selectors: build_selectors) }
  let(:project) { build.project }

  before do
    expect_sleep.with { raise "Unexpected sleep" }.never
    build.update_column(:docker_repo_digest, nil) # building needs to happen
    job.update_column(:commit, build.git_sha) # this is normally done by JobExecution
    GitRepository.any_instance.stubs(:file_content).with('Dockerfile', job.commit).returns "FROM all"
  end

  describe "#ensure_successful_builds" do
    def execute
      finder.ensure_successful_builds
    end

    it "fails when the build is not built" do
      e = assert_raises(Samson::Hooks::UserError) { execute }
      e.message.must_equal "Build #{build.url} was created but never ran, run it."
      out.wont_include "Creating Build"
    end

    it "fails to build when dockerfile is missing" do
      Build.delete_all
      job.project.update_column :dockerfiles, 'Dockerfile'
      GitRepository.any_instance.expects(:file_content).with('Dockerfile', job.commit).returns nil

      refute_difference 'Build.count' do
        e = assert_raises(Samson::Hooks::UserError) { execute }
        e.message.must_include "Could not create build for Dockerfile"
      end
    end

    it "waits when build is active" do
      expect_sleep
      done = false
      build.class.any_instance.expects(:active?).times(2).with do
        build.class.any_instance.stubs(:docker_repo_digest).returns('some-digest') unless done
        done = true
      end.returns(true, false)

      assert execute.any?

      out.must_include "Waiting for Build #{build.url} to finish."
    end

    it "stop wait when deploy is cancelled by user" do
      finder.cancelled!
      build.class.any_instance.expects(:active?).returns true

      finder.expects(:sleep).never

      assert execute.any?
    end

    it "continue wait until build became active" do
      expect_sleep.times(2)
      done = false
      build.class.any_instance.expects(:active?).times(3).with do
        build.class.any_instance.stubs(:docker_repo_digest).returns('some-digest') unless done
        done = true
      end.returns(true, true, false)

      assert execute.any?

      out.must_include "Waiting for Build #{build.url} to finish."
    end

    it "fails when build job failed" do
      build.create_docker_job.update_column(:status, 'cancelled')
      build.save!
      e = assert_raises Samson::Hooks::UserError do
        execute
      end
      e.message.must_equal "Build #{build.url} is cancelled, rerun it."
      out.wont_include "Creating Build"
    end

    it "fails when plugin checks fail" do
      build.update_column :docker_repo_digest, 'foo'
      Samson::Hooks.with_callback(:ensure_build_is_successful, ->(*) { false }) do
        e = assert_raises Samson::Hooks::UserError do
          execute
        end
        e.message.must_equal "Plugin build checks for #{build.url} failed."
        out.wont_include "Creating Build"
      end
    end

    describe "when build needs to be created" do
      let(:build_selectors) { [["Dockerfile", nil]] }

      before do
        build.update_column(:git_sha, 'something-else')
        Build.any_instance.stubs(:validate_git_reference)
      end

      it "retries finding when build is created through parallel execution of build" do
        job.project.docker_release_branch = 'master' # indicates that there will be a build kicked off on merge
        expect_sleep.with do
          build.update_column(:git_sha, job.commit)
          build.update_column(:docker_repo_digest, 'somet-digest') # a bit misleading since it should be running
        end
        DockerBuilderService.any_instance.expects(:run).never
        assert execute.any?
        out.must_include "Build #{build.url} is looking good!"
      end

      it "succeeds when the build works" do
        job.project.update_column(:dockerfiles, 'Dockerfile')
        DockerBuilderService.expects(:new).with do |build|
          build.create_docker_job.update_column(:status, 'succeeded')
          build.update_column(:docker_repo_digest, 'some-sha')
          build.expects(:reload).never # instance is not shared with BuildFinder to avoid both modifying the same
          true
        end.returns(stub(run: true))
        assert execute.any?
        out.must_include "Creating build for Dockerfile."
        out.must_include "Build #{Build.last.url} is looking good"
      end

      it "raise when image building disabled" do
        # detect_build_by_selector itself will raise with image building disabled
        # should never return nil
        Samson::BuildFinder.stubs(:detect_build_by_selector!).returns(nil)
        job.project.update_column(:dockerfiles, nil)
        job.project.update_column(:docker_image_building_disabled, true)
        with_env(EXTERNAL_BUILD_WAIT: "0") do
          assert_raises { execute }
        end
      end

      it "reuses build when told to do so" do
        setup_using_previous_builds

        DockerBuilderService.any_instance.expects(:run).never

        assert execute.any?
        out.must_include "Build #{build.url} is looking good"
      end

      it "fails when the build fails" do
        job.project.update_column :dockerfiles, 'Dockerfile'
        DockerBuilderService.any_instance.expects(:run).with do
          Build.any_instance.expects(:docker_build_job).at_least_once.returns Job.new(status: 'cancelled')
          true
        end
        e = assert_raises Samson::Hooks::UserError do
          execute
        end
        e.message.must_equal "Build #{Build.last.url} is cancelled, rerun it."
        out.must_include "Creating build for Dockerfile."
      end

      it "stops when deploy is cancelled by user" do
        job.project.update_column :dockerfiles, 'Dockerfile'
        finder.cancelled!
        DockerBuilderService.any_instance.expects(:run).returns(true)
        execute
        out.scan(/.*build for.*/).must_equal(["Creating build for Dockerfile."])
      end
    end

    describe "when finding builds via image_name" do
      let(:build_selectors) { [[nil, "foo.com/foo/bar:latest"]] }

      before do
        build.update_columns(image_name: 'bar', docker_repo_digest: "some-digest")
        job.project.update_column(:docker_image_building_disabled, true) # only ever used when builds are external
      end

      it "finds the matching build" do
        execute.must_equal [build]
      end

      it "raise with missing dockerfile" do
        # detect_build_by_selector itself will raise without dockerfile
        # should never return nil
        Samson::BuildFinder.stubs(:detect_build_by_selector!).returns(nil)
        with_env(EXTERNAL_BUILD_WAIT: "0") do
          assert_raises { execute }
        end
      end

      it "does not find for different sha" do
        build.update_column(:git_sha, 'other')
        expect_sleep # waiting for external builds to arrive
        e = assert_raises(Samson::Hooks::UserError) { execute }
        e.message.must_include("Did not find build")
      end

      it "can find build that arrives late" do
        matching_sha = build.git_sha
        build.update_column(:git_sha, 'other')
        # waiting for external builds to arrive
        expect_sleep.with do
          build.update_column(:git_sha, matching_sha)
        end
        execute.must_equal [build]
      end

      it "finds across projects" do
        build.update_column(:project_id, projects(:other).id)
        execute.must_equal [build]
      end

      it "can reuse previous build" do
        setup_using_previous_builds
        execute.must_equal [build]
      end

      it "can reuse build and skips if there is no previous build" do
        job.deploy.update_column(:kubernetes_reuse_build, true)
        refute job.deploy.previous_deploy
        execute.must_equal [build]
      end

      it "prefers previous builds since that is what the user selected" do
        setup_using_previous_builds
        current = builds(:staging)
        current.update_columns(
          docker_repo_digest: 'ababababab',
          git_sha: job.commit,
          image_name: build.image_name
        )
        execute.must_equal [build]
      end
    end

    describe "when using external builds" do
      with_env EXTERNAL_BUILD_WAIT: '15'
      let!(:matching_sha) { build.git_sha }

      before do
        job.project.update_column(:docker_image_building_disabled, true)
        build.update_columns(git_sha: 'other')
      end

      it "waits for builds to arrive" do
        # waiting for external builds to arrive
        expect_sleep.with do
          build.update_columns(git_sha: matching_sha, docker_repo_digest: 'done')
        end

        execute.must_equal [build]
      end

      it "fails if a build does not arrive" do
        job.project.update_column :dockerfiles, 'foobar'
        expect_sleep.times(3)

        e = assert_raises(Samson::Hooks::UserError) { execute }
        e.message.must_equal(
          "Did not find build for dockerfile \"foobar\" or image_name \"foobar\".\n"\
          "Found builds: [].\nProject builds URL: http://www.test-url.com/projects/foo/builds"
        )
      end

      it "shows found non-match builds when nothing was matching" do
        expect_sleep.times(3).with do
          build.update_columns(git_sha: matching_sha, docker_repo_digest: 'done', dockerfile: "Mooo")
        end

        e = assert_raises(Samson::Hooks::UserError) { execute }
        e.message.must_equal(
          "Did not find build for dockerfile \"Dockerfile\" or image_name \"foo\".\n"\
          "Found builds: [[\"Mooo\"]].\nProject builds URL: http://www.test-url.com/projects/foo/builds"
        )
      end

      it "stops when cancelled" do
        expect_sleep.with { finder.cancelled! }

        execute.must_equal []
      end

      it "does not wait multiple times because builds start simultaneously" do
        expect_sleep.times(3)

        assert_raises(Samson::Hooks::UserError) { execute }
        assert_raises(Samson::Hooks::UserError) { execute }
      end

      it "waits for builds with just image_name" do
        expect_sleep.with do
          build.update_columns(
            git_sha: matching_sha,
            docker_repo_digest: 'done',
            dockerfile: nil,
            image_name: project.permalink
          )
        end

        execute.must_equal [build]
      end

      describe "removes empty image_name from expection" do
        let(:build_selectors) { [["foobar", nil]] }

        it "fails if a build does not arrive" do
          job.project.update_column :dockerfiles, 'foobar'
          expect_sleep.times(3)

          e = assert_raises(Samson::Hooks::UserError) { execute }
          e.message.must_equal(
            "Did not find build for dockerfile \"foobar\".\n"\
            "Found builds: [].\nProject builds URL: http://www.test-url.com/projects/foo/builds"
          )
        end
      end
    end
  end
end
