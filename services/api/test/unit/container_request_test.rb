# Copyright (C) The Arvados Authors. All rights reserved.
#
# SPDX-License-Identifier: AGPL-3.0

require 'test_helper'
require 'helpers/docker_migration_helper'

class ContainerRequestTest < ActiveSupport::TestCase
  include DockerMigrationHelper
  include DbCurrentTime

  def create_minimal_req! attrs={}
    defaults = {
      command: ["echo", "foo"],
      container_image: links(:docker_image_collection_tag).name,
      cwd: "/tmp",
      environment: {},
      mounts: {"/out" => {"kind" => "tmp", "capacity" => 1000000}},
      output_path: "/out",
      runtime_constraints: {"vcpus" => 1, "ram" => 2},
      name: "foo",
      description: "bar",
    }
    cr = ContainerRequest.create!(defaults.merge(attrs))
    cr.reload
    return cr
  end

  def check_bogus_states cr
    [nil, "Flubber"].each do |state|
      assert_raises(ActiveRecord::RecordInvalid) do
        cr.state = state
        cr.save!
      end
      cr.reload
    end
  end

  test "Container request create" do
    set_user_from_auth :active
    cr = create_minimal_req!

    assert_nil cr.container_uuid
    assert_nil cr.priority

    check_bogus_states cr

    # Ensure we can modify all attributes
    cr.command = ["echo", "foo3"]
    cr.container_image = "img3"
    cr.cwd = "/tmp3"
    cr.environment = {"BUP" => "BOP"}
    cr.mounts = {"BAR" => "BAZ"}
    cr.output_path = "/tmp4"
    cr.priority = 2
    cr.runtime_constraints = {"vcpus" => 4}
    cr.name = "foo3"
    cr.description = "bar3"
    cr.save!

    assert_nil cr.container_uuid
  end

  [
    {"vcpus" => 1},
    {"vcpus" => 1, "ram" => nil},
    {"vcpus" => 0, "ram" => 123},
    {"vcpus" => "1", "ram" => "123"}
  ].each do |invalid_constraints|
    test "Create with #{invalid_constraints}" do
      set_user_from_auth :active
      assert_raises(ActiveRecord::RecordInvalid) do
        cr = create_minimal_req!(state: "Committed",
                                 priority: 1,
                                 runtime_constraints: invalid_constraints)
        cr.save!
      end
    end

    test "Update with #{invalid_constraints}" do
      set_user_from_auth :active
      cr = create_minimal_req!(state: "Uncommitted", priority: 1)
      cr.save!
      assert_raises(ActiveRecord::RecordInvalid) do
        cr = ContainerRequest.find_by_uuid cr.uuid
        cr.update_attributes!(state: "Committed",
                              runtime_constraints: invalid_constraints)
      end
    end
  end

  test "Update from fixture" do
    set_user_from_auth :active
    cr = ContainerRequest.find_by_uuid(container_requests(:running).uuid)
    cr.update_attributes!(description: "New description")
    assert_equal "New description", cr.description
  end

  test "Update with valid runtime constraints" do
      set_user_from_auth :active
      cr = create_minimal_req!(state: "Uncommitted", priority: 1)
      cr.save!
      cr = ContainerRequest.find_by_uuid cr.uuid
      cr.update_attributes!(state: "Committed",
                            runtime_constraints: {"vcpus" => 1, "ram" => 23})
      assert_not_nil cr.container_uuid
  end

  test "Container request priority must be non-nil" do
    set_user_from_auth :active
    cr = create_minimal_req!(priority: nil)
    cr.state = "Committed"
    assert_raises(ActiveRecord::RecordInvalid) do
      cr.save!
    end
  end

  test "Container request commit" do
    set_user_from_auth :active
    cr = create_minimal_req!(runtime_constraints: {"vcpus" => 2, "ram" => 30})

    assert_nil cr.container_uuid

    cr.reload
    cr.state = "Committed"
    cr.priority = 1
    cr.save!

    cr.reload

    assert_equal({"vcpus" => 2, "ram" => 30}, cr.runtime_constraints)

    assert_not_nil cr.container_uuid
    c = Container.find_by_uuid cr.container_uuid
    assert_not_nil c
    assert_equal ["echo", "foo"], c.command
    assert_equal collections(:docker_image).portable_data_hash, c.container_image
    assert_equal "/tmp", c.cwd
    assert_equal({}, c.environment)
    assert_equal({"/out" => {"kind"=>"tmp", "capacity"=>1000000}}, c.mounts)
    assert_equal "/out", c.output_path
    assert_equal({"keep_cache_ram"=>268435456, "vcpus" => 2, "ram" => 30}, c.runtime_constraints)
    assert_equal 1, c.priority

    assert_raises(ActiveRecord::RecordInvalid) do
      cr.priority = nil
      cr.save!
    end

    cr.priority = 0
    cr.save!

    cr.reload
    c.reload
    assert_equal 0, cr.priority
    assert_equal 0, c.priority
  end


  test "Container request max priority" do
    set_user_from_auth :active
    cr = create_minimal_req!(priority: 5, state: "Committed")

    c = Container.find_by_uuid cr.container_uuid
    assert_equal 5, c.priority

    cr2 = create_minimal_req!
    cr2.priority = 10
    cr2.state = "Committed"
    cr2.container_uuid = cr.container_uuid
    act_as_system_user do
      cr2.save!
    end

    # cr and cr2 have priority 5 and 10, and are being satisfied by
    # the same container c, so c's priority should be
    # max(priority)=10.
    c.reload
    assert_equal 10, c.priority

    cr2.update_attributes!(priority: 0)

    c.reload
    assert_equal 5, c.priority

    cr.update_attributes!(priority: 0)

    c.reload
    assert_equal 0, c.priority
  end


  test "Independent container requests" do
    set_user_from_auth :active
    cr1 = create_minimal_req!(command: ["foo", "1"], priority: 5, state: "Committed")
    cr2 = create_minimal_req!(command: ["foo", "2"], priority: 10, state: "Committed")

    c1 = Container.find_by_uuid cr1.container_uuid
    assert_equal 5, c1.priority

    c2 = Container.find_by_uuid cr2.container_uuid
    assert_equal 10, c2.priority

    cr1.update_attributes!(priority: 0)

    c1.reload
    assert_equal 0, c1.priority

    c2.reload
    assert_equal 10, c2.priority
  end

  test "Request is finalized when its container is cancelled" do
    set_user_from_auth :active
    cr = create_minimal_req!(priority: 1, state: "Committed", container_count_max: 1)

    act_as_system_user do
      Container.find_by_uuid(cr.container_uuid).
        update_attributes!(state: Container::Cancelled)
    end

    cr.reload
    assert_equal "Final", cr.state
  end

  test "Request is finalized when its container is completed" do
    set_user_from_auth :active
    project = groups(:private)
    cr = create_minimal_req!(owner_uuid: project.uuid,
                             priority: 1,
                             state: "Committed")

    c = act_as_system_user do
      c = Container.find_by_uuid(cr.container_uuid)
      c.update_attributes!(state: Container::Locked)
      c.update_attributes!(state: Container::Running)
      c
    end

    cr.reload
    assert_equal "Committed", cr.state

    output_pdh = '1f4b0bc7583c2a7f9102c395f4ffc5e3+45'
    log_pdh = 'fa7aeb5140e2848d39b416daeef4ffc5+45'
    act_as_system_user do
      c.update_attributes!(state: Container::Complete,
                           output: output_pdh,
                           log: log_pdh)
    end

    cr.reload
    assert_equal "Final", cr.state
    ['output', 'log'].each do |out_type|
      pdh = Container.find_by_uuid(cr.container_uuid).send(out_type)
      assert_equal(1, Collection.where(portable_data_hash: pdh,
                                       owner_uuid: project.uuid).count,
                   "Container #{out_type} should be copied to #{project.uuid}")
    end
    assert_not_nil cr.output_uuid
    assert_not_nil cr.log_uuid
    output = Collection.find_by_uuid cr.output_uuid
    assert_equal output_pdh, output.portable_data_hash
    log = Collection.find_by_uuid cr.log_uuid
    assert_equal log_pdh, log.portable_data_hash
  end

  test "Container makes container request, then is cancelled" do
    set_user_from_auth :active
    cr = create_minimal_req!(priority: 5, state: "Committed", container_count_max: 1)

    c = Container.find_by_uuid cr.container_uuid
    assert_equal 5, c.priority

    cr2 = create_minimal_req!
    cr2.update_attributes!(priority: 10, state: "Committed", requesting_container_uuid: c.uuid, command: ["echo", "foo2"], container_count_max: 1)
    cr2.reload

    c2 = Container.find_by_uuid cr2.container_uuid
    assert_equal 10, c2.priority

    act_as_system_user do
      c.state = "Cancelled"
      c.save!
    end

    cr.reload
    assert_equal "Final", cr.state

    cr2.reload
    assert_equal 0, cr2.priority

    c2.reload
    assert_equal 0, c2.priority
  end

  [
    ['running_container_auth', 'zzzzz-dz642-runningcontainr'],
    ['active_no_prefs', nil],
  ].each do |token, expected|
    test "create as #{token} and expect requesting_container_uuid to be #{expected}" do
      set_user_from_auth token
      cr = ContainerRequest.create(container_image: "img", output_path: "/tmp", command: ["echo", "foo"])
      assert_not_nil cr.uuid, 'uuid should be set for newly created container_request'
      assert_equal expected, cr.requesting_container_uuid
    end
  end

  [[{"vcpus" => [2, nil]},
    lambda { |resolved| resolved["vcpus"] == 2 }],
   [{"vcpus" => [3, 7]},
    lambda { |resolved| resolved["vcpus"] == 3 }],
   [{"vcpus" => 4},
    lambda { |resolved| resolved["vcpus"] == 4 }],
   [{"ram" => [1000000000, 2000000000]},
    lambda { |resolved| resolved["ram"] == 1000000000 }],
   [{"ram" => [1234234234]},
    lambda { |resolved| resolved["ram"] == 1234234234 }],
  ].each do |rc, okfunc|
    test "resolve runtime constraint range #{rc} to values" do
      resolved = Container.resolve_runtime_constraints(rc)
      assert(okfunc.call(resolved),
             "container runtime_constraints was #{resolved.inspect}")
    end
  end

  [[{"/out" => {
        "kind" => "collection",
        "uuid" => "zzzzz-4zz18-znfnqtbbv4spc3w",
        "path" => "/foo"}},
    lambda do |resolved|
      resolved["/out"] == {
        "portable_data_hash" => "1f4b0bc7583c2a7f9102c395f4ffc5e3+45",
        "kind" => "collection",
        "path" => "/foo",
      }
    end],
   [{"/out" => {
        "kind" => "collection",
        "uuid" => "zzzzz-4zz18-znfnqtbbv4spc3w",
        "portable_data_hash" => "1f4b0bc7583c2a7f9102c395f4ffc5e3+45",
        "path" => "/foo"}},
    lambda do |resolved|
      resolved["/out"] == {
        "portable_data_hash" => "1f4b0bc7583c2a7f9102c395f4ffc5e3+45",
        "kind" => "collection",
        "path" => "/foo",
      }
    end],
  ].each do |mounts, okfunc|
    test "resolve mounts #{mounts.inspect} to values" do
      set_user_from_auth :active
      resolved = Container.resolve_mounts(mounts)
      assert(okfunc.call(resolved),
             "Container.resolve_mounts returned #{resolved.inspect}")
    end
  end

  test 'mount unreadable collection' do
    set_user_from_auth :spectator
    m = {
      "/foo" => {
        "kind" => "collection",
        "uuid" => "zzzzz-4zz18-znfnqtbbv4spc3w",
        "path" => "/foo",
      },
    }
    assert_raises(ArvadosModel::UnresolvableContainerError) do
      Container.resolve_mounts(m)
    end
  end

  test 'mount collection with mismatched UUID and PDH' do
    set_user_from_auth :active
    m = {
      "/foo" => {
        "kind" => "collection",
        "uuid" => "zzzzz-4zz18-znfnqtbbv4spc3w",
        "portable_data_hash" => "fa7aeb5140e2848d39b416daeef4ffc5+45",
        "path" => "/foo",
      },
    }
    assert_raises(ArgumentError) do
      Container.resolve_mounts(m)
    end
  end

  ['arvados/apitestfixture:latest',
   'arvados/apitestfixture',
   'd8309758b8fe2c81034ffc8a10c36460b77db7bc5e7b448c4e5b684f9d95a678',
  ].each do |tag|
    test "Container.resolve_container_image(#{tag.inspect})" do
      set_user_from_auth :active
      resolved = Container.resolve_container_image(tag)
      assert_equal resolved, collections(:docker_image).portable_data_hash
    end
  end

  test "Container.resolve_container_image(pdh)" do
    set_user_from_auth :active
    [[:docker_image, 'v1'], [:docker_image_1_12, 'v2']].each do |coll, ver|
      Rails.configuration.docker_image_formats = [ver]
      pdh = collections(coll).portable_data_hash
      resolved = Container.resolve_container_image(pdh)
      assert_equal resolved, pdh
    end
  end

  ['acbd18db4cc2f85cedef654fccc4a4d8+3',
   'ENOEXIST',
   'arvados/apitestfixture:ENOEXIST',
  ].each do |img|
    test "container_image_for_container(#{img.inspect}) => 422" do
      set_user_from_auth :active
      assert_raises(ArvadosModel::UnresolvableContainerError) do
        Container.resolve_container_image(img)
      end
    end
  end

  test "migrated docker image" do
    Rails.configuration.docker_image_formats = ['v2']
    add_docker19_migration_link

    # Test that it returns only v2 images even though request is for v1 image.

    set_user_from_auth :active
    cr = create_minimal_req!(command: ["true", "1"],
                             container_image: collections(:docker_image).portable_data_hash)
    assert_equal(Container.resolve_container_image(cr.container_image),
                 collections(:docker_image_1_12).portable_data_hash)

    cr = create_minimal_req!(command: ["true", "2"],
                             container_image: links(:docker_image_collection_tag).name)
    assert_equal(Container.resolve_container_image(cr.container_image),
                 collections(:docker_image_1_12).portable_data_hash)
  end

  test "use unmigrated docker image" do
    Rails.configuration.docker_image_formats = ['v1']
    add_docker19_migration_link

    # Test that it returns only supported v1 images even though there is a
    # migration link.

    set_user_from_auth :active
    cr = create_minimal_req!(command: ["true", "1"],
                             container_image: collections(:docker_image).portable_data_hash)
    assert_equal(Container.resolve_container_image(cr.container_image),
                 collections(:docker_image).portable_data_hash)

    cr = create_minimal_req!(command: ["true", "2"],
                             container_image: links(:docker_image_collection_tag).name)
    assert_equal(Container.resolve_container_image(cr.container_image),
                 collections(:docker_image).portable_data_hash)
  end

  test "incompatible docker image v1" do
    Rails.configuration.docker_image_formats = ['v1']
    add_docker19_migration_link

    # Don't return unsupported v2 image even if we ask for it directly.
    set_user_from_auth :active
    cr = create_minimal_req!(command: ["true", "1"],
                             container_image: collections(:docker_image_1_12).portable_data_hash)
    assert_raises(ArvadosModel::UnresolvableContainerError) do
      Container.resolve_container_image(cr.container_image)
    end
  end

  test "incompatible docker image v2" do
    Rails.configuration.docker_image_formats = ['v2']
    # No migration link, don't return unsupported v1 image,

    set_user_from_auth :active
    cr = create_minimal_req!(command: ["true", "1"],
                             container_image: collections(:docker_image).portable_data_hash)
    assert_raises(ArvadosModel::UnresolvableContainerError) do
      Container.resolve_container_image(cr.container_image)
    end
    cr = create_minimal_req!(command: ["true", "2"],
                             container_image: links(:docker_image_collection_tag).name)
    assert_raises(ArvadosModel::UnresolvableContainerError) do
      Container.resolve_container_image(cr.container_image)
    end
  end

  test "requestor can retrieve container owned by dispatch" do
    assert_not_empty Container.readable_by(users(:admin)).where(uuid: containers(:running).uuid)
    assert_not_empty Container.readable_by(users(:active)).where(uuid: containers(:running).uuid)
    assert_empty Container.readable_by(users(:spectator)).where(uuid: containers(:running).uuid)
  end

  [
    [{"var" => "value1"}, {"var" => "value1"}, nil],
    [{"var" => "value1"}, {"var" => "value1"}, true],
    [{"var" => "value1"}, {"var" => "value1"}, false],
    [{"var" => "value1"}, {"var" => "value2"}, nil],
  ].each do |env1, env2, use_existing|
    test "Container request #{((env1 == env2) and (use_existing.nil? or use_existing == true)) ? 'does' : 'does not'} reuse container when committed#{use_existing.nil? ? '' : use_existing ? ' and use_existing == true' : ' and use_existing == false'}" do
      common_attrs = {cwd: "test",
                      priority: 1,
                      command: ["echo", "hello"],
                      output_path: "test",
                      runtime_constraints: {"vcpus" => 4,
                                            "ram" => 12000000000},
                      mounts: {"test" => {"kind" => "json"}}}
      set_user_from_auth :active
      cr1 = create_minimal_req!(common_attrs.merge({state: ContainerRequest::Committed,
                                                    environment: env1}))
      if use_existing.nil?
        # Testing with use_existing default value
        cr2 = create_minimal_req!(common_attrs.merge({state: ContainerRequest::Uncommitted,
                                                      environment: env2}))
      else

        cr2 = create_minimal_req!(common_attrs.merge({state: ContainerRequest::Uncommitted,
                                                      environment: env2,
                                                      use_existing: use_existing}))
      end
      assert_not_nil cr1.container_uuid
      assert_nil cr2.container_uuid

      # Update cr2 to commited state and check for container equality on different cases:
      # * When env1 and env2 are equal and use_existing is true, the same container
      #   should be assigned.
      # * When use_existing is false, a different container should be assigned.
      # * When env1 and env2 are different, a different container should be assigned.
      cr2.update_attributes!({state: ContainerRequest::Committed})
      assert_equal (cr2.use_existing == true and (env1 == env2)),
                   (cr1.container_uuid == cr2.container_uuid)
    end
  end

  test "requesting_container_uuid at create is not allowed" do
    set_user_from_auth :active
    assert_raises(ActiveRecord::RecordNotSaved) do
      create_minimal_req!(state: "Uncommitted", priority: 1, requesting_container_uuid: 'youcantdothat')
    end
  end

  test "Retry on container cancelled" do
    set_user_from_auth :active
    cr = create_minimal_req!(priority: 1, state: "Committed", container_count_max: 2)
    cr2 = create_minimal_req!(priority: 1, state: "Committed", container_count_max: 2, command: ["echo", "baz"])
    prev_container_uuid = cr.container_uuid

    c = act_as_system_user do
      c = Container.find_by_uuid(cr.container_uuid)
      c.update_attributes!(state: Container::Locked)
      c.update_attributes!(state: Container::Running)
      c
    end

    cr.reload
    cr2.reload
    assert_equal "Committed", cr.state
    assert_equal prev_container_uuid, cr.container_uuid
    assert_not_equal cr2.container_uuid, cr.container_uuid
    prev_container_uuid = cr.container_uuid

    act_as_system_user do
      c.update_attributes!(state: Container::Cancelled)
    end

    cr.reload
    cr2.reload
    assert_equal "Committed", cr.state
    assert_not_equal prev_container_uuid, cr.container_uuid
    assert_not_equal cr2.container_uuid, cr.container_uuid
    prev_container_uuid = cr.container_uuid

    c = act_as_system_user do
      c = Container.find_by_uuid(cr.container_uuid)
      c.update_attributes!(state: Container::Cancelled)
      c
    end

    cr.reload
    cr2.reload
    assert_equal "Final", cr.state
    assert_equal prev_container_uuid, cr.container_uuid
    assert_not_equal cr2.container_uuid, cr.container_uuid
  end

  test "Output collection name setting using output_name with name collision resolution" do
    set_user_from_auth :active
    output_name = 'unimaginative name'
    Collection.create!(name: output_name)

    cr = create_minimal_req!(priority: 1,
                             state: ContainerRequest::Committed,
                             output_name: output_name)
    run_container(cr)
    cr.reload
    assert_equal ContainerRequest::Final, cr.state
    output_coll = Collection.find_by_uuid(cr.output_uuid)
    # Make sure the resulting output collection name include the original name
    # plus the date
    assert_not_equal output_name, output_coll.name,
                     "more than one collection with the same owner and name"
    assert output_coll.name.include?(output_name),
           "New name should include original name"
    assert_match /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z/, output_coll.name,
                 "New name should include ISO8601 date"
  end

  [[0, :check_output_ttl_0],
   [1, :check_output_ttl_1s],
   [365*86400, :check_output_ttl_1y],
  ].each do |ttl, checker|
    test "output_ttl=#{ttl}" do
      act_as_user users(:active) do
        cr = create_minimal_req!(priority: 1,
                                 state: ContainerRequest::Committed,
                                 output_name: 'foo',
                                 output_ttl: ttl)
        run_container(cr)
        cr.reload
        output = Collection.find_by_uuid(cr.output_uuid)
        send(checker, db_current_time, output.trash_at, output.delete_at)
      end
    end
  end

  def check_output_ttl_0(now, trash, delete)
    assert_nil(trash)
    assert_nil(delete)
  end

  def check_output_ttl_1s(now, trash, delete)
    assert_not_nil(trash)
    assert_not_nil(delete)
    assert_in_delta(trash, now + 1.second, 10)
    assert_in_delta(delete, now + Rails.configuration.blob_signature_ttl.second, 10)
  end

  def check_output_ttl_1y(now, trash, delete)
    year = (86400*365).second
    assert_not_nil(trash)
    assert_not_nil(delete)
    assert_in_delta(trash, now + year, 10)
    assert_in_delta(delete, now + year, 10)
  end

  def run_container(cr)
    act_as_system_user do
      c = Container.find_by_uuid(cr.container_uuid)
      c.update_attributes!(state: Container::Locked)
      c.update_attributes!(state: Container::Running)
      c.update_attributes!(state: Container::Complete,
                           exit_code: 0,
                           output: '1f4b0bc7583c2a7f9102c395f4ffc5e3+45',
                           log: 'fa7aeb5140e2848d39b416daeef4ffc5+45')
      c
    end
  end

  test "Finalize committed request when reusing a finished container" do
    set_user_from_auth :active
    cr = create_minimal_req!(priority: 1, state: ContainerRequest::Committed)
    cr.reload
    assert_equal ContainerRequest::Committed, cr.state
    run_container(cr)
    cr.reload
    assert_equal ContainerRequest::Final, cr.state

    cr2 = create_minimal_req!(priority: 1, state: ContainerRequest::Committed)
    assert_equal cr.container_uuid, cr2.container_uuid
    assert_equal ContainerRequest::Final, cr2.state

    cr3 = create_minimal_req!(priority: 1, state: ContainerRequest::Uncommitted)
    assert_equal ContainerRequest::Uncommitted, cr3.state
    cr3.update_attributes!(state: ContainerRequest::Committed)
    assert_equal cr.container_uuid, cr3.container_uuid
    assert_equal ContainerRequest::Final, cr3.state
  end

  [
    [{"partitions" => ["fastcpu","vfastcpu", 100]}, ContainerRequest::Committed, ActiveRecord::RecordInvalid],
    [{"partitions" => ["fastcpu","vfastcpu", 100]}, ContainerRequest::Uncommitted],
    [{"partitions" => "fastcpu"}, ContainerRequest::Committed, ActiveRecord::RecordInvalid],
    [{"partitions" => "fastcpu"}, ContainerRequest::Uncommitted],
    [{"partitions" => ["fastcpu","vfastcpu"]}, ContainerRequest::Committed],
  ].each do |sp, state, expected|
    test "create container request with scheduling_parameters #{sp} in state #{state} and verify #{expected}" do
      common_attrs = {cwd: "test",
                      priority: 1,
                      command: ["echo", "hello"],
                      output_path: "test",
                      scheduling_parameters: sp,
                      mounts: {"test" => {"kind" => "json"}}}
      set_user_from_auth :active

      if expected == ActiveRecord::RecordInvalid
        assert_raises(ActiveRecord::RecordInvalid) do
          create_minimal_req!(common_attrs.merge({state: state}))
        end
      else
        cr = create_minimal_req!(common_attrs.merge({state: state}))
        assert_equal sp, cr.scheduling_parameters

        if state == ContainerRequest::Committed
          c = Container.find_by_uuid(cr.container_uuid)
          assert_equal sp, c.scheduling_parameters
        end
      end
    end
  end

  [['Committed', true, {name: "foobar", priority: 123}],
   ['Committed', false, {container_count: 2}],
   ['Committed', false, {container_count: 0}],
   ['Committed', false, {container_count: nil}],
   ['Final', false, {state: ContainerRequest::Committed, name: "foobar"}],
   ['Final', false, {name: "foobar", priority: 123}],
   ['Final', false, {name: "foobar", output_uuid: "zzzzz-4zz18-znfnqtbbv4spc3w"}],
   ['Final', false, {name: "foobar", log_uuid: "zzzzz-4zz18-znfnqtbbv4spc3w"}],
   ['Final', false, {log_uuid: "zzzzz-4zz18-znfnqtbbv4spc3w"}],
   ['Final', false, {priority: 123}],
   ['Final', false, {mounts: {}}],
   ['Final', false, {container_count: 2}],
   ['Final', true, {name: "foobar"}],
   ['Final', true, {name: "foobar", description: "baz"}],
  ].each do |state, permitted, updates|
    test "state=#{state} can#{'not' if !permitted} update #{updates.inspect}" do
      act_as_user users(:active) do
        cr = create_minimal_req!(priority: 1,
                                 state: "Committed",
                                 container_count_max: 1)
        case state
        when 'Committed'
          # already done
        when 'Final'
          act_as_system_user do
            Container.find_by_uuid(cr.container_uuid).
              update_attributes!(state: Container::Cancelled)
          end
          cr.reload
        else
          raise 'broken test case'
        end
        assert_equal state, cr.state
        if permitted
          assert cr.update_attributes!(updates)
        else
          assert_raises(ActiveRecord::RecordInvalid) do
            cr.update_attributes!(updates)
          end
        end
      end
    end
  end

  test "delete container_request and check its container's priority" do
    act_as_user users(:active) do
      cr = ContainerRequest.find_by_uuid container_requests(:running_to_be_deleted).uuid

      # initially the cr's container has priority > 0
      c = Container.find_by_uuid(cr.container_uuid)
      assert_equal 1, c.priority

      # destroy the cr
      assert_nothing_raised {cr.destroy}

      # the cr's container now has priority of 0
      c = Container.find_by_uuid(cr.container_uuid)
      assert_equal 0, c.priority
    end
  end

  test "delete container_request in final state and expect no error due to before_destroy callback" do
    act_as_user users(:active) do
      cr = ContainerRequest.find_by_uuid container_requests(:completed).uuid
      assert_nothing_raised {cr.destroy}
    end
  end
end
