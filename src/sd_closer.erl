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
-module(sd_closer).

%% public api

-export([start_link/1]).

%% gen api

-export([init_it/6]).

%% gen_fsm api

-export([init/1]).
-export([init/2]).
-export([init/3]).
-export([handle_event/3]).
-export([handle_sync_event/4]).
-export([handle_info/3]).
-export([code_change/4]).
-export([terminate/3]).

%% public api

-spec start_link(Id) -> ignore | {error, Reason} when
      Id :: sock_drawer:id(),
      Reason :: term().
start_link(Id) ->
    gen:start(?MODULE, link, {via, sd_reg, {Id, ?MODULE}}, ?MODULE, Id, []).

%% gen api

init_it(Starter, _Parent, Name, ?MODULE, Id, Opts) ->
    % Will make current creators close as soon as possible.
    ok = sd_targeter_sup:terminate_targeter(Id),
    % Create a fake empty pool to join manager and wait for init_ack to ensure
    % no creators are left. This should make sock_drawer's termination as
    % graceful as possible.
    PRef = make_ref(),
    case sd_manager:join(Id, PRef, []) of
        {ok, ARef} ->
            gen_fsm:enter_loop(?MODULE, Opts, init, {Starter, Id, ARef}, Name);
        {error, not_found} ->
            sd_reg:unregister_name({Id, ?MODULE}),
            proc_lib:init_ack(Starter, ignore),
            exit(normal)
    end.

%% gen_fsm api

init(_) ->
    {stop, enotsup}.

init({init_ack, ARef}, {_Starter, _Id, ARef} = State) ->
    {stop, normal, State}.

init(Event, _From, State) ->
    {stop, {bad_event, Event}, State}.

handle_event(Event, _StateName, State) ->
    {stop, {bad_event, Event}, State}.

handle_sync_event(Event, _From, _StateName, State) ->
    {stop, {bad_event, Event}, State}.

handle_info({'DOWN', ARef, _, _, Reason}, _StateName,
            {_Starter, ARef} = State) ->
    {stop, {shutdown, {bad_manager, Reason}}, State};
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

terminate(normal, init, {Starter, Id, _ARef}) ->
    sd_reg:unregister_name({Id, ?MODULE}),
    proc_lib:init_ack(Starter, ignore);
terminate(Reason, init, {Starter, Id, _ARef}) ->
    sd_reg:unregister_name({Id, ?MODULE}),
    proc_lib:init_ack(Starter, {error, Reason}).
