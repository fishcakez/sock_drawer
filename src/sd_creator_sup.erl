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
-module(sd_creator_sup).

-behaviour(supervisor).

%% public api

-export([start_link/3]).
-export([start_creator/6]).

%% supervisor api

-export([init/1]).

%% public api

-spec start_link(Id, PRef, Creator) ->
    {ok, Pid} | {error, Reason} when
      Id :: sock_drawer:id(),
      PRef :: reference(),
      Creator :: supervisor:child_spec(),
      Pid :: pid(),
      Reason :: term().
start_link(Id, PRef, Creator) ->
    supervisor:start_link({via, sd_reg, {Id, {?MODULE, PRef}}}, ?MODULE,
                          Creator).

-spec start_creator(Id, PRef, N, Socket, Manager, HandlerSups) ->
    {ok, Pid} | {error, Reason} when
      Id :: sock_drawer:id(),
      PRef :: reference(),
      N :: pos_integer(),
      Socket :: term(),
      Manager :: pid(),
      HandlerSups :: [pid(), ...],
      Pid :: pid(),
      Reason :: term().
start_creator(Id, PRef, N, Socket, Manager, HandlerSups) ->
    supervisor:start_child({via, sd_reg, {Id, {?MODULE, PRef}}},
                           [N, Socket, Manager, HandlerSups]).

%% supervisor api

init(Creator) ->
    {ok, {{simple_one_for_one, 0, 1}, [Creator]}}.
