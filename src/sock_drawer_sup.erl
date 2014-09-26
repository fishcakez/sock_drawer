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
-module(sock_drawer_sup).

-behaviour(supervisor).

%% public api

-export([start_link/0]).

%% supervisor api

-export([init/1]).

%% public api

-spec start_link() -> {ok, Pid} | {error, Reason} when
      Pid :: pid(),
      Reason :: term().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% supervisor api

init([]) ->
    Register = {sd_reg, {sd_reg, start_link, []},
                permanent, 5000, worker, [sd_reg]},
    Seek = {sd_seek, {sd_seek, start_link, []},
            permanent, 5000, worker, [sd_seek]},
    {ok, {{one_for_one, 1, 5}, [Register, Seek]}}.
