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
-module(sd_util).

-export([append_args/2]).

-spec append_args(ChildSpec, Args) -> ChildSpec2 when
      ChildSpec :: supervisor:childspec(),
      Args :: list(),
      ChildSpec2 :: supervisor:childspec().
append_args({Name, {M, F, A}, Restart, Shutdown, Type, Mods}, Args) ->
    {Name, {M, F, A ++ Args}, Restart, Shutdown, Type, Mods}.
