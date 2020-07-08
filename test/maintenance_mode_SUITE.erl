%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at https://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2020 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(maintenance_mode_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all() ->
    [
      {group, cluster_size_3}
    ].

groups() ->
    [
      {cluster_size_3, [], [
          maintenance_mode_status,
          listener_suspension_status,
          client_connection_closure,
          queue_leadership_transition
        ]}
    ].

%% -------------------------------------------------------------------
%% Setup and teardown.
%% -------------------------------------------------------------------

init_per_suite(Config) ->
    rabbit_ct_helpers:log_environment(),
    rabbit_ct_helpers:run_setup_steps(Config).

end_per_suite(Config) ->
    rabbit_ct_helpers:run_teardown_steps(Config).

init_per_group(cluster_size_3, Config) ->
    rabbit_ct_helpers:set_config(Config, [
        {rmq_nodes_count, 3}
      ]).

end_per_group(_, Config) ->
    Config.

init_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_started(Config, Testcase),
    ClusterSize = ?config(rmq_nodes_count, Config),
    TestNumber = rabbit_ct_helpers:testcase_number(Config, ?MODULE, Testcase),
    Config1 = rabbit_ct_helpers:set_config(Config, [
        {rmq_nodes_clustered, true},
        {rmq_nodename_suffix, Testcase},
        {tcp_ports_base, {skip_n_nodes, TestNumber * ClusterSize}}
      ]),
    rabbit_ct_helpers:run_steps(Config1,
      rabbit_ct_broker_helpers:setup_steps() ++
      rabbit_ct_client_helpers:setup_steps() ++ [
        fun rabbit_ct_broker_helpers:set_ha_policy_all/1
      ]).

end_per_testcase(Testcase, Config) ->
    Config1 = rabbit_ct_helpers:run_steps(Config,
      rabbit_ct_client_helpers:teardown_steps() ++
      rabbit_ct_broker_helpers:teardown_steps()),
    rabbit_ct_helpers:testcase_finished(Config1, Testcase).

%% -------------------------------------------------------------------
%% Test Cases
%% -------------------------------------------------------------------

maintenance_mode_status(Config) ->
    Nodes = [A, B, C] = rabbit_ct_broker_helpers:get_node_configs(Config, nodename),
    
    [begin
         ?assertNot(rabbit_ct_broker_helpers:is_being_drained_local_read(Config, Node)),
         ?assertNot(rabbit_ct_broker_helpers:is_being_drained_consistent_read(Config, Node))
     end || Node <- Nodes],
    
    [begin
        [begin
             ?assertNot(rabbit_ct_broker_helpers:is_being_drained_consistent_read(Config, TargetNode, NodeToCheck))
        end || NodeToCheck <- Nodes]
     end || TargetNode <- Nodes],

    rabbit_ct_broker_helpers:mark_as_being_drained(Config, B),
    rabbit_ct_helpers:await_condition(
        fun () -> rabbit_ct_broker_helpers:is_being_drained_local_read(Config, B) end,
        10000),
    
    [begin
         ?assert(rabbit_ct_broker_helpers:is_being_drained_consistent_read(Config, TargetNode, B))
     end || TargetNode <- Nodes],
    
    ?assertEqual(
        lists:usort([A, C]),
        lists:usort(rabbit_ct_broker_helpers:rpc(Config, B,
                        rabbit_maintenance, primary_replica_transfer_candidate_nodes, []))),
    
    rabbit_ct_broker_helpers:unmark_as_being_drained(Config, B),
    rabbit_ct_helpers:await_condition(
        fun () -> not rabbit_ct_broker_helpers:is_being_drained_local_read(Config, B) end,
        10000),
    
    [begin
         ?assertNot(rabbit_ct_broker_helpers:is_being_drained_local_read(Config, TargetNode, B)),
         ?assertNot(rabbit_ct_broker_helpers:is_being_drained_consistent_read(Config, TargetNode, B))
     end || TargetNode <- Nodes],
    
    ?assertEqual(
        lists:usort([A, C]),
        lists:usort(rabbit_ct_broker_helpers:rpc(Config, B,
                        rabbit_maintenance, primary_replica_transfer_candidate_nodes, []))),
    
    ok.


