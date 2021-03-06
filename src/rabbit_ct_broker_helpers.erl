%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2015 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_ct_broker_helpers).

-include_lib("common_test/include/ct.hrl").
-include_lib("kernel/include/inet.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").

-export([
    setup_steps/0,
    teardown_steps/0,
    start_rabbitmq_nodes/1,
    stop_rabbitmq_nodes/1,
    rewrite_node_config_file/2,
    cluster_nodes/1, cluster_nodes/2,

    get_node_configs/1, get_node_configs/2,
    get_node_config/2, get_node_config/3, set_node_config/3,
    nodename_to_index/2,
    node_uri/2, node_uri/3,

    control_action/2, control_action/3, control_action/4,
    rabbitmqctl/3, rabbitmqctl_list/3,

    add_code_path_to_node/2,
    add_code_path_to_all_nodes/2,
    rpc/5, rpc/6,
    rpc_all/4, rpc_all/5,

    start_node/2,
    start_broker/2,
    restart_broker/2,
    stop_broker/2,
    restart_node/2,
    stop_node/2,
    stop_node_after/3,
    kill_node/2,
    kill_node_after/3,

    set_partition_handling_mode/3,
    set_partition_handling_mode_globally/2,
    enable_dist_proxy_manager/1,
    enable_dist_proxy/1,
    enable_dist_proxy_on_node/3,
    block_traffic_between/2,
    allow_traffic_between/2,

    get_connection_pids/1,
    get_queue_sup_pid/1,

    set_policy/6,
    set_policy/7,
    clear_policy/3,
    clear_policy/4,
    set_operator_policy/6,
    clear_operator_policy/3,
    set_ha_policy/4, set_ha_policy/5,
    set_ha_policy_all/1,
    set_ha_policy_two_pos/1,
    set_ha_policy_two_pos_batch_sync/1,

    set_parameter/5,
    set_parameter/6,
    set_parameter/7,
    clear_parameter/4,
    clear_parameter/5,
    clear_parameter/6,

    set_global_parameter/3,
    set_global_parameter/4,
    clear_global_parameter/2,
    clear_global_parameter/3,

    add_vhost/2,
    add_vhost/3,
    add_vhost/4,
    delete_vhost/2,
    delete_vhost/3,
    delete_vhost/4,

    add_user/2,
    add_user/3,
    add_user/4,
    add_user/5,
    set_user_tags/4,
    set_user_tags/5,

    delete_user/2,
    delete_user/3,
    delete_user/4,

    change_password/5,
    clear_password/4,

    change_password/3,

    switch_credential_validator/2,
    switch_credential_validator/3,

    set_permissions/6,
    set_permissions/7,
    set_permissions/8,
    set_full_permissions/2,
    set_full_permissions/3,
    set_full_permissions/4,

    clear_permissions/2,
    clear_permissions/3,
    clear_permissions/4,
    clear_permissions/5,

    enable_plugin/3,
    disable_plugin/3,

    test_channel/0
  ]).

%% Internal functions exported to be used by rpc:call/4.
-export([
    do_restart_broker/0
  ]).

-define(DEFAULT_USER, "guest").
-define(NODE_START_ATTEMPTS, 10).

-define(TCP_PORTS_BASE, 21000).
-define(TCP_PORTS_LIST, [
    tcp_port_amqp,
    tcp_port_amqp_tls,
    tcp_port_mgmt,
    tcp_port_erlang_dist,
    tcp_port_erlang_dist_proxy,
    tcp_port_mqtt,
    tcp_port_mqtt_tls,
    tcp_port_web_mqtt,
    tcp_port_stomp,
    tcp_port_stomp_tls,
    tcp_port_web_stomp
  ]).

%% -------------------------------------------------------------------
%% Broker setup/teardown steps.
%% -------------------------------------------------------------------

setup_steps() ->
    [
      fun run_make_dist/1,
      fun start_rabbitmq_nodes/1,
      fun share_dist_and_proxy_ports_map/1
    ].

teardown_steps() ->
    [
      fun stop_rabbitmq_nodes/1
    ].

run_make_dist(Config) ->
    case os:getenv("SKIP_MAKE_TEST_DIST") of
        false ->
            SrcDir = ?config(current_srcdir, Config),
            case rabbit_ct_helpers:make(Config, SrcDir, ["test-dist"]) of
                {ok, _} ->
                    %% The caller can set $SKIP_MAKE_TEST_DIST to
                    %% manually skip this step which can be time
                    %% consuming. But we also use this variable to
                    %% record the fact we went through it already so we
                    %% save redundant calls.
                    os:putenv("SKIP_MAKE_TEST_DIST", "true"),
                    Config;
                _ ->
                    {skip, "Failed to run \"make test-dist\""}
            end;
        _ ->
            ct:pal(?LOW_IMPORTANCE, "(skip `$MAKE test-dist`)", []),
            Config
    end.

start_rabbitmq_nodes(Config) ->
    Config1 = rabbit_ct_helpers:set_config(Config, [
        {rmq_username, list_to_binary(?DEFAULT_USER)},
        {rmq_password, list_to_binary(?DEFAULT_USER)},
        {rmq_hostname, "localhost"},
        {rmq_vhost, <<"/">>},
        {rmq_channel_max, 0}]),
    NodesCount0 = rabbit_ct_helpers:get_config(Config1, rmq_nodes_count),
    NodesCount = case NodesCount0 of
        undefined                                -> 1;
        N when is_integer(N) andalso N >= 1      -> N;
        L when is_list(L) andalso length(L) >= 1 -> length(L)
    end,
    Clustered0 = rabbit_ct_helpers:get_config(Config1, rmq_nodes_clustered),
    Clustered = case Clustered0 of
        undefined            -> true;
        C when is_boolean(C) -> C
    end,
    Master = self(),
    Starters = [
      spawn_link(fun() -> start_rabbitmq_node(Master, Config1, [], I) end)
      || I <- lists:seq(0, NodesCount - 1)
    ],
    wait_for_rabbitmq_nodes(Config1, Starters, [], Clustered).

wait_for_rabbitmq_nodes(Config, [], NodeConfigs, Clustered) ->
    NodeConfigs1 = [NC || {_, NC} <- lists:keysort(1, NodeConfigs)],
    Config1 = rabbit_ct_helpers:set_config(Config, {rmq_nodes, NodeConfigs1}),
    if
        Clustered -> cluster_nodes(Config1);
        true      -> Config1
    end;
wait_for_rabbitmq_nodes(Config, Starting, NodeConfigs, Clustered) ->
    receive
        {_, {skip, _} = Error} ->
            NodeConfigs1 = [NC || {_, NC} <- NodeConfigs],
            Config1 = rabbit_ct_helpers:set_config(Config,
              {rmq_nodes, NodeConfigs1}),
            stop_rabbitmq_nodes(Config1),
            Error;
        {Pid, I, NodeConfig} when NodeConfigs =:= [] ->
            wait_for_rabbitmq_nodes(Config, Starting -- [Pid],
              [{I, NodeConfig} | NodeConfigs], Clustered);
        {Pid, I, NodeConfig} ->
            wait_for_rabbitmq_nodes(Config, Starting -- [Pid],
              [{I, NodeConfig} | NodeConfigs], Clustered)
    end.

