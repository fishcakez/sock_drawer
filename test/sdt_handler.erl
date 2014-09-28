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
-module(sdt_handler).

-behaviour(gen_fsm).

%% public api

-export([start_link/3]).
-export([start_link/4]).

%% gen_fsm api

-export([init/1]).
-export([init/2]).
-export([init/3]).
-export([active/2]).
-export([active/3]).
-export([handle_event/3]).
-export([handle_sync_event/4]).
-export([handle_info/3]).
-export([code_change/4]).
-export([terminate/3]).

%% types

-record(state, {id, reload, pool_ref, sock_info, socket}).

%% public api

start_link(SockInfo, Id, PRef) ->
    start_link(undefined, SockInfo, Id, PRef).

start_link(Reload, SockInfo, Id, PRef) ->
    gen_fsm:start_link(?MODULE, {Id, Reload, PRef, SockInfo}, []).

%% gen_fsm api

init({Id, Reload, PRef, SockInfo}) ->
    {ok, init, #state{id=Id, reload=Reload, pool_ref=PRef, sock_info=SockInfo}}.

init(Event, State) ->
    {stop, {bad_event, Event}, State}.

init(Event, _From, State) ->
    {stop, {bad_event, Event}, State}.

active(timeout, #state{reload=undefined, socket=Socket} = State) ->
    gen_tcp:send(Socket, "hi"),
    {next_state, active, State};
active(timeout, #state{reload=Reload, socket=Socket} = State) ->
    gen_tcp:send(Socket, ["hi", <<Reload:32>>]),
    {next_state, active, State}.

active(Event, _From, State) ->
    {stop, {bad_event, Event}, State}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

handle_info({socket, PRef, Socket}, init, #state{pool_ref=PRef} = State) ->
    inet:setopts(Socket, [{active, once}]),
    {next_state, active, State#state{socket=Socket}, 0};
handle_info({tcp_closed, Socket}, active, #state{socket=Socket} = State) ->
    gen_tcp:close(Socket),
    {stop, normal, State};
handle_info({tcp, Socket, Data}, active, #state{socket=Socket} = State) ->
    gen_tcp:send(Socket, Data),
    inet:setopts(Socket, [{active, once}]),
    {next_state, active, State};
handle_info(Info, StateName, State) ->
    io:format(user, "info ~p ~p ~n", [Info, State]),
    {next_state, StateName, State}.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    ok.