listener_suspension_status(Config) ->
    Nodes = [A | _] = rabbit_ct_broker_helpers:get_node_configs(Config, nodename),
    ct:pal("Picked node ~s for maintenance tests...", [A]),
    
    rabbit_ct_helpers:await_condition(
        fun () -> not rabbit_ct_broker_helpers:is_being_drained_local_read(Config, A) end, 10000),

    [begin
         ?assertNot(rabbit_ct_broker_helpers:is_being_drained_consistent_read(Config, Node))
     end || Node <- Nodes],

    Conn1 = rabbit_ct_client_helpers:open_connection(Config, A),
    ?assert(is_pid(Conn1)),
    rabbit_ct_client_helpers:close_connection(Conn1),

    rabbit_ct_broker_helpers:drain_node(Config, A),
    rabbit_ct_helpers:await_condition(
        fun () -> rabbit_ct_broker_helpers:is_being_drained_local_read(Config, A) end, 10000),

    ?assertEqual({error, econnrefused}, rabbit_ct_client_helpers:open_unmanaged_connection(Config, A)),

    rabbit_ct_broker_helpers:revive_node(Config, A),
    rabbit_ct_helpers:await_condition(
        fun () -> not rabbit_ct_broker_helpers:is_being_drained_local_read(Config, A) end, 10000),

    Conn3 = rabbit_ct_client_helpers:open_connection(Config, A),
    ?assert(is_pid(Conn3)),
    rabbit_ct_client_helpers:close_connection(Conn3),

    ok.


client_connection_closure(Config) ->
    [A | _] = rabbit_ct_broker_helpers:get_node_configs(Config, nodename),
    ct:pal("Picked node ~s for maintenance tests...", [A]),

    rabbit_ct_helpers:await_condition(
        fun () -> not rabbit_ct_broker_helpers:is_being_drained_local_read(Config, A) end, 10000),

    Conn1 = rabbit_ct_client_helpers:open_connection(Config, A),
    ?assert(is_pid(Conn1)),
    ?assertEqual(1, length(rabbit_ct_broker_helpers:rpc(Config, A, rabbit_networking, local_connections, []))),

    rabbit_ct_broker_helpers:drain_node(Config, A),
    ?assertEqual(0, length(rabbit_ct_broker_helpers:rpc(Config, A, rabbit_networking, local_connections, []))),

    rabbit_ct_broker_helpers:revive_node(Config, A).


queue_leadership_transition(Config) ->
    [A | _] = rabbit_ct_broker_helpers:get_node_configs(Config, nodename),
    ct:pal("Picked node ~s for maintenance tests...", [A]),

    rabbit_ct_helpers:await_condition(
        fun () -> not rabbit_ct_broker_helpers:is_being_drained_local_read(Config, A) end, 10000),

    PolicyPattern = <<"^cq.mirrored">>,
    rabbit_ct_broker_helpers:set_ha_policy(Config, A, PolicyPattern, <<"all">>),

    Conn = rabbit_ct_client_helpers:open_connection(Config, A),
    {ok, Ch} = amqp_connection:open_channel(Conn),
    QName = <<"cq.mirrored.1">>,
    amqp_channel:call(Ch, #'queue.declare'{queue = QName, durable = true}),

    ?assertEqual(1, length(rabbit_ct_broker_helpers:rpc(Config, A, rabbit_amqqueue, list_local, [<<"/">>]))),

    rabbit_ct_broker_helpers:drain_node(Config, A),
    rabbit_ct_helpers:await_condition(
        fun () -> rabbit_ct_broker_helpers:is_being_drained_local_read(Config, A) end, 10000),

    ?assertEqual(0, length(rabbit_ct_broker_helpers:rpc(Config, A, rabbit_amqqueue, list_local, [<<"/">>]))),

    rabbit_ct_broker_helpers:revive_node(Config, A),
    %% rabbit_ct_broker_helpers:set_ha_policy/4 uses pattern for policy name
    rabbit_ct_broker_helpers:clear_policy(Config, A, PolicyPattern).