%% To start a RabbitMQ node, we need to:
%%   1. Pick TCP port numbers
%%   2. Generate a node name
%%   3. Write a configuration file
%%   4. Start the node
%%
%% If this fails (usually because the node name is taken or a TCP port
%% is already in use), we start again with another set of TCP ports. The
%% node name is derived from the AMQP TCP port so a new node name is
%% generated.

start_rabbitmq_node(Master, Config, NodeConfig, I) ->
    Attempts0 = rabbit_ct_helpers:get_config(NodeConfig, failed_boot_attempts),
    Attempts = case Attempts0 of
        undefined -> 0;
        N         -> N
    end,
    NodeConfig1 = init_tcp_port_numbers(Config, NodeConfig, I),
    NodeConfig2 = init_nodename(Config, NodeConfig1, I),
    NodeConfig3 = init_config_filename(Config, NodeConfig2, I),
    Steps = [
      fun write_config_file/3,
      fun do_start_rabbitmq_node/3
    ],
    case run_node_steps(Config, NodeConfig3, I, Steps) of
        {skip, _} = Error
        when Attempts >= ?NODE_START_ATTEMPTS ->
            %% It's unlikely we'll ever succeed to start RabbitMQ.
            Master ! {self(), Error},
            unlink(Master);
        {skip, _} ->
            %% Try again with another TCP port numbers base.
            NodeConfig4 = move_nonworking_nodedir_away(NodeConfig3),
            NodeConfig5 = rabbit_ct_helpers:set_config(NodeConfig4,
              {failed_boot_attempts, Attempts + 1}),
            start_rabbitmq_node(Master, Config, NodeConfig5, I);
        NodeConfig4 ->
            Master ! {self(), I, NodeConfig4},
            unlink(Master)
    end.

run_node_steps(Config, NodeConfig, I, [Step | Rest]) ->
    case Step(Config, NodeConfig, I) of
        {skip, _} = Error -> Error;
        NodeConfig1       -> run_node_steps(Config, NodeConfig1, I, Rest)
    end;
run_node_steps(_, NodeConfig, _, []) ->
    NodeConfig.

init_tcp_port_numbers(Config, NodeConfig, I) ->
    %% If there is no TCP port numbers base previously calculated,
    %% use the TCP port 21000. If a base was previously calculated,
    %% increment it by the number of TCP ports we may open.
    %%
    %% Port 21000 is an arbitrary choice. We don't want to use the
    %% default AMQP port of 5672 so other AMQP clients on the same host
    %% do not accidentally use the testsuite broker. There seems to be
    %% no registered service around this port in /etc/services. And it
    %% should be far enough away from the default ephemeral TCP ports
    %% range.
    ExtraPorts = case rabbit_ct_helpers:get_config(Config, rmq_extra_tcp_ports) of
        undefined           -> [];
        EP when is_list(EP) -> EP
    end,
    PortsCount = length(?TCP_PORTS_LIST) + length(ExtraPorts),
    Base = case rabbit_ct_helpers:get_config(NodeConfig, tcp_ports_base) of
        undefined -> tcp_port_base_for_broker(Config, I, PortsCount);
        P         -> P + PortsCount
    end,
    NodeConfig1 = rabbit_ct_helpers:set_config(NodeConfig,
      {tcp_ports_base, Base}),
    %% Now, compute all TCP port numbers from this base.
    {NodeConfig2, _} = lists:foldl(
      fun(PortName, {NewConfig, NextPort}) ->
          {
            rabbit_ct_helpers:set_config(NewConfig, {PortName, NextPort}),
            NextPort + 1
          }
      end,
      {NodeConfig1, Base}, ?TCP_PORTS_LIST ++ ExtraPorts),
    %% Finally, update the RabbitMQ configuration with the computed TCP
    %% port numbers. Extra TCP ports are not added automatically to the
    %% configuration.
    update_tcp_ports_in_rmq_config(NodeConfig2, ?TCP_PORTS_LIST).

tcp_port_base_for_broker(Config, I, PortsCount) ->
    Base = case rabbit_ct_helpers:get_config(Config, tcp_ports_base) of
        undefined ->
            ?TCP_PORTS_BASE;
        {skip_n_nodes, N} ->
            tcp_port_base_for_broker1(?TCP_PORTS_BASE, N, PortsCount);
        B ->
            B
    end,
    tcp_port_base_for_broker1(Base, I, PortsCount).

tcp_port_base_for_broker1(Base, I, PortsCount) ->
    Base + I * PortsCount * ?NODE_START_ATTEMPTS.

update_tcp_ports_in_rmq_config(NodeConfig, [tcp_port_amqp = Key | Rest]) ->
    NodeConfig1 = rabbit_ct_helpers:merge_app_env(NodeConfig,
      {rabbit, [{tcp_listeners, [?config(Key, NodeConfig)]}]}),
    update_tcp_ports_in_rmq_config(NodeConfig1, Rest);
update_tcp_ports_in_rmq_config(NodeConfig, [tcp_port_amqp_tls = Key | Rest]) ->
    NodeConfig1 = rabbit_ct_helpers:merge_app_env(NodeConfig,
      {rabbit, [{ssl_listeners, [?config(Key, NodeConfig)]}]}),
    update_tcp_ports_in_rmq_config(NodeConfig1, Rest);
update_tcp_ports_in_rmq_config(NodeConfig, [tcp_port_mgmt = Key | Rest]) ->
    NodeConfig1 = rabbit_ct_helpers:merge_app_env(NodeConfig,
      {rabbitmq_management, [{listener, [{port, ?config(Key, NodeConfig)}]}]}),
    update_tcp_ports_in_rmq_config(NodeConfig1, Rest);
update_tcp_ports_in_rmq_config(NodeConfig, [tcp_port_mqtt = Key | Rest]) ->
    NodeConfig1 = rabbit_ct_helpers:merge_app_env(NodeConfig,
      {rabbitmq_mqtt, [{tcp_listeners, [?config(Key, NodeConfig)]}]}),
    update_tcp_ports_in_rmq_config(NodeConfig1, Rest);
update_tcp_ports_in_rmq_config(NodeConfig, [tcp_port_mqtt_tls = Key | Rest]) ->
    NodeConfig1 = rabbit_ct_helpers:merge_app_env(NodeConfig,
      {rabbitmq_mqtt, [{ssl_listeners, [?config(Key, NodeConfig)]}]}),
    update_tcp_ports_in_rmq_config(NodeConfig1, Rest);
