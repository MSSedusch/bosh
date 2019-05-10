require 'spec_helper'
require 'support/release_helper'
require 'digest'

module Bosh::Director
  describe Jobs::UpdateRelease do
    before do
      allow(Bosh::Director::Config).to receive(:verify_multidigest_path).and_return('some/path')
      allow(App).to receive_message_chain(:instance, :blobstores, :blobstore).and_return(blobstore)
    end
    let(:blobstore) { instance_double('Bosh::Blobstore::BaseClient') }
    let(:task) { Models::Task.make(id: 42) }
    let(:task_writer) { Bosh::Director::TaskDBWriter.new(:event_output, task.id) }
    let(:event_log) { Bosh::Director::EventLog::Log.new(task_writer) }

    before do
      allow(Config).to receive(:event_log).and_return(event_log)
    end

    describe 'DJ job class expectations' do
      let(:job_type) { :update_release }
      let(:queue) { :normal }
      it_behaves_like 'a DJ job'
    end

    describe 'Compiled release upload' do
      subject(:job) { Jobs::UpdateRelease.new(release_path, job_options) }

      let(:release_dir) { Test::ReleaseHelper.new.create_release_tarball(manifest) }
      let(:release_path) { File.join(release_dir, 'release.tgz') }
      let(:release_version) { '42+dev.6' }
      let(:release) { Models::Release.make(name: 'appcloud') }

      let(:manifest_jobs) do
        [
          {
            'name' => 'fake-job-1',
            'version' => 'fake-version-1',
            'sha1' => 'fakesha11',
            'fingerprint' => 'fake-fingerprint-1',
            'templates' => {},
          },
          {
            'name' => 'fake-job-2',
            'version' => 'fake-version-2',
            'sha1' => 'fake-sha1-2',
            'fingerprint' => 'fake-fingerprint-2',
            'templates' => {},
          },
        ]
      end
      let(:manifest_compiled_packages) do
        [
          {
            'sha1' => 'fakesha1',
            'fingerprint' => 'fake-fingerprint-1',
            'name' => 'fake-name-1',
            'version' => 'fake-version-1',
          },
          {
            'sha1' => 'fakesha2',
            'fingerprint' => 'fake-fingerprint-2',
            'name' => 'fake-name-2',
            'version' => 'fake-version-2',
          },
        ]
      end
      let(:manifest) do
        {
          'name' => 'appcloud',
          'version' => release_version,
          'jobs' => manifest_jobs,
          'compiled_packages' => manifest_compiled_packages,
        }
      end

      let(:job_options) do
        { 'remote' => false }
      end

      before do
        allow(Dir).to receive(:mktmpdir).and_return(release_dir)
        allow(job).to receive(:with_release_lock).and_yield
        allow(blobstore).to receive(:create)
        allow(job).to receive(:register_package)
      end

      it 'should process packages for compiled release' do
        expect(job).to receive(:create_packages)
        expect(job).to receive(:use_existing_packages)
        expect(job).to receive(:create_compiled_packages)
        expect(job).to receive(:register_template).twice
        expect(job).to receive(:create_job).twice

        job.perform
      end
    end

    describe '#perform' do
      subject(:job) { Jobs::UpdateRelease.new(release_path, job_options) }
      let(:job_options) do
        {}
      end

      let(:release_dir) { Test::ReleaseHelper.new.create_release_tarball(manifest) }
      before { allow(Dir).to receive(:mktmpdir).and_return(release_dir) }

      let(:release_path) { File.join(release_dir, 'release.tgz') }

      let(:manifest) do
        {
          'name' => 'appcloud',
          'version' => release_version,
          'commit_hash' => '12345678',
          'uncommitted_changes' => true,
          'jobs' => manifest_jobs,
          'packages' => manifest_packages,
        }
      end
      let(:release_version) { '42+dev.6' }
      let(:release) { Models::Release.make(name: 'appcloud') }
      let(:manifest_packages) { nil }
      let(:manifest_jobs) { nil }
      let(:status) { instance_double(Process::Status, exitstatus: 0) }

      before do
        allow(Open3).to receive(:capture3).and_return([nil, 'some error', status])
        allow(job).to receive(:with_release_lock).and_yield
      end

      context 'when release is local' do
        let(:job_options) do
          {}
        end

        it 'with a local release' do
          expect(job).not_to receive(:download_remote_release)
          expect(job).to receive(:extract_release)
          expect(job).to receive(:verify_manifest)
          expect(job).to receive(:process_release)
          job.perform
        end
      end

      context 'when release is remote' do
        let(:job_options) do
          { 'remote' => true, 'location' => 'release_location' }
        end

        it 'with a remote release' do
          expect(job).to receive(:download_remote_release)
          expect(job).to receive(:extract_release)
          expect(job).to receive(:verify_manifest)
          expect(job).to receive(:process_release)

          job.perform
        end

        context 'with multiple digests' do
          context 'when the digest matches' do
            let(:job_options) do
              {
                'remote' => true,
                'location' => 'release_location',
                'sha1' => "sha1:#{::Digest::SHA1.file(release_path).hexdigest}",
              }
            end

            it 'verifies that the digest matches the release' do
              allow(job).to receive(:release_path).and_return(release_path)

              expect(job).to receive(:download_remote_release)
              expect(job).to receive(:process_release)

              job.perform
            end
          end

          context 'when the digest does not match' do
            let(:status) { instance_double(Process::Status, exitstatus: 1) }
            let(:job_options) do
              { 'remote' => true, 'location' => 'release_location', 'sha1' => 'sha1:potato' }
            end

            it 'raises an error' do
              allow(job).to receive(:release_path).and_return(release_path)
              expect(job).to receive(:download_remote_release)

              expect do
                job.perform
              end.to raise_exception(Bosh::Director::ReleaseSha1DoesNotMatch, 'some error')
            end
          end
        end
      end

      context 'when commit_hash and uncommitted changes flag are present' do
        let(:manifest) do
          {
            'name' => 'appcloud',
            'version' => '42.6-dev',
            'commit_hash' => '12345678',
            'uncommitted_changes' => 'true',
            'jobs' => [],
            'packages' => [],
          }
        end

        it 'sets commit_hash and uncommitted changes flag on release_version' do
          job.perform

          rv = Models::ReleaseVersion.filter(version: '42+dev.6').first
          expect(rv).not_to be_nil
          expect(rv.commit_hash).to eq('12345678')
          expect(rv.uncommitted_changes).to be(true)
        end
      end

      context 'when commit_hash and uncommitted_changes flag are missing' do
        let(:manifest) do
          {
            'name' => 'appcloud',
            'version' => '42.6-dev',
            'jobs' => [],
            'packages' => [],
          }
        end

        it 'sets default commit_hash and uncommitted changes' do
          job.perform

          rv = Models::ReleaseVersion.filter(version: '42+dev.6').first
          expect(rv).not_to be_nil
          expect(rv.commit_hash).to eq('unknown')
          expect(rv.uncommitted_changes).to be(false)
        end
      end

      context 'when extracting release fails' do
        before do
          result = Bosh::Exec::Result.new('cmd', 'output', 1)
          expect(Bosh::Exec).to receive(:sh).and_return(result)
        end

        it 'raises an error' do
          expect do
            job.perform
          end.to raise_exception(Bosh::Director::ReleaseInvalidArchive)
        end

        it 'deletes release archive and the release dir' do
          expect(FileUtils).to receive(:rm_rf).with(release_dir)
          expect(FileUtils).to receive(:rm_rf).with(release_path)

          expect do
            job.perform
          end.to raise_exception(Bosh::Director::ReleaseInvalidArchive)
        end
      end

      it 'saves release version and sets update_completed flag' do
        job.perform

        rv = Models::ReleaseVersion.filter(version: '42+dev.6').first
        expect(rv.update_completed).to be(true)
      end

      it 'resolves package dependencies' do
        expect(job).to receive(:resolve_package_dependencies)
        job.perform
      end

      it 'deletes release archive and extraction directory' do
        expect(FileUtils).to receive(:rm_rf).with(release_dir)
        expect(FileUtils).to receive(:rm_rf).with(release_path)

        job.perform
      end

      context 'release already exists' do
        before { Models::ReleaseVersion.make(release: release, version: '42+dev.6', commit_hash: '12345678', uncommitted_changes: true) }

        context 'when rebase is passed' do
          let(:job_options) do
            { 'rebase' => true }
          end

          context 'when there are package changes' do
            let(:manifest_packages) do
              [
                {
                  'sha1' => 'fakesha1',
                  'fingerprint' => 'fake-fingerprint-1',
                  'name' => 'fake-name-1',
                  'version' => 'fake-version-1',
                },
              ]
            end

            it 'sets a next release version' do
              expect(job).to receive(:create_package)
              expect(job).to receive(:register_package)
              job.perform

              rv = Models::ReleaseVersion.filter(version: '42+dev.7').first
              expect(rv).to_not be_nil
            end
          end

          context 'when there are no job and package changes' do
            it 'still can pass and set a next release version' do
              # it just generate the next release version without creating/registering package
              expect do
                job.perform
              end.to_not raise_error

              rv = Models::ReleaseVersion.filter(version: '42+dev.7').first
              expect(rv).to_not be_nil
            end
          end
        end

        context 'when skip_if_exists is passed' do
          let(:job_options) do
            { 'skip_if_exists' => true }
          end

          it 'does not create a release' do
            expect(job).not_to receive(:create_package)
            expect(job).not_to receive(:create_job)
            job.perform
          end
        end
      end

      context 'when the same release is uploaded with different commit hash' do
        let!(:previous_release_version) do
          Models::ReleaseVersion.make(release: release, version: '42+dev.6', commit_hash: 'bad123', uncommitted_changes: true)
        end

        it 'fails with a ReleaseVersionCommitHashMismatch exception' do
          expect do
            job.perform
          end.to raise_exception(Bosh::Director::ReleaseVersionCommitHashMismatch, /#{previous_release_version.commit_hash}/)
        end
      end

      context 'when the release version does not match database valid format' do
        before do
          # We only want to verify that the proper error is raised
          # If version can not be validated because it has wrong model format
          # Currently SemiSemantic Version validates version that matches the model format
          stub_const('Bosh::Director::Models::VALID_ID', /^[a-z0-9]+$/i)
        end

        let(:release_version) { 'bad-version' }

        it 'raises an error ReleaseVersionInvalid' do
          expect do
            job.perform
          end.to raise_error(Sequel::ValidationFailed)
        end
      end

      context 'when there are packages in manifest' do
        let(:manifest_packages) do
          [
            {
              'sha1' => 'fakesha1',
              'fingerprint' => 'fake-fingerprint-1',
              'name' => 'fake-name-1',
              'version' => 'fake-version-1',
            },
            {
              'sha1' => 'fakesha2',
              'fingerprint' => 'fake-fingerprint-2',
              'name' => 'fake-name-2',
              'version' => 'fake-version-2',
            },
          ]
        end

        before do
          Models::Package.make(release: release, name: 'fake-name-1', version: 'fake-version-1', fingerprint: 'fake-fingerprint-1')
        end

        it "creates packages that don't already exist" do
          expect(job).to receive(:create_packages).with([
                                                          {
                                                            'sha1' => 'fakesha2',
                                                            'fingerprint' => 'fake-fingerprint-2',
                                                            'name' => 'fake-name-2',
                                                            'version' => 'fake-version-2',
                                                            'dependencies' => [],
                                                            'compiled_package_sha1' => 'fakesha2',
                                                          },
                                                        ], release_dir)
          job.perform
        end

        it 'raises an error if a different fingerprint was detected for an already existing package' do
          pkg = Models::Package.make(release: release, name: 'fake-name-2', version: 'fake-version-2', fingerprint: 'different-finger-print', sha1: 'fakesha2')
          release_version = Models::ReleaseVersion.make(release: release, version: '42+dev.6', commit_hash: '12345678', uncommitted_changes: true)
          release_version.add_package(pkg)

          allow(job).to receive(:create_packages)

          expect do
            job.perform
          end.to raise_exception(
            Bosh::Director::ReleaseInvalidPackage,
            %r{package 'fake-name-2' had different fingerprint in previously uploaded release 'appcloud\/42\+dev.6'},
          )
        end
      end

      context 'when manifest contains jobs' do
        let(:manifest_jobs) do
          [
            {
              'name' => 'fake-job-1',
              'version' => 'fake-version-1',
              'sha1' => 'fakesha11',
              'fingerprint' => 'fake-fingerprint-1',
              'templates' => {},
            },
            {
              'name' => 'fake-job-2',
              'version' => 'fake-version-2',
              'sha1' => 'fake-sha1-2',
              'fingerprint' => 'fake-fingerprint-2',
              'templates' => {},
            },
          ]
        end

        it 'creates job' do
          expect(blobstore).to receive(:create) do |file|
            expect(file.path).to eq(File.join(release_dir, 'jobs', 'fake-job-1.tgz'))
          end

          expect(blobstore).to receive(:create) do |file|
            expect(file.path).to eq(File.join(release_dir, 'jobs', 'fake-job-2.tgz'))
          end

          job.perform

          expect(Models::Template.all.size).to eq(2)
          expect(Models::Template.all.map(&:name)).to match_array(['fake-job-1', 'fake-job-2'])
        end

        it 'raises an error if a different fingerprint was detected for an already existing job' do
          corrupted_job = Models::Template.make(
            release: release,
            name: 'fake-job-1',
            version: 'fake-version-1',
            fingerprint: 'different-finger-print',
            sha1: 'fakesha11',
          )
          release_version = Models::ReleaseVersion.make(
            release: release,
            version: '42+dev.6',
            commit_hash: '12345678',
            uncommitted_changes: true,
          )
          release_version.add_template(corrupted_job)

          allow(job).to receive(:process_packages)

          expect do
            job.perform
          end.to raise_exception(
            Bosh::Director::ReleaseExistingJobFingerprintMismatch,
            %r{job 'fake-job-1' had different fingerprint in previously uploaded release 'appcloud\/42\+dev.6'},
          )
        end

        it "creates jobs that don't already exist" do
          Models::Template.make(
            release: release,
            name: 'fake-job-1',
            version: 'fake-version-1',
            fingerprint: 'fake-fingerprint-1',
          )
          expect(job).to receive(:create_jobs).with([
                                                      {
                                                        'sha1' => 'fake-sha1-2',
                                                        'fingerprint' => 'fake-fingerprint-2',
                                                        'name' => 'fake-job-2',
                                                        'version' => 'fake-version-2',
                                                        'templates' => {},
                                                      },
                                                    ], release_dir)
          job.perform
        end

        context 'when the release contains no packages' do
          before do
            manifest.delete('packages')
          end
          it 'should not error' do
            allow(job).to receive(:create_jobs)
            expect { job.perform }.to_not raise_error
          end
        end
      end

      context 'when manifest contains packages and jobs' do
        let(:manifest_jobs) do
          [
            {
              'name' => 'zbz',
              'version' => '666',
              'templates' => {},
              'packages' => %w[zbb],
              'fingerprint' => 'job-fingerprint-3',
            },
          ]
        end
        let(:manifest_packages) do
          [
            {
              'name' => 'foo',
              'version' => '2.33-dev',
              'dependencies' => %w[bar],
              'fingerprint' => 'package-fingerprint-1',
              'sha1' => 'packagesha11',
            },
            {
              'name' => 'bar',
              'version' => '3.14-dev',
              'dependencies' => [],
              'fingerprint' => 'package-fingerprint-2',
              'sha1' => 'packagesha12',
            },
            {
              'name' => 'zbb',
              'version' => '333',
              'dependencies' => [],
              'fingerprint' => 'package-fingerprint-3',
              'sha1' => 'packagesha13',
            },
          ]
        end

        it 'process packages should include all packages from the manifest in the packages array, even previously existing ones' do
          pkg_foo = Models::Package.make(release: release, name: 'foo', version: '2.33-dev',
                                         fingerprint: 'package-fingerprint-1', sha1: 'packagesha11',
                                         blobstore_id: 'bs1')
          pkg_bar = Models::Package.make(release: release, name: 'bar', version: '3.14-dev',
                                         fingerprint: 'package-fingerprint-2', sha1: 'packagesha12',
                                         blobstore_id: 'bs2')
          pkg_zbb = Models::Package.make(release: release, name: 'zbb', version: '333',
                                         fingerprint: 'package-fingerprint-3', sha1: 'packagesha13',
                                         blobstore_id: 'bs3')
          release_version = Models::ReleaseVersion.make(release: release, version: '42+dev.6', commit_hash: '12345678',
                                                        uncommitted_changes: true, update_completed: true)
          release_version.add_package(pkg_foo)
          release_version.add_package(pkg_bar)
          release_version.add_package(pkg_zbb)

          expect(BlobUtil).to receive(:create_blob).and_return('blob_id')
          allow(blobstore).to receive(:create)

          job.perform
        end
      end
    end

    describe 'rebasing release' do
      let(:manifest) do
        {
          'name' => 'appcloud',
          'version' => '42.6-dev',
          'jobs' => [
            {
              'name' => 'baz',
              'version' => '33',
              'templates' => {
                'bin/test.erb' => 'bin/test',
                'config/zb.yml.erb' => 'config/zb.yml',
              },
              'packages' => %w[foo bar],
              'fingerprint' => 'job-fingerprint-1',
            },
            {
              'name' => 'zaz',
              'version' => '0.2-dev',
              'templates' => {},
              'packages' => %w[bar],
              'fingerprint' => 'job-fingerprint-2',
            },
            {
              'name' => 'zbz',
              'version' => '666',
              'templates' => {},
              'packages' => %w[zbb],
              'fingerprint' => 'job-fingerprint-3',
            },
          ],
          'packages' => [
            {
              'name' => 'foo',
              'version' => '2.33-dev',
              'dependencies' => %w[bar],
              'fingerprint' => 'package-fingerprint-1',
              'sha1' => 'packagesha11',
            },
            {
              'name' => 'bar',
              'version' => '3.14-dev',
              'dependencies' => [],
              'fingerprint' => 'package-fingerprint-2',
              'sha1' => 'packagesha12',
            },
            {
              'name' => 'zbb',
              'version' => '333',
              'dependencies' => [],
              'fingerprint' => 'package-fingerprint-3',
              'sha1' => 'packagesha13',
            },
          ],
        }
      end

      before do
        @release_dir = Test::ReleaseHelper.new.create_release_tarball(manifest)
        @release_path = File.join(@release_dir, 'release.tgz')

        @job = Jobs::UpdateRelease.new(@release_path, 'rebase' => true)

        @release = Models::Release.make(name: 'appcloud')
        @rv = Models::ReleaseVersion.make(release: @release, version: '37')

        Models::Package.make(release: @release, name: 'foo', version: '2.7-dev')
        Models::Package.make(release: @release, name: 'bar', version: '42')

        Models::Template.make(release: @release, name: 'baz', version: '33.7-dev')
        Models::Template.make(release: @release, name: 'zaz', version: '17')

        # create up to 6 new blobs (3*job + 3*package)
        allow(blobstore).to receive(:create).at_most(6).and_return('b1', 'b2', 'b3', 'b4', 'b5', 'b6')
        # get is only called when a blob is copied
        allow(blobstore).to receive(:get)
        allow(@job).to receive(:with_release_lock).with('appcloud').and_yield
      end

      it 'rebases the release version' do
        @job.perform

        # No previous release exists with the same release version (42).
        # So the default dev post-release version is used (semi-semantic format).
        rv = Models::ReleaseVersion.filter(release_id: @release.id, version: '42+dev.1').first

        expect(rv).to_not be_nil
      end

      context 'when the package fingerprint matches one in the database' do
        before do
          Models::Package.make(
            release: @release,
            name: 'zbb',
            version: '25',
            fingerprint: 'package-fingerprint-3',
            sha1: 'packagesha1old',
          )
        end

        it 'creates new package (version) with copied blob (sha1)' do
          expect(blobstore).to receive(:create).exactly(6).times # creates new blobs for each package & job
          expect(blobstore).to receive(:get).exactly(1).times # copies the existing 'zbb' package
          @job.perform

          zbbs = Models::Package.filter(release_id: @release.id, name: 'zbb').all
          expect(zbbs.map(&:version)).to match_array(%w[25 333])

          # Fingerprints are the same because package contents did not change
          expect(zbbs.map(&:fingerprint)).to match_array(%w[package-fingerprint-3 package-fingerprint-3])

          # SHA1s are the same because first blob was copied
          expect(zbbs.map(&:sha1)).to match_array(%w[packagesha1old packagesha1old])
        end

        it 'associates newly created packages to the release version' do
          @job.perform

          rv = Models::ReleaseVersion.filter(release_id: @release.id, version: '42+dev.1').first
          expect(rv.packages.map(&:version)).to match_array(%w[2.33-dev 3.14-dev 333])
          expect(rv.packages.map(&:fingerprint)).to match_array(
            %w[package-fingerprint-1 package-fingerprint-2 package-fingerprint-3],
          )
          expect(rv.packages.map(&:sha1)).to match_array(%w[packagesha11 packagesha12 packagesha1old])
        end
      end

      context 'when the package fingerprint matches multiple in the database' do
        before do
          Models::Package.make(release: @release, name: 'zbb', version: '25', fingerprint: 'package-fingerprint-3', sha1: 'packagesha125')
          Models::Package.make(release: @release, name: 'zbb', version: '26', fingerprint: 'package-fingerprint-3', sha1: 'packagesha126')
        end

        it 'creates new package (version) with copied blob (sha1)' do
          expect(blobstore).to receive(:create).exactly(6).times # creates new blobs for each package & job
          expect(blobstore).to receive(:get).exactly(1).times # copies the existing 'zbb' package
          @job.perform

          zbbs = Models::Package.filter(release_id: @release.id, name: 'zbb').all
          expect(zbbs.map(&:version)).to match_array(%w[26 25 333])

          # Fingerprints are the same because package contents did not change
          expect(zbbs.map(&:fingerprint)).to match_array(%w[package-fingerprint-3 package-fingerprint-3 package-fingerprint-3])

          # SHA1s are the same because first blob was copied
          expect(zbbs.map(&:sha1)).to match_array(%w[packagesha125 packagesha125 packagesha126])
        end

        it 'associates newly created packages to the release version' do
          @job.perform

          rv = Models::ReleaseVersion.filter(release_id: @release.id, version: '42+dev.1').first
          expect(rv.packages.map(&:version)).to match_array(%w[2.33-dev 3.14-dev 333])
          expect(rv.packages.map(&:fingerprint)).to match_array(
            %w[package-fingerprint-1 package-fingerprint-2 package-fingerprint-3],
          )
          expect(rv.packages.map(&:sha1)).to match_array(%w[packagesha11 packagesha12 packagesha125])
        end
      end

      context 'when the package fingerprint is new' do
        before do
          Models::Package.make(release: @release, name: 'zbb', version: '25', fingerprint: 'package-fingerprint-old', sha1: 'packagesha125')
        end

        it 'creates new package (version) with new blob (sha1)' do
          expect(blobstore).to receive(:create).exactly(6).times # creates new blobs for each package & job
          expect(blobstore).to receive(:get).exactly(0).times # does not copy any existing packages or jobs
          @job.perform

          zbbs = Models::Package.filter(release_id: @release.id, name: 'zbb').all
          expect(zbbs.map(&:version)).to match_array(%w[25 333])

          # Fingerprints are different because package contents are different
          expect(zbbs.map(&:fingerprint)).to match_array(%w[package-fingerprint-old package-fingerprint-3])

          # SHA1s are different because package tars are different
          expect(zbbs.map(&:sha1)).to match_array(%w[packagesha125 packagesha13])
        end

        it 'associates newly created packages to the release version' do
          @job.perform

          rv = Models::ReleaseVersion.filter(release_id: @release.id, version: '42+dev.1').first
          expect(rv.packages.map(&:version)).to match_array(%w[2.33-dev 3.14-dev 333])
          expect(rv.packages.map(&:fingerprint)).to match_array(
            %w[package-fingerprint-1 package-fingerprint-2 package-fingerprint-3],
          )
          expect(rv.packages.map(&:sha1)).to match_array(%w[packagesha11 packagesha12 packagesha13])
        end
      end

      context 'when the job fingerprint matches one in the database' do
        before do
          Models::Template.make(release: @release, name: 'zbz', version: '28', fingerprint: 'job-fingerprint-3')
        end

        it 'uses the new job blob' do
          expect(blobstore).to receive(:create).exactly(6).times # creates new blobs for each package & job
          expect(blobstore).to receive(:get).exactly(0).times # does not copy any existing packages or jobs
          @job.perform

          zbzs = Models::Template.filter(release_id: @release.id, name: 'zbz').all
          expect(zbzs.map(&:version)).to match_array(%w[28 666])
          expect(zbzs.map(&:fingerprint)).to match_array(%w[job-fingerprint-3 job-fingerprint-3])

          rv = Models::ReleaseVersion.filter(release_id: @release.id, version: '42+dev.1').first
          expect(rv.templates.map(&:fingerprint)).to match_array(%w[job-fingerprint-1 job-fingerprint-2 job-fingerprint-3])
        end
      end

      context 'when the job fingerprint is new' do
        before do
          Models::Template.make(release: @release, name: 'zbz', version: '28', fingerprint: 'job-fingerprint-old')
        end

        it 'uses the new job blob' do
          expect(blobstore).to receive(:create).exactly(6).times # creates new blobs for each package & job
          expect(blobstore).to receive(:get).exactly(0).times # does not copy any existing packages or jobs
          @job.perform

          zbzs = Models::Template.filter(release_id: @release.id, name: 'zbz').all
          expect(zbzs.map(&:version)).to match_array(%w[28 666])
          expect(zbzs.map(&:fingerprint)).to match_array(%w[job-fingerprint-old job-fingerprint-3])

          rv = Models::ReleaseVersion.filter(release_id: @release.id, version: '42+dev.1').first
          expect(rv.templates.map(&:fingerprint)).to match_array(%w[job-fingerprint-1 job-fingerprint-2 job-fingerprint-3])
        end
      end

      it 'uses major+dev.1 version for initial rebase if no version exists' do
        @rv.destroy
        Models::Package.each(&:destroy)
        Models::Template.each(&:destroy)

        @job.perform

        foos = Models::Package.filter(release_id: @release.id, name: 'foo').all
        bars = Models::Package.filter(release_id: @release.id, name: 'bar').all

        expect(foos.map(&:version)).to match_array(%w[2.33-dev])
        expect(bars.map(&:version)).to match_array(%w[3.14-dev])

        bazs = Models::Template.filter(release_id: @release.id, name: 'baz').all
        zazs = Models::Template.filter(release_id: @release.id, name: 'zaz').all

        expect(bazs.map(&:version)).to match_array(%w[33])
        expect(zazs.map(&:version)).to match_array(%w[0.2-dev])

        rv = Models::ReleaseVersion.filter(release_id: @release.id, version: '42+dev.1').first

        expect(rv.packages.map(&:version)).to match_array(%w[2.33-dev 3.14-dev 333])
        expect(rv.templates.map(&:version)).to match_array(%w[0.2-dev 33 666])
      end

      it 'performs the rebase if same release is being rebased twice', if: ENV.fetch('DB', 'sqlite') != 'sqlite' do
        allow(Config).to receive_message_chain(:current_job, :username).and_return('username')
        task = Models::Task.make(state: 'processing')
        allow(Config).to receive_message_chain(:current_job, :task_id).and_return(task.id)

        Config.configure(SpecHelper.spec_get_director_config)
        @job.perform

        @release_dir = Test::ReleaseHelper.new.create_release_tarball(manifest)
        @release_path = File.join(@release_dir, 'release.tgz')
        @job = Jobs::UpdateRelease.new(@release_path, 'rebase' => true)

        expect do
          @job.perform
        end.to_not raise_error

        rv = Models::ReleaseVersion.filter(release_id: @release.id, version: '42+dev.2').first
        expect(rv).to_not be_nil
      end
    end

    describe 'uploading release with --fix' do
      subject(:job) { Jobs::UpdateRelease.new(release_path, 'fix' => true) }
      let(:release_dir) { Test::ReleaseHelper.new.create_release_tarball(manifest) }
      let(:release_path) { File.join(release_dir, 'release.tgz') }
      let!(:release) { Models::Release.make(name: 'appcloud') }

      let!(:release_version_model) do
        Models::ReleaseVersion.make(
          release: release,
          version: '42+dev.1',
          commit_hash: '12345678',
          uncommitted_changes: true,
        )
      end
      before do
        allow(Dir).to receive(:mktmpdir).and_return(release_dir)
        allow(job).to receive(:with_release_lock).and_yield
      end

      context 'when uploading source release' do
        let(:manifest) do
          {
            'name' => 'appcloud',
            'version' => '42+dev.1',
            'commit_hash' => '12345678',
            'uncommitted_changes' => true,
            'jobs' => manifest_jobs,
            'packages' => manifest_packages,
          }
        end
        let(:manifest_jobs) do
          [
            {
              'sha1' => 'fakesha2',
              'fingerprint' => 'fake-fingerprint-2',
              'name' => 'fake-name-2',
              'version' => 'fake-version-2',
              'packages' => [
                'fake-name-1',
              ],
              'templates' => {},
            },
          ]
        end
        let(:manifest_packages) do
          [
            {
              'sha1' => 'fakesha1',
              'fingerprint' => 'fake-fingerprint-1',
              'name' => 'fake-name-1',
              'version' => 'fake-version-1',
              'dependencies' => [],
            },
          ]
        end

        context 'when release already exists' do
          let!(:package) do
            package = Models::Package.make(
              release: release,
              name: 'fake-name-1',
              version: 'fake-version-1',
              fingerprint: 'fake-fingerprint-1',
              blobstore_id: 'fake-pkg-blobstore-id-1',
              sha1: 'fakesha1',
            )
            release_version_model.add_package(package)
            package
          end

          let!(:template) do
            template = Models::Template.make(
              release: release,
              name: 'fake-name-2',
              version: 'fake-version-2',
              fingerprint: 'fake-fingerprint-2',
              blobstore_id: 'fake-job-blobstore-id-2',
              sha1: 'fakesha2',
            )
            release_version_model.add_template(template)
            template
          end

          it 're-uploads all blobs to replace old ones' do
            expect(BlobUtil).to receive(:delete_blob).with('fake-pkg-blobstore-id-1')
            expect(BlobUtil).to receive(:delete_blob).with('fake-job-blobstore-id-2')

            expect(BlobUtil).to receive(:create_blob).with(
              File.join(release_dir, 'packages', 'fake-name-1.tgz'),
            ).and_return('new-blobstore-id-after-fix')

            expect(BlobUtil).to receive(:create_blob).with(
              File.join(release_dir, 'jobs', 'fake-name-2.tgz'),
            ).and_return('new-job-blobstore-id-after-fix')

            job.perform

            expect(template.reload.blobstore_id).to eq('new-job-blobstore-id-after-fix')
          end
        end

        context 'when re-using existing packages' do
          let!(:another_release) { Models::Release.make(name: 'foocloud') }
          let!(:old_release_version_model) do
            Models::ReleaseVersion.make(
              release: another_release,
              version: '41+dev.1',
              commit_hash: '23456789',
              uncommitted_changes: true,
            )
          end

          let!(:existing_pkg) do
            package = Models::Package.make(
              release: another_release,
              name: 'fake-name-1',
              version: 'fake-version-1',
              fingerprint: 'fake-fingerprint-1',
              blobstore_id: 'fake-blobstore-id-1',
              sha1: 'fakesha1',
            ).save

            old_release_version_model.add_package(package)
            package
          end

          it 'replaces existing packages and copy blobs' do
            expect(BlobUtil).to receive(:delete_blob).with('fake-blobstore-id-1')
            expect(BlobUtil).to receive(:create_blob).with(File.join(release_dir, 'packages', 'fake-name-1.tgz')).and_return('new-blobstore-id-after-fix')
            expect(BlobUtil).to receive(:create_blob).with(File.join(release_dir, 'jobs', 'fake-name-2.tgz')).and_return('new-job-blobstore-id-after-fix')
            expect(BlobUtil).to receive(:copy_blob).with('new-blobstore-id-after-fix').and_return('new-blobstore-id')
            job.perform
          end
        end

        context 'eliminates compiled packages' do
          let!(:package) do
            package = Models::Package.make(
              release: release,
              name: 'fake-name-1',
              version: 'fake-version-1',
              fingerprint: 'fake-fingerprint-1',
              blobstore_id: 'fake-pkg-blobstore-id-1',
              sha1: 'fakepkgsha1',
            )
            release_version_model.add_package(package)
            package
          end
          let!(:compiled_package) do
            Models::CompiledPackage.make(
              package: package,
              sha1: 'fakecompiledsha1',
              blobstore_id: 'fake-compiled-pkg-blobstore-id-1',
              dependency_key: 'fake-dep-key-1',
              stemcell_os: 'windows me',
              stemcell_version: '4.5',
            )
          end

          it 'eliminates package when broken or missing' do
            expect(BlobUtil).to receive(:delete_blob).with('fake-pkg-blobstore-id-1')
            expect(BlobUtil).to receive(:create_blob).with(
              File.join(release_dir, 'packages', 'fake-name-1.tgz'),
            ).and_return('new-pkg-blobstore-id-1')
            expect(BlobUtil).to receive(:create_blob).with(
              File.join(release_dir, 'jobs', 'fake-name-2.tgz'),
            ).and_return('new-job-blobstore-id-1')
            expect(BlobUtil).to receive(:delete_blob).with('fake-compiled-pkg-blobstore-id-1')
            expect do
              job.perform
            end.to change { Models::CompiledPackage.dataset.count }.from(1).to(0)
          end
        end
      end

      context 'when uploading compiled release' do
        let(:manifest_jobs) { [] }
        let(:manifest_compiled_packages) do
          [
            {
              'sha1' => 'fakesha1',
              'fingerprint' => 'fake-fingerprint-1',
              'name' => 'fake-name-1',
              'version' => 'fake-version-1',
              'stemcell' => 'macintosh os/7.1',
            },
          ]
        end
        let(:manifest) do
          {
            'name' => 'appcloud',
            'version' => '42+dev.1',
            'commit_hash' => '12345678',
            'uncommitted_changes' => true,
            'jobs' => manifest_jobs,
            'compiled_packages' => manifest_compiled_packages,
          }
        end

        context 'when release already exists' do
          let!(:package) do
            package = Models::Package.make(
              release: release,
              name: 'fake-name-1',
              version: 'fake-version-1',
              fingerprint: 'fake-fingerprint-1',
            )
            release_version_model.add_package(package)
            package
          end
          let!(:existing_compiled_package_with_different_dependencies) do
            compiled_package = Models::CompiledPackage.make(
              blobstore_id: 'fake-compiled-blobstore-id-2',
              dependency_key: 'blarg',
              sha1: 'fakecompiledsha1',
              stemcell_os: 'macintosh os',
              stemcell_version: '7.1',
            )
            package.add_compiled_package compiled_package
            compiled_package
          end
          let!(:compiled_package) do
            compiled_package = Models::CompiledPackage.make(
              blobstore_id: 'fake-compiled-blobstore-id-1',
              dependency_key: '[]',
              sha1: 'fakecompiledsha1',
              stemcell_os: 'macintosh os',
              stemcell_version: '7.1',
            )
            package.add_compiled_package compiled_package
            compiled_package
          end

          it 're-uploads all compiled packages to replace old ones' do
            expect(BlobUtil).to receive(:delete_blob).with('fake-compiled-blobstore-id-1')
            expect(BlobUtil).to receive(:create_blob).with(
              File.join(release_dir, 'compiled_packages', 'fake-name-1.tgz'),
            ).and_return('new-compiled-blobstore-id-after-fix')
            expect do
              job.perform
            end.to change {
              compiled_package.reload.blobstore_id
            }.from('fake-compiled-blobstore-id-1').to('new-compiled-blobstore-id-after-fix')
          end
        end

        context 'when re-using existing compiled packages from other releases' do
          let!(:another_release) { Models::Release.make(name: 'foocloud') }
          let!(:old_release_version_model) do
            Models::ReleaseVersion.make(
              release: another_release,
              version: '41+dev.1',
              commit_hash: '23456789',
              uncommitted_changes: true,
            )
          end
          let!(:existing_package) do
            package = Models::Package.make(
              release: another_release,
              name: 'fake-name-1',
              version: 'fake-version-1',
              fingerprint: 'fake-fingerprint-1',
            ).save

            old_release_version_model.add_package(package)
            package
          end
          let!(:existing_package_with_same_fingerprint) do
            package = Models::Package.make(
              release: another_release,
              name: 'fake-name-2',
              version: 'fake-version-2',
              fingerprint: 'fake-fingerprint-1',
            ).save

            old_release_version_model.add_package(package)
            package
          end
          let!(:existing_compiled_package_with_different_dependencies) do
            existing_compiled_package = Models::CompiledPackage.make(
              blobstore_id: 'fake-existing-compiled-blobstore-id-2',
              dependency_key: 'fake-existing-compiled-dependency-key-1-other',
              sha1: 'fakeexistingcompiledsha1',
              stemcell_os: 'macintosh os',
              stemcell_version: '7.1',
            )
            existing_package.add_compiled_package existing_compiled_package
            existing_compiled_package
          end

          let!(:existing_compiled_package) do
            Models::CompiledPackage.make(
              blobstore_id: 'fake-existing-compiled-blobstore-id-1',
              dependency_key: '[]',
              sha1: 'fakeexistingcompiledsha1',
              stemcell_os: 'macintosh os',
              stemcell_version: '7.1',
            ).tap { |c| existing_package.add_compiled_package(c) }
          end

          let!(:matching_existing_compiled_package_from_same_release_version) do
            Models::CompiledPackage.make(
              blobstore_id: 'fake-existing-compiled-blobstore-id-A',
              dependency_key: '[]',
              sha1: 'fakeexistingcompiledsha1',
              stemcell_os: 'macintosh os',
              stemcell_version: '7.1',
            ).tap { |c| existing_package_with_same_fingerprint.add_compiled_package(c) }
          end
          it 'replaces existing compiled packages and copy blobs' do
            expect(BlobUtil).to receive(:delete_blob).with('fake-existing-compiled-blobstore-id-1')
            expect(BlobUtil).to receive(:delete_blob).with('fake-existing-compiled-blobstore-id-A')
            expect(BlobUtil).to receive(:create_blob).with(
              File.join(release_dir, 'compiled_packages', 'fake-name-1.tgz'),
            ).and_return('new-existing-compiled-blobstore-id-after-fix', 'new-existing-compiled-blobstore-id-A-after-fix')
            expect(BlobUtil).to receive(:copy_blob).with(
              'new-existing-compiled-blobstore-id-after-fix',
            ).and_return('new-compiled-blobstore-id')
            expect(existing_compiled_package.reload.blobstore_id).to eq('fake-existing-compiled-blobstore-id-1')
            expect(matching_existing_compiled_package_from_same_release_version.reload.blobstore_id).to eq('fake-existing-compiled-blobstore-id-A')
            job.perform
            expect(existing_compiled_package.reload.blobstore_id).to eq('new-existing-compiled-blobstore-id-after-fix')
            expect(matching_existing_compiled_package_from_same_release_version.reload.blobstore_id).to eq('new-existing-compiled-blobstore-id-A-after-fix')
          end
        end
      end
    end

    describe 'create_package_for_compiled_release' do
      let(:release_dir) { Dir.mktmpdir }
      after { FileUtils.rm_rf(release_dir) }

      before do
        @release = Models::Release.make
        @job = Jobs::UpdateRelease.new(release_dir)
        @job.release_model = @release
        @job.instance_variable_set(:@compiled_release, true)
      end

      it 'should create simple packages without blobstore_id or sha1' do
        @job.create_package({
          'name' => 'test_package',
          'version' => '1.0',
          'sha1' => nil,
          'dependencies' => %w[foo_package bar_package],
        }, release_dir)

        package = Models::Package[name: 'test_package', version: '1.0']
        expect(package).not_to be_nil
        expect(package.name).to eq('test_package')
        expect(package.version).to eq('1.0')
        expect(package.release).to eq(@release)
        expect(package.sha1).to be_nil
        expect(package.blobstore_id).to be_nil
      end
    end

    describe 'create_package' do
      let(:release_dir) { Dir.mktmpdir }
      after { FileUtils.rm_rf(release_dir) }

      before do
        @release = Models::Release.make
        @job = Jobs::UpdateRelease.new(release_dir)
        @job.release_model = @release
      end

      it 'should create simple packages' do
        FileUtils.mkdir_p(File.join(release_dir, 'packages'))
        package_path = File.join(release_dir, 'packages', 'test_package.tgz')

        File.open(package_path, 'w') do |f|
          f.write(create_package('test' => 'test contents'))
        end

        expect(blobstore).to receive(:create)
          .with(satisfy { |obj| obj.path == package_path })
          .and_return('blob_id')

        @job.create_package({
          'name' => 'test_package',
          'version' => '1.0',
          'sha1' => 'some-sha',
          'dependencies' => %w[foo_package bar_package],
        }, release_dir)

        package = Models::Package[name: 'test_package', version: '1.0']
        expect(package).not_to be_nil
        expect(package.name).to eq('test_package')
        expect(package.version).to eq('1.0')
        expect(package.release).to eq(@release)
        expect(package.sha1).to eq('some-sha')
        expect(package.blobstore_id).to eq('blob_id')
      end

      it 'should copy package blob' do
        expect(BlobUtil).to receive(:copy_blob).and_return('blob_id')
        FileUtils.mkdir_p(File.join(release_dir, 'packages'))
        package_path = File.join(release_dir, 'packages', 'test_package.tgz')
        File.open(package_path, 'w') do |f|
          f.write(create_package('test' => 'test contents'))
        end

        @job.create_package({
          'name' => 'test_package',
          'version' => '1.0', 'sha1' => 'some-sha',
          'dependencies' => %w[foo_package bar_package],
          'blobstore_id' => 'blah'
        }, release_dir)

        package = Models::Package[name: 'test_package', version: '1.0']
        expect(package).not_to be_nil
        expect(package.name).to eq('test_package')
        expect(package.version).to eq('1.0')
        expect(package.release).to eq(@release)
        expect(package.sha1).to eq('some-sha')
        expect(package.blobstore_id).to eq('blob_id')
      end

      it 'should fail if cannot extract package archive' do
        result = Bosh::Exec::Result.new('cmd', 'output', 1)
        expect(Bosh::Exec).to receive(:sh).and_return(result)

        expect do
          @job.create_package({
            'name' => 'test_package',
            'version' => '1.0',
            'sha1' => 'some-sha',
            'dependencies' => %w[foo_package bar_package],
          }, release_dir)
        end.to raise_exception(Bosh::Director::PackageInvalidArchive)
      end

      def create_package(files)
        io = StringIO.new

        Archive::Tar::Minitar::Writer.open(io) do |tar|
          files.each do |key, value|
            tar.add_file(key, mode: '0644', mtime: 0) { |os, _| os.write(value) }
          end
        end

        io.close
        gzip(io.string)
      end
    end

    describe 'resolve_package_dependencies' do
      before do
        @job = Jobs::UpdateRelease.new('fake-release-path')
      end

      it 'should normalize nil dependencies' do
        packages = [
          { 'name' => 'A' },
          { 'name' => 'B', 'dependencies' => ['A'] },
        ]
        @job.resolve_package_dependencies(packages)
        expect(packages).to eql([
                                  { 'name' => 'A', 'dependencies' => [] },
                                  { 'name' => 'B', 'dependencies' => ['A'] },
                                ])
      end

      it 'should not allow cycles' do
        packages = [
          { 'name' => 'A', 'dependencies' => ['B'] },
          { 'name' => 'B', 'dependencies' => ['A'] },
        ]
        expect { @job.resolve_package_dependencies(packages) }.to raise_exception
      end
    end

    describe 'process_release' do
      subject(:job) { Jobs::UpdateRelease.new(release_path) }
      let(:release_dir) { Test::ReleaseHelper.new.create_release_tarball(manifest) }
      let(:release_path) { File.join(release_dir, 'release.tgz') }
      let(:manifest) do
        {
          'name' => 'appcloud',
          'version' => release_version,
          'commit_hash' => '12345678',
          'uncommitted_changes' => false,
          'jobs' => manifest_jobs,
          'packages' => manifest_packages,
        }
      end
      let(:release_version) { '42+dev.6' }
      let(:release) { Models::Release.make(name: 'appcloud') }
      let(:manifest_packages) { nil }
      let(:manifest_jobs) { nil }
      let(:extracted_release_dir) { job.extract_release }

      before do
        allow(Dir).to receive(:mktmpdir).and_return(release_dir)
        job.verify_manifest(extracted_release_dir)
      end

      context 'when upload release fails' do
        shared_examples_for 'failed release update' do
          it 'flags release as uncompleted' do
            allow(job).to receive(:process_jobs).and_raise('Intentional error')

            expect { job.process_release(extracted_release_dir) }.to raise_error('Intentional error')

            rv = Models::ReleaseVersion.filter(version: release_version).first
            expect(rv.update_completed).to be(false)
          end
        end

        context 'on a new release' do
          include_examples 'failed release update'
        end

        context 'on an already uploaded release' do
          before do
            Models::ReleaseVersion.make(release: release, version: '42+dev.6', commit_hash: '12345678',
                                        update_completed: true)
          end

          include_examples 'failed release update'
        end

        context 'on an already uploaded but uncompleted release' do
          it 'fixes the release' do
            Models::ReleaseVersion.make(release: release, version: '42+dev.6', commit_hash: '12345678',
                                        update_completed: false)

            job.process_release(extracted_release_dir)

            expect(job.fix).to be(true)
            rv = Models::ReleaseVersion.filter(version: release_version).first
            expect(rv.update_completed).to be(true)
          end
        end
      end
    end
  end
end
