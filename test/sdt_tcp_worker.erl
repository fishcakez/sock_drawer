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
-module(sdt_tcp_worker).

-behaviour(gen_fsm).

%% public api

-export([start_link/5]).
-export([start_link/6]).

%% gen_fsm api

-export([init/1]).
-export([create/2]).
-export([create/3]).
-export([passive/2]).
-export([passive/3]).
-export([active/2]).
-export([active/3]).
-export([busy/2]).
-export([busy/3]).
-export([handle_event/3]).
-export([handle_sync_event/4]).
-export([handle_info/3]).
-export([code_change/4]).
-export([terminate/3]).

%% public api

%% Wrapping sd_tcp_worker but send a "hi" on controlling the socket to allow
%% confirmation of socket connection in tests.
start_link(Timeout, SockInfo, Id, PRef, Manager) ->
    start_link(undefined, Timeout, SockInfo, Id, PRef, Manager).

start_link(Reload, Timeout, SockInfo, Id, PRef, Manager) ->
    Args = {Id, PRef, SockInfo, Manager, Timeout},
    gen_fsm:start_link(?MODULE, {Reload, Args}, [{debug, [log]}]).

%% gen_fsm api

init({Reload, Args}) ->
    put(reload, Reload),
    sd_tcp_worker:init(Args).

create(Event, State) ->
    sd_tcp_worker:create(Event, State).

create(Event, From, State) ->
    sd_tcp_worker:create(Event, From, State).

passive(Event, State) ->
    sd_tcp_worker:passive(Event, State).

passive(Event, From, State) ->
    sd_tcp_worker:passive(Event, From, State).

active(Event, State) ->
    receive
        {tcp, Socket, <<"hello">> = Data} ->
            ok = gen_tcp:send(Socket, Data),
            inet:setopts(Socket, [{active, once}])
    after
        0 ->
            ok
    end,
    sd_tcp_worker:active(Event, State).

active(Event, From, State) ->
    receive
        {tcp, Socket, <<"hello">> = Data} ->
            ok = gen_tcp:send(Socket, Data),
            inet:setopts(Socket, [{active, once}])
    after
        0 ->
            ok
    end,
    sd_tcp_worker:active(Event, From, State).

busy(Event, State) ->
    sd_tcp_worker:busy(Event, State).

busy(Event, From, State) ->
    sd_tcp_worker:busy(Event, From, State).

handle_event(Event, StateName, State) ->
    sd_tcp_worker:handle_event(Event, StateName, State).

handle_sync_event(Event, From, StateName, State) ->
    sd_tcp_worker:handle_event(Event, From, StateName, State).

handle_info({socket, _PRef, Socket} = Msg, create, State) ->
    case get(reload) of
        undefined ->
            ok = gen_tcp:send(Socket, "hi");
        Reload ->
            ok = gen_tcp:send(Socket, ["hi", <<Reload:32>>])
    end,
    sd_tcp_worker:handle_info(Msg, create, State);
handle_info(Msg, StateName, State) ->
    sd_tcp_worker:handle_info(Msg, StateName, State).

code_change(OldVsn, StateName, State, Extra) ->
    sd_tcp_worker:code_change(OldVsn, StateName, State, Extra).

terminate(Reason, StateName, State) ->
    sd_tcp_worker:terminate(Reason, StateName, State).