update_tcp_ports_in_rmq_config(NodeConfig, [tcp_port_web_mqtt = Key | Rest]) ->
    NodeConfig1 = rabbit_ct_helpers:merge_app_env(NodeConfig,
      {rabbitmq_web_mqtt, [{tcp_config, [{port, ?config(Key, NodeConfig)}]}]}),
    update_tcp_ports_in_rmq_config(NodeConfig1, Rest);
update_tcp_ports_in_rmq_config(NodeConfig, [tcp_port_web_stomp = Key | Rest]) ->
    NodeConfig1 = rabbit_ct_helpers:merge_app_env(NodeConfig,
      {rabbitmq_web_stomp, [{tcp_config, [{port, ?config(Key, NodeConfig)}]}]}),
    update_tcp_ports_in_rmq_config(NodeConfig1, Rest);
update_tcp_ports_in_rmq_config(NodeConfig, [tcp_port_stomp = Key | Rest]) ->
    NodeConfig1 = rabbit_ct_helpers:merge_app_env(NodeConfig,
      {rabbitmq_stomp, [{tcp_listeners, [?config(Key, NodeConfig)]}]}),
    update_tcp_ports_in_rmq_config(NodeConfig1, Rest);
update_tcp_ports_in_rmq_config(NodeConfig, [tcp_port_stomp_tls = Key | Rest]) ->
    NodeConfig1 = rabbit_ct_helpers:merge_app_env(NodeConfig,
      {rabbitmq_stomp, [{ssl_listeners, [?config(Key, NodeConfig)]}]}),
    update_tcp_ports_in_rmq_config(NodeConfig1, Rest);
update_tcp_ports_in_rmq_config(NodeConfig, [tcp_port_erlang_dist | Rest]) ->
    %% The Erlang distribution port doesn't appear in the configuration file.
    update_tcp_ports_in_rmq_config(NodeConfig, Rest);
update_tcp_ports_in_rmq_config(NodeConfig, [tcp_port_erlang_dist_proxy | Rest]) ->
    %% inet_proxy_dist port doesn't appear in the configuration file.
    update_tcp_ports_in_rmq_config(NodeConfig, Rest);
update_tcp_ports_in_rmq_config(NodeConfig, []) ->
    NodeConfig.

init_nodename(Config, NodeConfig, I) ->
    Nodename0 = case rabbit_ct_helpers:get_config(Config, rmq_nodes_count) of
        NodesList when is_list(NodesList) ->
            Name = lists:nth(I + 1, NodesList),
            rabbit_misc:format("~s@localhost", [Name]);
        _ ->
            Base = ?config(tcp_ports_base, NodeConfig),
            Suffix0 = rabbit_ct_helpers:get_config(Config,
              rmq_nodename_suffix),
            Suffix = case Suffix0 of
                undefined               -> "";
                _ when is_atom(Suffix0) -> [$- | atom_to_list(Suffix0)];
                _                       -> [$- | Suffix0]
            end,
            rabbit_misc:format("rmq-ct~s-~b-~b@localhost",
              [Suffix, I + 1, Base])
    end,
    Nodename = list_to_atom(Nodename0),
    rabbit_ct_helpers:set_config(NodeConfig, [
        {nodename, Nodename},
        {initial_nodename, Nodename}
      ]).

init_config_filename(Config, NodeConfig, _I) ->
    PrivDir = ?config(priv_dir, Config),
    Nodename = ?config(nodename, NodeConfig),
    ConfigDir = filename:join(PrivDir, Nodename),
    ConfigFile = filename:join(ConfigDir, Nodename),
    rabbit_ct_helpers:set_config(NodeConfig,
      {erlang_node_config_filename, ConfigFile}).

write_config_file(Config, NodeConfig, _I) ->
    %% Prepare a RabbitMQ configuration.
    ErlangConfigBase = ?config(erlang_node_config, Config),
    ErlangConfigOverlay = ?config(erlang_node_config, NodeConfig),
    ErlangConfig = rabbit_ct_helpers:merge_app_env_in_erlconf(ErlangConfigBase,
      ErlangConfigOverlay),
    ConfigFile = ?config(erlang_node_config_filename, NodeConfig),
    ConfigDir = filename:dirname(ConfigFile),
    Ret1 = file:make_dir(ConfigDir),
    Ret2 = file:write_file(ConfigFile ++ ".config",
      io_lib:format("% vim:ft=erlang:~n~n~p.~n", [ErlangConfig])),
    case {Ret1, Ret2} of
        {ok, ok} ->
            NodeConfig;
        {{error, eexist}, ok} ->
            NodeConfig;
        {{error, Reason}, _} when Reason =/= eexist ->
            {skip, "Failed to create Erlang node config directory \"" ++
             ConfigDir ++ "\": " ++ file:format_error(Reason)};
        {_, {error, Reason}} ->
            {skip, "Failed to create Erlang node config file \"" ++
             ConfigFile ++ "\": " ++ file:format_error(Reason)}
    end.

do_start_rabbitmq_node(Config, NodeConfig, I) ->
    WithPlugins0 = rabbit_ct_helpers:get_config(Config,
      broker_with_plugins),
    WithPlugins = case is_list(WithPlugins0) of
        true  -> lists:nth(I + 1, WithPlugins0);
        false -> WithPlugins0
    end,
    SrcDir = case WithPlugins of
        false -> ?config(rabbit_srcdir, Config);
        _     -> ?config(current_srcdir, Config)
    end,
    PrivDir = ?config(priv_dir, Config),
    Nodename = ?config(nodename, NodeConfig),
    InitialNodename = ?config(initial_nodename, NodeConfig),
    DistPort = ?config(tcp_port_erlang_dist, NodeConfig),
    ConfigFile = ?config(erlang_node_config_filename, NodeConfig),
    %% Use inet_proxy_dist to handle distribution. This is used by the
    %% partitions testsuite.
    DistMod = rabbit_ct_helpers:get_config(Config, erlang_dist_module),
    StartArgs0 = case DistMod of
        undefined ->
            "";
        _ ->
            DistModS = atom_to_list(DistMod),
            DistModPath = filename:absname(
              filename:dirname(code:where_is_file(DistModS ++ ".beam"))),
            DistArg = re:replace(DistModS, "_dist$", "", [{return, list}]),
            "-pa \"" ++ DistModPath ++ "\" -proto_dist " ++ DistArg
    end,
    %% Set the net_ticktime.
    CurrentTicktime = case net_kernel:get_net_ticktime() of
        {ongoing_change_to, T} -> T;
        T                      -> T
    end,
    StartArgs1 = case rabbit_ct_helpers:get_config(Config, net_ticktime) of
        undefined ->
            case CurrentTicktime of
                60 -> ok;
                _  -> net_kernel:set_net_ticktime(60)
            end,
            StartArgs0;
        Ticktime ->
            case CurrentTicktime of
                Ticktime -> ok;
                _        -> net_kernel:set_net_ticktime(Ticktime)
            end,
            StartArgs0 ++ " -kernel net_ticktime " ++ integer_to_list(Ticktime)
    end,
    Cmd = ["start-background-broker",
      {"RABBITMQ_NODENAME=~s", [Nodename]},
      {"RABBITMQ_NODENAME_FOR_PATHS=~s", [InitialNodename]},
      {"RABBITMQ_DIST_PORT=~b", [DistPort]},
      {"RABBITMQ_CONFIG_FILE=~s", [ConfigFile]},
      {"RABBITMQ_SERVER_START_ARGS=~s", [StartArgs1]},
      {"TEST_TMPDIR=~s", [PrivDir]}],
    case rabbit_ct_helpers:make(Config, SrcDir, Cmd) of
        {ok, _} -> query_node(Config, NodeConfig);
        _       -> {skip, "Failed to initialize RabbitMQ"}
    end.

