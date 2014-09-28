%%-------------------------------------------------------------------
%%
%% Copyright (c) 2014, James Fish <james@fishcakez.com>
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License. You may obtain
%% a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied. See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%%-------------------------------------------------------------------
-module(sock_drawer_SUITE).

-include_lib("common_test/include/ct.hrl").

%% common_test api

-export([all/0]).
-export([suite/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([group/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

%% test cases

-export([basic_accept/1]).
-export([basic_connect/1]).
-export([max_sockets/1]).
-export([graceful_shutdown/1]).
-export([reload/1]).
-export([reload_targeter/1]).
-export([reload_manager/1]).
-export([purge/1]).
-export([restart_targeter/1]).
-export([restart_manager/1]).
-export([simple_statem/1]).

%% common_test api

all() ->
    [{group, simple},
     {group, property}].

suite() ->
    [{timetrap, {seconds, 300}}].

groups() ->
    [{simple, [parallel],
      [basic_accept, basic_connect, max_sockets, graceful_shutdown, reload,
       reload_targeter, reload_manager, purge, restart_targeter,
       restart_manager]},
     {property, [simple_statem]}].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

group(_Group) ->
    [].

init_per_group(_Group, Config) ->
    ok = application:start(sock_drawer),
    Config.

end_per_group(_Group, _Config) ->
    ok = application:stop(sock_drawer).

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%% test cases

basic_accept(_Config) ->
    process_flag(trap_exit, true),
    {ok, Pid} = sdt:start_link(accept, 0),
    try
        Id = sock_drawer:id(Pid),
        {ok, L} = sd_agent:find(Id, socket),
        {ok, Port} = inet:port(L),
        {ok, S} = gen_tcp:connect({127,0,0,1}, Port, opts(), 1000),
        {ok, <<"hi">>} = gen_tcp:recv(S, 0, 1000),
        gen_tcp:send(S, <<"world">>),
        {ok, <<"world">>} = gen_tcp:recv(S, 0, 1000),
        ok = gen_tcp:close(S)
    after
        exit(Pid, shutdown),
        receive
            {'EXIT', Pid, _Reason} ->
                ok
        end
    end.

basic_connect(_Config) ->
    process_flag(trap_exit, true),
    {ok, L} = gen_tcp:listen(0, [{ifaddr, {127,0,0,1}} | opts()]),
    {ok, Port} = inet:port(L),
    {ok, Pid} = sdt:start_link(connect, Port),
    try
        {ok, S} = gen_tcp:accept(L, 1000),
        {ok, <<"hi">>} = gen_tcp:recv(S, 0, 1000),
        gen_tcp:send(S, <<"world">>),
        {ok, <<"world">>} = gen_tcp:recv(S, 0, 1000),
        ok = gen_tcp:close(S)
    after
        exit(Pid, shutdown),
        receive
            {'EXIT', Pid, _Reason} ->
                gen_tcp:close(L)
        end
    end.

max_sockets(_Config) ->
    process_flag(trap_exit, true),
    {ok, L} = gen_tcp:listen(0, [{ifaddr, {127,0,0,1}} | opts()]),
    {ok, Port} = inet:port(L),
    {ok, Pid} = sdt:start_link(connect, Port),
    try
        {ok, S} = gen_tcp:accept(L, 1000),
        {ok, S2} = gen_tcp:accept(L, 1000),
        {error, timeout} = gen_tcp:accept(L, 100),
        gen_tcp:close(S),
        {ok, S3} = gen_tcp:accept(L, 100),
        ok = gen_tcp:close(S2),
        ok = gen_tcp:close(S3)
    after
        exit(Pid, shutdown),
        receive
            {'EXIT', Pid, _Reason} ->
                gen_tcp:close(L)
        end
    end.

graceful_shutdown(_Config) ->
    process_flag(trap_exit, true),
    {ok, L} = gen_tcp:listen(0, [{ifaddr, {127,0,0,1}} | opts()]),
    {ok, Port} = inet:port(L),
    {ok, Pid} = sdt:start_link(connect, Port),
    {ok, S} = gen_tcp:accept(L, 1000),
    Id = sock_drawer:id(Pid),
    Manager = sd_agent:whereis_name({Id, sd_manager}),
    MRef = monitor(process, Manager),
    exit(Pid, shutdown),
    receive
        {'EXIT', Pid, _Reason} ->
            ok
    end,
    receive
        {'DOWN', MRef, _, Manager, shutdown} ->
            ok;
        {'DOWN', MRef, _, Manager, Reason} ->
            exit({manager_exit, Reason})
    end,
    {ok, <<"hi">>} = gen_tcp:recv(S, 0, 100),
    {error, closed} = gen_tcp:recv(S, 0, 100),
    gen_tcp:close(S),
    gen_tcp:close(L).

reload(_Config) ->
    process_flag(trap_exit, true),
    {ok, Pid} = sdt:start_link(accept, 0),
    Id = sock_drawer:id(Pid),
    {ok, L} = sd_agent:find(Id, socket),
    {ok, Port} = inet:port(L),
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port, opts(), 100),
    try
        [Reloader | Children] = supervisor:which_children(Pid),
        %% 5 creators, 4 waiters, 1 accepting
        Creators = sets:from_list(sd_manager:which_creators(Id)),
        5 = sets:size(Creators),
        sys:suspend(Pid),
        sys:change_code(Pid, sdt, undefined, undefined),
        sys:resume(Pid),
        timer:sleep(50),
        {ok, L} = sd_agent:find(Id, socket),
        %% 5 creators, 5 waiters, 1 old accepting
        Creators2 = sets:from_list(sd_manager:which_creators(Id)),
        %% 5 new waiters, 1 old accepting
        6 = sets:size(Creators2),
        %% 1 old accepting
        1 = sets:size(sets:intersection(Creators, Creators2)),
        %% Reloader must be replaced, it's last child so 1st in which_children
        [Reloader2 | Children] = supervisor:which_children(Pid),
        true = (Reloader =/= Reloader2),
        %% once supervisor call returns reload is done so:
        %% 4 new waiters, 1 new accepting
        Creators3 = sets:from_list(sd_manager:which_creators(Id)),
        5 = sets:size(Creators3),
        5 = sets:size(sets:intersection(Creators2, Creators3)),
        {ok, S2} = gen_tcp:connect({127, 0, 0, 1}, Port, opts(), 100),
        %% 5 new waiters
        Creators4 = sets:from_list(sd_manager:which_creators(Id)),
        5 = sets:size(Creators4),
        5 = sets:size(sets:intersection(Creators3, Creators3)),
        gen_tcp:close(S2)
    after
        gen_tcp:close(S),
        exit(Pid, shutdown),
        receive
            {'EXIT', Pid, _Reason} ->
                ok
        end
    end.

reload_targeter(_Config) ->
    process_flag(trap_exit, true),
    {ok, Pid} = sdt_rand_targeter:start_link(accept, 0),
    Id = sock_drawer:id(Pid),
    {ok, L} = sd_agent:find(Id, socket),
    {ok, Port} = inet:port(L),
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port, opts(), 100),
    {ok, <<"hi">>} = gen_tcp:recv(S, 0, 100),
    try
        [Reloader | Children] = supervisor:which_children(Pid),
        %% 5 creators, 4 waiters, 1 accepting
        Creators = sets:from_list(sd_manager:which_creators(Id)),
        5 = sets:size(Creators),
        Manager = sd_reg:whereis_name({Id, sd_manager}),
        Targeter = sd_reg:whereis_name({Id, sd_targeter}),
        sys:suspend(Pid),
        sys:change_code(Pid, sdt, undefined, undefined),
        sys:resume(Pid),
        %% Reloader must be replaced, it's last child so 1st in which_children
        [Reloader2 | Children] = supervisor:which_children(Pid),
        true = (Reloader =/= Reloader2),
        Manager = sd_reg:whereis_name({Id, sd_manager}),
        Targeter2 = sd_reg:whereis_name({Id, sd_targeter}),
        true = (Targeter =/= Targeter2),
        %% 5 creators, 4 waiters, 1 accepting, 0 old
        Creators2 = sets:from_list(sd_manager:which_creators(Id)),
        5 = sets:size(Creators2),
        %% 0 old
        0 = sets:size(sets:intersection(Creators, Creators2)),
        {ok, L2} = sd_agent:find(Id, socket),
        {ok, Port2} = inet:port(L2),
        %% New listen socket
        true = (L =/= L2),
        {error, timeout} = gen_tcp:recv(S, 0, 100),
        {ok, S2} = gen_tcp:connect({127, 0, 0, 1}, Port2, opts(), 100),
        {ok, <<"hi">>} = gen_tcp:recv(S2, 0, 100),
        gen_tcp:close(S2)
    after
        gen_tcp:close(S),
        exit(Pid, shutdown),
        receive
            {'EXIT', Pid, _Reason} ->
                ok
        end
    end.

reload_manager(_Config) ->
    process_flag(trap_exit, true),
    {ok, Pid} = sdt_rand_manager:start_link(accept, 0),
    Id = sock_drawer:id(Pid),
    {ok, L} = sd_agent:find(Id, socket),
    {ok, Port} = inet:port(L),
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port, opts(), 100),
    {ok, <<"hi">>} = gen_tcp:recv(S, 0, 100),
    try
        [Reloader | Children] = supervisor:which_children(Pid),
        %% 5 creators, 4 waiters, 1 accepting
        Creators = sets:from_list(sd_manager:which_creators(Id)),
        5 = sets:size(Creators),
        Manager = sd_reg:whereis_name({Id, sd_manager}),
        Targeter = sd_reg:whereis_name({Id, sd_targeter}),
        sys:suspend(Pid),
        sys:change_code(Pid, sdt, undefined, undefined),
        sys:resume(Pid),
        %% Reloader must be replaced, it's last child so 1st in which_children
        [Reloader2 | Children] = supervisor:which_children(Pid),
        true = (Reloader =/= Reloader2),
        Manager2 = sd_reg:whereis_name({Id, sd_manager}),
        Targeter2 = sd_reg:whereis_name({Id, sd_targeter}),
        true = (Manager =/= Manager2),
        true = (Targeter =/= Targeter2),
        %% 5 creators, 4 waiters, 1 accepting, 0 old
        Creators2 = sets:from_list(sd_manager:which_creators(Id)),
        5 = sets:size(Creators2),
        %% 0 old
        0 = sets:size(sets:intersection(Creators, Creators2)),
        {ok, L2} = sd_agent:find(Id, socket),
        {ok, Port2} = inet:port(L2),
        %% New listen socket
        true = (L =/= L2),
        %% Old sockets/handlers closed.
        {error, closed} = gen_tcp:recv(S, 0, 100),
        {ok, S2} = gen_tcp:connect({127, 0, 0, 1}, Port2, opts(), 100),
        {ok, <<"hi">>} = gen_tcp:recv(S2, 0, 100),
        gen_tcp:close(S2)
    after
        gen_tcp:close(S),
        exit(Pid, shutdown),
        receive
            {'EXIT', Pid, _Reason} ->
                ok
        end
    end.



purge(_Config) ->
    process_flag(trap_exit, true),
    {ok, Pid} = sdt:start_link(accept, 0),
    Id = sock_drawer:id(Pid),
    {ok, L} = sd_agent:find(Id, socket),
    {ok, Port} = inet:port(L),
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port, opts(), 100),
    try
        [Reloader | Children] = supervisor:which_children(Pid),
        sys:suspend(Pid),
        sys:change_code(Pid, sdt, undefined, undefined),
        sys:resume(Pid),
        [Reloader2 | Children] = supervisor:which_children(Pid),
        true = (Reloader =/= Reloader2),
        {ok, S2} = gen_tcp:connect({127, 0, 0, 1}, Port, opts(), 100),
        ok = sock_drawer:purge(Pid),
        [Reloader2 | Children] = supervisor:which_children(Pid),
        [_Pool] = supervisor:which_children({via, sd_reg, {Id, sd_pool_sup}}),
        {ok, <<"hi">>} = gen_tcp:recv(S, 0, 100),
        {error, closed} = gen_tcp:recv(S, 0, 100),
        {ok, <<"hi">>} = gen_tcp:recv(S2, 0, 100),
        {error, timeout} = gen_tcp:recv(S2, 0, 100),
        gen_tcp:close(S2),
        {ok, S3} = gen_tcp:connect({127, 0, 0, 1}, Port, opts(), 100),
        {ok, <<"hi">>} = gen_tcp:recv(S3, 0, 100),
        gen_tcp:close(S3)
    after
        gen_tcp:close(S),
        exit(Pid, shutdown),
        receive
            {'EXIT', Pid, _Reason} ->
                ok
        end
    end.

