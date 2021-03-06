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
-module(sd_manager_sup).

-behaviour(supervisor).

%% public api

-export([start_link/1]).
-export([start_manager/2]).
-export([terminate_manager/1]).

%% supervisor api

-export([init/1]).

%% public api

-spec start_link(Id) -> {ok, Pid} | {error, Reason} when
      Id :: sock_drawer:id(),
      Pid :: pid(),
      Reason :: term().
start_link(Id) ->
    supervisor:start_link({via, sd_reg, {Id, ?MODULE}}, ?MODULE, []).

-spec start_manager(Id, Manager) ->
    {ok, Pid} | {ok, Pid, Info} | {error, Reason} when
      Id :: sock_drawer:id(),
      Manager :: supervisor:child_spec(),
      Pid :: pid(),
      Info :: term(),
      Reason :: term().
start_manager(Id, Manager) ->
    supervisor:start_child({via, sd_reg, {Id, ?MODULE}}, Manager).

-spec terminate_manager(Id) -> ok when
      Id :: sock_drawer:id().
terminate_manager(Id) ->
    Sup = {via, sd_reg, {Id, ?MODULE}},
    case supervisor:terminate_child(Sup, manager) of
        ok ->
            ok = supervisor:delete_child(Sup, manager);
        {error, not_found} ->
            ok
    end.

%% supervisor api

init([]) ->
    {ok, {{one_for_all, 0, 1}, []}}.