query_node(Config, NodeConfig) ->
    Nodename = ?config(nodename, NodeConfig),
    PidFile = rpc(Config, Nodename, os, getenv, ["RABBITMQ_PID_FILE"]),
    MnesiaDir = rpc(Config, Nodename, mnesia, system_info, [directory]),
    {ok, PluginsDir} = rpc(Config, Nodename, application, get_env,
      [rabbit, plugins_dir]),
    {ok, EnabledPluginsFile} = rpc(Config, Nodename, application, get_env,
      [rabbit, enabled_plugins_file]),
    rabbit_ct_helpers:set_config(NodeConfig, [
        {pid_file, PidFile},
        {mnesia_dir, MnesiaDir},
        {plugins_dir, PluginsDir},
        {enabled_plugins_file, EnabledPluginsFile}
      ]).

cluster_nodes(Config) ->
    [NodeConfig1 | NodeConfigs] = get_node_configs(Config),
    cluster_nodes1(Config, NodeConfig1, NodeConfigs).

cluster_nodes(Config, Nodes) ->
    [NodeConfig1 | NodeConfigs] = [
      get_node_config(Config, Node) || Node <- Nodes],
    cluster_nodes1(Config, NodeConfig1, NodeConfigs).

cluster_nodes1(Config, NodeConfig1, [NodeConfig2 | Rest]) ->
    case cluster_nodes(Config, NodeConfig2, NodeConfig1) of
        ok    -> cluster_nodes1(Config, NodeConfig1, Rest);
        Error -> Error
    end;
cluster_nodes1(Config, _, []) ->
    Config.

cluster_nodes(Config, NodeConfig1, NodeConfig2) ->
    Nodename1 = ?config(nodename, NodeConfig1),
    Nodename2 = ?config(nodename, NodeConfig2),
    Cmds = [
      ["stop_app"],
      ["join_cluster", Nodename2],
      ["start_app"]
    ],
    cluster_nodes1(Config, Nodename1, Nodename2, Cmds).

cluster_nodes1(Config, Nodename1, Nodename2, [Cmd | Rest]) ->
    case rabbitmqctl(Config, Nodename1, Cmd) of
        {ok, _} -> cluster_nodes1(Config, Nodename1, Nodename2, Rest);
        _       -> {skip,
                    "Failed to cluster nodes \"" ++ atom_to_list(Nodename1) ++
                    "\" and \"" ++ atom_to_list(Nodename2) ++ "\""}
    end;
cluster_nodes1(_, _, _, []) ->
    ok.

move_nonworking_nodedir_away(NodeConfig) ->
    ConfigFile = ?config(erlang_node_config_filename, NodeConfig),
    ConfigDir = filename:dirname(ConfigFile),
    NewName = filename:join(
      filename:dirname(ConfigDir),
      "_unused_nodedir_" ++ filename:basename(ConfigDir)),
    file:rename(ConfigDir, NewName),
    lists:keydelete(erlang_node_config_filename, 1, NodeConfig).

share_dist_and_proxy_ports_map(Config) ->
    Map = [
      {
        ?config(tcp_port_erlang_dist, NodeConfig),
        ?config(tcp_port_erlang_dist_proxy, NodeConfig)
      } || NodeConfig <- get_node_configs(Config)],
    rpc_all(Config,
      application, set_env, [kernel, dist_and_proxy_ports_map, Map]),
    Config.

rewrite_node_config_file(Config, Node) ->
    NodeConfig = get_node_config(Config, Node),
    I = if
        is_integer(Node) -> Node;
        true             -> nodename_to_index(Config, Node)
    end,
    %% Keep copies of previous config file.
    ConfigFile = ?config(erlang_node_config_filename, NodeConfig),
    case rotate_config_file(ConfigFile) of
        ok ->
            ok;
        {error, Reason} ->
            ct:pal("Failed to rotate config file ~s: ~s",
              [ConfigFile, file:format_error(Reason)])
    end,
    %% Now we can write the new file. The caller is responsible for
    %% restarting the broker/node.
    case write_config_file(Config, NodeConfig, I) of
        {skip, Error} -> {error, Error};
        _NodeConfig1  -> ok
    end.

rotate_config_file(ConfigFile) ->
    rotate_config_file(ConfigFile, ConfigFile ++ ".config", 1).

rotate_config_file(ConfigFile, OldName, Ext) ->
    NewName = rabbit_misc:format("~s.config.~b", [ConfigFile, Ext]),
    case filelib:is_file(NewName) of
        true  ->
            case rotate_config_file(ConfigFile, NewName, Ext + 1) of
                ok    -> file:rename(OldName, NewName);
                Error -> Error
            end;
        false ->
            file:rename(OldName, NewName)
    end.

stop_rabbitmq_nodes(Config) ->
    NodeConfigs = get_node_configs(Config),
    [stop_rabbitmq_node(Config, NodeConfig) || NodeConfig <- NodeConfigs],
    proplists:delete(rmq_nodes, Config).

stop_rabbitmq_node(Config, NodeConfig) ->
    SrcDir = ?config(current_srcdir, Config),
    PrivDir = ?config(priv_dir, Config),
    Nodename = ?config(nodename, NodeConfig),
    InitialNodename = ?config(initial_nodename, NodeConfig),
    Cmd = ["stop-rabbit-on-node", "stop-node",
      {"RABBITMQ_NODENAME=~s", [Nodename]},
      {"RABBITMQ_NODENAME_FOR_PATHS=~s", [InitialNodename]},
      {"TEST_TMPDIR=~s", [PrivDir]}],
    rabbit_ct_helpers:make(Config, SrcDir, Cmd),
    NodeConfig.

%% -------------------------------------------------------------------
%% Helpers for partition simulation
%% -------------------------------------------------------------------

enable_dist_proxy_manager(Config) ->
    inet_tcp_proxy_manager:start(),
    rabbit_ct_helpers:set_config(Config,
      {erlang_dist_module, inet_proxy_dist}).