restart_targeter(_Config) ->
    process_flag(trap_exit, true),
    {ok, Pid} = sdt:start_link(accept, 0),
    Id = sock_drawer:id(Pid),
    {ok, L} = sd_agent:find(Id, socket),
    {ok, Port} = inet:port(L),
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port, opts(), 100),
    try
        [Reloader, TargeterSup | Children] = supervisor:which_children(Pid),
        {{sd_reloader, RRef}, _, _, _} = Reloader,
        {ok, <<"hi">>} = gen_tcp:recv(S, 0, 100),
        gen_tcp:close(L),
        timer:sleep(100),
        [Reloader2, TargeterSup2 | Children] = supervisor:which_children(Pid),
        {{sd_reloader, RRef}, _, _, _} = Reloader2,
        {ok, L2} = sd_agent:find(Id, socket),
        true = (TargeterSup =/= TargeterSup2),
        true = (L =/= L2),
        {error, timeout} = gen_tcp:recv(S, 0, 100),
        {ok, Port2} = inet:port(L2),
        {ok, S2} = gen_tcp:connect({127, 0, 0, 1}, Port2, opts(), 100),
        {ok, <<"hi">>} = gen_tcp:recv(S2, 0, 100),
        gen_tcp:close(S2)
    after
        gen_tcp:close(S),
        exit(Pid, shutdown),
        receive
            {'EXIT', Pid, _Reason} ->
                ok
        end
    end.

