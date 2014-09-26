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
-module(sd_purger).

%% public api

-export([start_link/1]).

%% gen_server api

-export([init/1]).

%% public api

-spec start_link(Id) -> ignore | {error, Reason} when
      Id :: sock_drawer:id(),
      Reason :: term().
start_link(Id) ->
    gen_server:start_link({via, sd_reg, {Id, ?MODULE}}, ?MODULE, Id, []).

%% gen_server api

init(Id) ->
    OldPools = sd_agent:old_pools(Id),
    _ = [sd_pool_sup:terminate_pool(Id, Pool) || Pool <- OldPools],
    ignore.