enable_dist_proxy(Config) ->
    NodeConfigs = rabbit_ct_broker_helpers:get_node_configs(Config),
    Nodes = [?config(nodename, NodeConfig) || NodeConfig <- NodeConfigs],
    ManagerNode = node(),
    ok = lists:foreach(
      fun(NodeConfig) ->
          ok = rabbit_ct_broker_helpers:rpc(Config,
            ?config(nodename, NodeConfig),
            ?MODULE, enable_dist_proxy_on_node,
            [NodeConfig, ManagerNode, Nodes])
      end, NodeConfigs),
    Config.

enable_dist_proxy_on_node(NodeConfig, ManagerNode, Nodes) ->
    Nodename = ?config(nodename, NodeConfig),
    DistPort = ?config(tcp_port_erlang_dist, NodeConfig),
    ProxyPort = ?config(tcp_port_erlang_dist_proxy, NodeConfig),
    ok = inet_tcp_proxy:start(ManagerNode, DistPort, ProxyPort),
    ok = inet_tcp_proxy:reconnect(Nodes -- [Nodename]).

block_traffic_between(NodeA, NodeB) ->
    rpc:call(NodeA, inet_tcp_proxy, block, [NodeB]),
    rpc:call(NodeB, inet_tcp_proxy, block, [NodeA]).

allow_traffic_between(NodeA, NodeB) ->
    rpc:call(NodeA, inet_tcp_proxy, allow, [NodeB]),
    rpc:call(NodeB, inet_tcp_proxy, allow, [NodeA]).

set_partition_handling_mode_globally(Config, Mode) ->
    rabbit_ct_broker_helpers:rpc_all(Config,
      application, set_env, [rabbit, cluster_partition_handling, Mode]).

set_partition_handling_mode(Config, Nodes, Mode) ->
    rabbit_ct_broker_helpers:rpc(Config, Nodes,
      application, set_env, [rabbit, cluster_partition_handling, Mode]).

%% -------------------------------------------------------------------
%% Calls to rabbitmqctl from Erlang.
%% -------------------------------------------------------------------

control_action(Command, Node) ->
    control_action(Command, Node, [], []).

control_action(Command, Node, Args) ->
    control_action(Command, Node, Args, []).

control_action(Command, Node, Args, Opts) ->
    rabbit_control_helper:command(Command, Node, Args, Opts).

%% Use rabbitmqctl(1) instead of using the Erlang API.

rabbitmqctl(Config, Node, Args) ->
    Rabbitmqctl = ?config(rabbitmqctl_cmd, Config),
    NodeConfig = get_node_config(Config, Node),
    Nodename = ?config(nodename, NodeConfig),
    Env = [
      {"RABBITMQ_PID_FILE", ?config(pid_file, NodeConfig)},
      {"RABBITMQ_MNESIA_DIR", ?config(mnesia_dir, NodeConfig)},
      {"RABBITMQ_PLUGINS_DIR", ?config(plugins_dir, NodeConfig)},
      {"RABBITMQ_ENABLED_PLUGINS_FILE",
        ?config(enabled_plugins_file, NodeConfig)}
    ],
    Cmd = [Rabbitmqctl, "-n", Nodename | Args],
    rabbit_ct_helpers:exec(Cmd, [{env, Env}]).

rabbitmqctl_list(Config, Node, Args) ->
    {ok, StdOut} = rabbitmqctl(Config, Node, Args),
    [<<"Listing", _/binary>>|Rows] = re:split(StdOut, <<"\n">>, [trim]),
    [re:split(Row, <<"\t">>) || Row <- Rows].

%% -------------------------------------------------------------------
%% Other helpers.
%% -------------------------------------------------------------------

get_node_configs(Config) ->
    ?config(rmq_nodes, Config).

get_node_configs(Config, Key) ->
    NodeConfigs = get_node_configs(Config),
    [?config(Key, NodeConfig) || NodeConfig <- NodeConfigs].

get_node_config(Config, Node) when is_atom(Node) andalso Node =/= undefined ->
    NodeConfigs = get_node_configs(Config),
    get_node_config1(NodeConfigs, Node);
get_node_config(Config, I) when is_integer(I) andalso I >= 0 ->
    NodeConfigs = get_node_configs(Config),
    lists:nth(I + 1, NodeConfigs).

get_node_config1([NodeConfig | Rest], Node) ->
    case ?config(nodename, NodeConfig) of
        Node -> NodeConfig;
        _    -> case ?config(initial_nodename, NodeConfig) of
                    Node -> NodeConfig;
                    _    -> get_node_config1(Rest, Node)
                end
    end;
get_node_config1([], Node) ->
    exit({unknown_node, Node}).

get_node_config(Config, Node, Key) ->
    NodeConfig = get_node_config(Config, Node),
    ?config(Key, NodeConfig).

set_node_config(Config, Node, Tuples) ->
    NodeConfig = get_node_config(Config, Node),
    NodeConfig1 = rabbit_ct_helpers:set_config(NodeConfig, Tuples),
    replace_entire_node_config(Config, Node, NodeConfig1).

replace_entire_node_config(Config, Node, NewNodeConfig) ->
    NodeConfigs = get_node_configs(Config),
    NodeConfigs1 = lists:map(
      fun(NodeConfig) ->
          Match = case ?config(nodename, NodeConfig) of
              Node -> true;
              _    -> case ?config(initial_nodename, NodeConfig) of
                      Node -> true;
                      _    -> false
                  end
          end,
          if
              Match -> NewNodeConfig;
              true  -> NodeConfig
          end
      end, NodeConfigs),
    rabbit_ct_helpers:set_config(Config, {rmq_nodes, NodeConfigs1}).

nodename_to_index(Config, Node) ->
    NodeConfigs = get_node_configs(Config),
    nodename_to_index1(NodeConfigs, Node, 0).

nodename_to_index1([NodeConfig | Rest], Node, I) ->
    case ?config(nodename, NodeConfig) of
        Node -> I;
        _    -> case ?config(initial_nodename, NodeConfig) of
                    Node -> I;
                    _    -> nodename_to_index1(Rest, Node, I + 1)
                end
    end;
nodename_to_index1([], Node, _) ->
    exit({unknown_node, Node}).

node_uri(Config, Node) ->
    node_uri(Config, Node, []).

node_uri(Config, Node, amqp) ->
    node_uri(Config, Node, []);
node_uri(Config, Node, management) ->
    node_uri(Config, Node, [
        {scheme, "http"},
        {tcp_port_name, tcp_port_mgmt}
      ]);
node_uri(Config, Node, Options) ->
    Scheme = proplists:get_value(scheme, Options, "amqp"),
    Hostname = case proplists:get_value(use_ipaddr, Options, false) of
        true ->
            {ok, Hostent} = inet:gethostbyname(?config(rmq_hostname, Config)),
            format_ipaddr_for_uri(Hostent);
        Family when Family =:= inet orelse Family =:= inet6 ->
            {ok, Hostent} = inet:gethostbyname(?config(rmq_hostname, Config),
              Family),
            format_ipaddr_for_uri(Hostent);
        false ->
            ?config(rmq_hostname, Config)
    end,
    TcpPortName = proplists:get_value(tcp_port_name, Options, tcp_port_amqp),
    TcpPort = get_node_config(Config, Node, TcpPortName),
    UserPass = case proplists:get_value(with_user, Options, false) of
        true ->
            User = proplists:get_value(user, Options, "guest"),
            Password = proplists:get_value(password, Options, "guest"),
            io_lib:format("~s:~s@", [User, Password]);
        false ->
            ""
    end,
    list_to_binary(
      rabbit_misc:format("~s://~s~s:~b",
        [Scheme, UserPass, Hostname, TcpPort])).