restart_manager(_Config) ->
    process_flag(trap_exit, true),
    {ok, Pid} = sdt:start_link(accept, 0),
    Id = sock_drawer:id(Pid),
    {ok, L} = sd_agent:find(Id, socket),
    {ok, Port} = inet:port(L),
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port, opts(), 100),
    try
        [Agent | _Children] = lists:reverse(supervisor:which_children(Pid)),
        Manager = sd_agent:whereis_name({Id, sd_manager}),
        {ok, <<"hi">>} = gen_tcp:recv(S, 0, 100),
        exit(Manager, shutdown),
        {error, closed} = gen_tcp:recv(S, 0, 100),
        timer:sleep(100),
        [Agent | _Children2] = lists:reverse(supervisor:which_children(Pid)),
        {ok, L2} = sd_agent:find(Id, socket),
        true = (L =/= L2),
        {ok, Port2} = inet:port(L2),
        {ok, S2} = gen_tcp:connect({127, 0, 0, 1}, Port2, opts(), 100),
        {ok, <<"hi">>} = gen_tcp:recv(S2, 0, 100),
        gen_tcp:close(S2)
    after
        gen_tcp:close(S),
        exit(Pid, shutdown),
        receive
            {'EXIT', Pid, _Reason} ->
                ok
        end
    end.

simple_statem(_Config) ->
    case sd_simple_statem:quickcheck([{numtests, 1000}, long_result, {on_output, fun log/2}]) of
        true ->
            ok;
        {error, Reason} ->
            error(Reason);
        CounterExample ->
            ct:log("Counter Example:~n~p", [CounterExample]),
            error(counterexample)
    end.

%% Custom log format.
log(".", []) ->
    ok;
log("!", []) ->
    ok;
log("OK: " ++ Comment = Format, Args) ->
    ct:comment(no_trailing_newline(Comment), Args),
    io:format(no_trailing_newline(Format), Args);
log("Failed: " ++ Comment = Format, Args) ->
    ct:comment(no_trailing_newline(Comment), Args),
    io:format(no_trailing_newline(Format), Args);
log(Format, Args) ->
    io:format(no_trailing_newline(Format), Args).

no_trailing_newline(Format) ->
    try lists:split(length(Format) - 2, Format) of
        {Format2, "~n"} ->
            Format2;
        _ ->
            Format
    catch
        error:badarg ->
            Format
    end.

%% Socket options
opts() ->
    [{active, false}, {packet, 4}, binary].