format_ipaddr_for_uri(
  #hostent{h_addrtype = inet, h_addr_list = [IPAddr | _]}) ->
    {A, B, C, D} = IPAddr,
    io_lib:format("~b.~b.~b.~b", [A, B, C, D]);
format_ipaddr_for_uri(
  #hostent{h_addrtype = inet6, h_addr_list = [IPAddr | _]}) ->
    {A, B, C, D, E, F, G, H} = IPAddr,
    Res0 = io_lib:format(
      "~.16b:~.16b:~.16b:~.16b:~.16b:~.16b:~.16b:~.16b",
      [A, B, C, D, E, F, G, H]),
    Res1 = re:replace(Res0, "(^0(:0)+$|^(0:)+|(:0)+$)|:(0:)+", "::"),
    "[" ++ Res1 ++ "]".


%% Virtual host management

add_vhost(Config, VHost) ->
    add_vhost(Config, 0, VHost).

add_vhost(Config, Node, VHost) ->
    add_vhost(Config, Node, VHost, <<"acting-user">>).

add_vhost(Config, Node, VHost, Username) ->
    rabbit_ct_broker_helpers:rpc(Config, Node, rabbit_vhost, add, [VHost, Username]).

delete_vhost(Config, VHost) ->
    delete_vhost(Config, 0, VHost).

delete_vhost(Config, Node, VHost) ->
    delete_vhost(Config, Node, VHost, <<"acting-user">>).

delete_vhost(Config, Node, VHost, Username) ->
    rabbit_ct_broker_helpers:rpc(Config, Node, rabbit_vhost, delete, [VHost, Username]).

add_user(Config, Username) ->
    %% for many tests it is convenient that
    %% the username and password match
    add_user(Config, 0, Username, Username).

add_user(Config, Username, Password) ->
    add_user(Config, 0, Username, Password).

add_user(Config, Node, Username, Password) ->
    add_user(Config, Node, Username, Password, <<"acting-user">>).

add_user(Config, Node, Username, Password, AuditUsername) ->
    rabbit_ct_broker_helpers:rpc(Config, Node, rabbit_auth_backend_internal, add_user,
        [rabbit_data_coercion:to_binary(Username),
         rabbit_data_coercion:to_binary(Password),
         AuditUsername]).

set_user_tags(Config, Node, Username, Tags) ->
    set_user_tags(Config, Node, Username, Tags, <<"acting-user">>).

set_user_tags(Config, Node, Username, Tags, AuditUsername) ->
    rabbit_ct_broker_helpers:rpc(Config, Node, rabbit_auth_backend_internal, set_tags,
                                 [Username, Tags, AuditUsername]).

delete_user(Config, Username) ->
    delete_user(Config, 0, Username).

delete_user(Config, Node, Username) ->
    delete_user(Config, Node, Username, <<"acting-user">>).

delete_user(Config, Node, Username, AuditUsername) ->
    rpc(Config, Node, rabbit_auth_backend_internal, delete_user,
        [Username, AuditUsername]).

change_password(Config, Username, Password) ->
    change_password(Config, 0, Username, Password, <<"acting-user">>).

change_password(Config, Node, Username, Password, AuditUsername) ->
    rpc(Config, Node, rabbit_auth_backend_internal, change_password,
                                 [Username, Password, AuditUsername]).

clear_password(Config, Node, Username, AuditUsername) ->
    rpc(Config, Node, rabbit_auth_backend_internal, clear_password,
        [Username, AuditUsername]).

switch_credential_validator(Config, accept_everything) ->
    rpc(Config, 0, application, set_env,
        [rabbit, credential_validator,
         [{validation_backend, rabbit_credential_validator_accept_everything}]]);

switch_credential_validator(Config, min_length) ->
    switch_credential_validator(Config, min_length, 5);

switch_credential_validator(Config, regexp) ->
    switch_credential_validator(Config, regexp, <<"^xyz\\d{10,12}$">>).


switch_credential_validator(Config, min_length, MinLength) ->
    ok = rpc(Config, 0, application, set_env,
             [rabbit, credential_validator,
              [{validation_backend, rabbit_credential_validator_min_password_length},
               {min_length,         MinLength}]]);

switch_credential_validator(Config, regexp, RegExp) ->
    ok = rpc(Config, 0, application, set_env,
             [rabbit, credential_validator,
              [{validation_backend, rabbit_credential_validator_password_regexp},
               {regexp,             RegExp}]]).

set_full_permissions(Config, VHost) ->
    set_permissions(Config, 0, <<"guest">>, VHost, <<".*">>, <<".*">>, <<".*">>).
set_full_permissions(Config, Username, VHost) ->
    set_permissions(Config, 0, Username, VHost, <<".*">>, <<".*">>, <<".*">>).
set_full_permissions(Config, Node, Username, VHost) ->
    set_permissions(Config, Node, Username, VHost, <<".*">>, <<".*">>, <<".*">>).

set_permissions(Config, Username, VHost, ConfigurePerm, WritePerm, ReadPerm) ->
    set_permissions(Config, 0, Username, VHost, ConfigurePerm, WritePerm, ReadPerm).

set_permissions(Config, Node, Username, VHost, ConfigurePerm, WritePerm, ReadPerm) ->
    set_permissions(Config, Node, Username, VHost, ConfigurePerm, WritePerm, ReadPerm,
                    <<"acting-user">>).

set_permissions(Config, Node, Username, VHost, ConfigurePerm, WritePerm, ReadPerm,
                ActingUser) ->
    rabbit_ct_broker_helpers:rpc(Config, Node,
                                 rabbit_auth_backend_internal,
                                 set_permissions,
                                 [rabbit_data_coercion:to_binary(Username),
                                  rabbit_data_coercion:to_binary(VHost),
                                  rabbit_data_coercion:to_binary(ConfigurePerm),
                                  rabbit_data_coercion:to_binary(WritePerm),
                                  rabbit_data_coercion:to_binary(ReadPerm),
                                  ActingUser]).

clear_permissions(Config, VHost) ->
    clear_permissions(Config, 0, <<"guest">>, VHost).
clear_permissions(Config, Username, VHost) ->
    clear_permissions(Config, 0, Username, VHost).

clear_permissions(Config, Node, Username, VHost) ->
    clear_permissions(Config, Node, Username, VHost, <<"acting-user">>).

clear_permissions(Config, Node, Username, VHost, ActingUser) ->
    rabbit_ct_broker_helpers:rpc(Config, Node,
                                 rabbit_auth_backend_internal,
                                 clear_permissions,
                                 [rabbit_data_coercion:to_binary(Username),
                                  rabbit_data_coercion:to_binary(VHost),
                                  ActingUser]).


%% Functions to execute code on a remote node/broker.

add_code_path_to_node(Node, Module) ->
    Path1 = filename:dirname(code:which(Module)),
    Path2 = filename:dirname(code:which(?MODULE)),
    Paths = lists:usort([Path1, Path2]),
    ExistingPaths = rpc:call(Node, code, get_path, []),
    lists:foreach(
      fun(P) ->
          case lists:member(P, ExistingPaths) of
              true  -> ok;
              false -> true = rpc:call(Node, code, add_pathz, [P])
          end
      end, Paths).

add_code_path_to_all_nodes(Config, Module) ->
    Nodenames = get_node_configs(Config, nodename),
    [ok = add_code_path_to_node(Nodename, Module)
      || Nodename <- Nodenames],
    ok.

rpc(Config, Node, Module, Function, Args)
when is_atom(Node) andalso Node =/= undefined ->
    rpc(Config, Node, Module, Function, Args, infinity);
rpc(Config, I, Module, Function, Args)
when is_integer(I) andalso I >= 0 ->
    Node = get_node_config(Config, I, nodename),
    rpc(Config, Node, Module, Function, Args);
rpc(Config, Nodes, Module, Function, Args)
when is_list(Nodes) ->
    [rpc(Config, Node, Module, Function, Args) || Node <- Nodes].

rpc(_Config, Node, Module, Function, Args, Timeout)
when is_atom(Node) andalso Node =/= undefined ->
    %% We add some directories to the broker node search path.
    add_code_path_to_node(Node, Module),
    %% If there is an exception, rpc:call/{4,5} returns the exception as
    %% a "normal" return value. If there is an exit signal, we raise
    %% it again. In both cases, we have no idea of the module and line
    %% number which triggered the issue.
    Ret = case Timeout of
        infinity -> rpc:call(Node, Module, Function, Args);
        _        -> rpc:call(Node, Module, Function, Args, Timeout)
    end,
    case Ret of
        {badrpc, {'EXIT', Reason}} -> exit(Reason);
        {badrpc, Reason}           -> exit(Reason);
        Ret                        -> Ret
    end;
rpc(Config, I, Module, Function, Args, Timeout)
when is_integer(I) andalso I >= 0 ->
    Node = get_node_config(Config, I, nodename),
    rpc(Config, Node, Module, Function, Args, Timeout);
rpc(Config, Nodes, Module, Function, Args, Timeout)
when is_list(Nodes) ->
    [rpc(Config, Node, Module, Function, Args, Timeout) || Node <- Nodes].

rpc_all(Config, Module, Function, Args) ->
    Nodes = get_node_configs(Config, nodename),
    rpc(Config, Nodes, Module, Function, Args).

rpc_all(Config, Module, Function, Args, Timeout) ->
    Nodes = get_node_configs(Config, nodename),
    rpc(Config, Nodes, Module, Function, Args, Timeout).

%% Functions to start/restart/stop only the broker or the full Erlang
%% node.

start_node(Config, Node) ->
    NodeConfig = get_node_config(Config, Node),
    I = if
        is_atom(Node) -> nodename_to_index(Config, Node);
        true          -> Node
    end,
    case do_start_rabbitmq_node(Config, NodeConfig, I) of
        {skip, _} = Error -> {error, Error};
        _                 -> ok
    end.

start_broker(Config, Node) ->
    ok = rpc(Config, Node, rabbit, start, []).

restart_broker(Config, Node) ->
    ok = rpc(Config, Node, ?MODULE, do_restart_broker, []).

do_restart_broker() ->
    ok = rabbit:stop(),
    ok = rabbit:start().

stop_broker(Config, Node) ->
    ok = rpc(Config, Node, rabbit, stop, []).

restart_node(Config, Node) ->
    ok = stop_node(Config, Node),
    ok = start_node(Config, Node).

stop_node(Config, Node) ->
    NodeConfig = get_node_config(Config, Node),
    case stop_rabbitmq_node(Config, NodeConfig) of
        {skip, _} = Error -> Error;
        _                 -> ok
    end.

stop_node_after(Config, Node, Sleep) ->
    timer:sleep(Sleep),
    stop_node(Config, Node).

kill_node(Config, Node) ->
    Pid = rpc(Config, Node, os, getpid, []),
    %% FIXME maybe_flush_cover(Cfg),
    os:cmd("kill -9 " ++ Pid),
    await_os_pid_death(Pid).

kill_node_after(Config, Node, Sleep) ->
    timer:sleep(Sleep),
    kill_node(Config, Node).

await_os_pid_death(Pid) ->
    case rabbit_misc:is_os_process_alive(Pid) of
        true  -> timer:sleep(100),
                 await_os_pid_death(Pid);
        false -> ok
    end.

%% From a given list of gen_tcp client connections, return the list of
%% connection handler PID in RabbitMQ.
get_connection_pids(Connections) ->
    ConnInfos = [
      begin
          {ok, {Addr, Port}} = inet:sockname(Connection),
          [{peer_host, Addr}, {peer_port, Port}]
      end || Connection <- Connections],
    lists:filter(
      fun(Conn) ->
          ConnInfo = rabbit_networking:connection_info(Conn,
            [peer_host, peer_port]),
          %% On at least Mac OS X, for a connection on localhost, the
          %% client side of the connection gives its IPv4 address
          %% (127.0.0.1), but the server side gives some kind of
          %% non-standard IPv6 address (::ffff:7f00:1, not even the
          %% standard ::1). So let's test for this alternate form too.
          AltConnInfo = case proplists:get_value(peer_host, ConnInfo) of
              {0, 0, 0, 0, 0, 16#ffff, 16#7f00, N} ->
                  lists:keyreplace(peer_host, 1, ConnInfo,
                      {peer_host, {127, 0, 0, N}});
              _ ->
                  ConnInfo
          end,
          lists:member(ConnInfo, ConnInfos) orelse
          lists:member(AltConnInfo, ConnInfos)
      end, rabbit_networking:connections()).

%% Return the PID of the given queue's supervisor.
get_queue_sup_pid(#amqqueue { pid = QPid, name = QName }) ->
    VHost = QName#resource.virtual_host,
    {ok, AmqSup} = rabbit_amqqueue_sup_sup:find_for_vhost(VHost, node(QPid)),
    Sups = supervisor:which_children(AmqSup),
    get_queue_sup_pid(Sups, QPid).

get_queue_sup_pid([{_, SupPid, _, _} | Rest], QueuePid) ->
    WorkerPids = [Pid || {_, Pid, _, _} <- supervisor:which_children(SupPid)],
    case lists:member(QueuePid, WorkerPids) of
        true  -> SupPid;
        false -> get_queue_sup_pid(Rest, QueuePid)
    end;
get_queue_sup_pid([], _QueuePid) ->
    undefined.

%% -------------------------------------------------------------------
%% Policy helpers.
%% -------------------------------------------------------------------

set_policy(Config, Node, Name, Pattern, ApplyTo, Definition) ->
    set_policy(Config, Node, Name, Pattern, ApplyTo, Definition, <<"acting-user">>).

set_policy(Config, Node, Name, Pattern, ApplyTo, Definition, Username) ->
    ok = rpc(Config, Node,
             rabbit_policy, set, [<<"/">>, Name, Pattern, Definition, 0, ApplyTo,
                                  Username]).

clear_policy(Config, Node, Name) ->
    clear_policy(Config, Node, Name, <<"acting-user">>).

clear_policy(Config, Node, Name, Username) ->
    rpc(Config, Node,
        rabbit_policy, delete, [<<"/">>, Name, Username]).

set_operator_policy(Config, Node, Name, Pattern, ApplyTo, Definition) ->
    ok = rpc(Config, Node,
      rabbit_policy, set_op, [<<"/">>, Name, Pattern, Definition, 0, ApplyTo,
                              <<"acting-user">>]).

clear_operator_policy(Config, Node, Name) ->
    rpc(Config, Node,
        rabbit_policy, delete_op, [<<"/">>, Name, <<"acting-user">>]).

set_ha_policy(Config, Node, Pattern, Policy) ->
    set_ha_policy(Config, Node, Pattern, Policy, []).

set_ha_policy(Config, Node, Pattern, Policy, Extra) ->
    set_policy(Config, Node, Pattern, Pattern, <<"queues">>,
      ha_policy(Policy) ++ Extra).

ha_policy(<<"all">>)      -> [{<<"ha-mode">>,   <<"all">>}];
ha_policy({Mode, Params}) -> [{<<"ha-mode">>,   Mode},
                              {<<"ha-params">>, Params}].

set_ha_policy_all(Config) ->
    set_ha_policy(Config, 0, <<".*">>, <<"all">>),
    Config.

set_ha_policy_two_pos(Config) ->
    Members = [
      rabbit_misc:atom_to_binary(N)
      || N <- get_node_configs(Config, nodename)],
    TwoNodes = [M || M <- lists:sublist(Members, 2)],
    set_ha_policy(Config, 0, <<"^ha.two.">>, {<<"nodes">>, TwoNodes},
                  [{<<"ha-promote-on-shutdown">>, <<"always">>}]),
    set_ha_policy(Config, 0, <<"^ha.auto.">>, {<<"nodes">>, TwoNodes},
                  [{<<"ha-sync-mode">>,           <<"automatic">>},
                   {<<"ha-promote-on-shutdown">>, <<"always">>}]),
    Config.

set_ha_policy_two_pos_batch_sync(Config) ->
    Members = [
      rabbit_misc:atom_to_binary(N)
      || N <- get_node_configs(Config, nodename)],
    TwoNodes = [M || M <- lists:sublist(Members, 2)],
    set_ha_policy(Config, 0, <<"^ha.two.">>, {<<"nodes">>, TwoNodes},
                  [{<<"ha-promote-on-shutdown">>, <<"always">>}]),
    set_ha_policy(Config, 0, <<"^ha.auto.">>, {<<"nodes">>, TwoNodes},
                  [{<<"ha-sync-mode">>,           <<"automatic">>},
                   {<<"ha-sync-batch-size">>,     200},
                   {<<"ha-promote-on-shutdown">>, <<"always">>}]),
    Config.

%% -------------------------------------------------------------------
%% Parameter helpers.
%% -------------------------------------------------------------------

set_parameter(Config, Node, Component, Name, Value) ->
    set_parameter(Config, Node, <<"/">>, Component, Name, Value, none).

set_parameter(Config, Node, VHost, Component, Name, Value) ->
    set_parameter(Config, Node, VHost, Component, Name, Value, none).

set_parameter(Config, Node, VHost, Component, Name, Value, Username) ->
    ok = rpc(Config, Node,
      rabbit_runtime_parameters, set, [VHost, Component, Name, Value, Username]).

clear_parameter(Config, Node, Component, Name) ->
    clear_parameter(Config, Node, <<"/">>, Component, Name).

clear_parameter(Config, Node, VHost, Component, Name) ->
    clear_parameter(Config, Node, VHost, Component, Name, <<"acting-user">>).

clear_parameter(Config, Node, VHost, Component, Name, Username) ->
    ok = rpc(Config, Node,
      rabbit_runtime_parameters, clear, [VHost, Component, Name, Username]).

set_global_parameter(Config, Name, Value) ->
    set_global_parameter(Config, 0, Name, Value).
set_global_parameter(Config, Node, Name, Value) ->
    ok = rpc(Config, Node,
      rabbit_runtime_parameters, set_global, [Name, Value, <<"acting-user">>]).

clear_global_parameter(Config, Name) ->
    clear_global_parameter(Config, 0, Name).
clear_global_parameter(Config, Node, Name) ->
    ok = rpc(Config, Node,
      rabbit_runtime_parameters, clear_global, [Name, <<"acting-user">>]).

%% -------------------------------------------------------------------
%% Parameter helpers.
%% -------------------------------------------------------------------

enable_plugin(Config, Node, Plugin) ->
    plugin_action(Config, Node, enable, [Plugin], []).

disable_plugin(Config, Node, Plugin) ->
    plugin_action(Config, Node, disable, [Plugin], []).

plugin_action(Config, Node, Command, Args, Opts) ->
    PluginsFile = rabbit_ct_broker_helpers:get_node_config(Config, Node,
      enabled_plugins_file),
    PluginsDir = rabbit_ct_broker_helpers:get_node_config(Config, Node,
      plugins_dir),
    Nodename = rabbit_ct_broker_helpers:get_node_config(Config, Node,
      nodename),
    rabbit_ct_broker_helpers:rpc(Config, Node,
      rabbit_plugins_main, action,
      [Command, Nodename, Args, Opts, PluginsFile, PluginsDir]).

%% -------------------------------------------------------------------

test_channel() ->
    Me = self(),
    Writer = spawn(fun () -> test_writer(Me) end),
    {ok, Limiter} = rabbit_limiter:start_link(no_id),
    {ok, Ch} = rabbit_channel:start_link(
                 1, Me, Writer, Me, "", rabbit_framing_amqp_0_9_1,
                 user(<<"guest">>), <<"/">>, [], Me, Limiter),
    {Writer, Limiter, Ch}.

test_writer(Pid) ->
    receive
        {'$gen_call', From, flush} -> gen_server:reply(From, ok),
                                      test_writer(Pid);
        {send_command, Method}     -> Pid ! Method,
                                      test_writer(Pid);
        shutdown                   -> ok
    end.

user(Username) ->
    #user{username       = Username,
          tags           = [administrator],
          authz_backends = [{rabbit_auth_backend_internal, none}]}.
