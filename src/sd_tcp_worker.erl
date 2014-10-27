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
-module(sd_tcp_worker).

-behaviour(gen_fsm).

%% public api

-export([start_link/5]).
-export([checkin/3]).

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

%% types

-record(config, {id, pool_ref, sock_info, manager, socket, handler_ref,
                 timeout}).
-record(state, {config, client, client_ref}).

%% public api

start_link(Timeout, SockInfo, Id, PRef, Manager) ->
    gen_fsm:start_link(?MODULE, {Id, PRef, SockInfo, Manager, Timeout},
                       [{debug, [trace]}]).

checkin(Socket, Handler, CRef) ->
    case gen_tcp:controlling_process(Socket, Handler) of
        ok ->
            gen_fsm:send_event(Handler, {checkin, CRef});
        {error, _Reason} = Error ->
            gen_tcp:close(Socket),
            Error
    end.

%% gen_fsm api

init({Id, PRef, SockInfo, Manager, Timeout}) ->
    process_flag(trap_exit, true),
    Config = #config{id=Id, pool_ref=PRef, sock_info=SockInfo, manager=Manager,
                   timeout=Timeout},
    {ok, create, #state{config=Config}}.

create(Event, State) ->
    {stop, {bad_event, Event}, State}.

create(Event, _From, State) ->
    {stop, {bad_event, Event}, State}.

passive(timeout, #state{config=#config{socket=Socket}} = State) ->
    case inet:setopts(Socket, [{active, once}]) of
        ok ->
            {next_state, active, State};
        {error, Reason} ->
            {stop, {tcp_error, Reason}, State}
    end;
passive({checkout, HRef, Client, CRef},
        #state{config=#config{handler_ref=HRef}} = State) ->
    checkout(State#state{client=Client, client_ref=CRef});
passive({stop, HRef},
        #state{config=#config{handler_ref=HRef} = Config} = State) ->
    Config2 = Config#config{handler_ref=undefined},
    {stop, normal, State#state{config=Config2}}.

passive(Event, _From, State) ->
    {stop, {bad_event, Event}, State}.

active({checkout, HRef, Client, CRef},
       #state{config=#config{handler_ref=HRef, socket=Socket}} = State) ->
    _ = inet:setopts(Socket, [{active, false}]),
    State2 = State#state{client_ref=CRef, client=Client},
    receive
        {tcp, Socket, Data} ->
            {stop, {tcp, Data}, State2};
        {tcp_error, Socket, Error} ->
            {stop, {tcp_error, Error}, State2};
        {tcp_closed, Socket} ->
            {stop, shutdown, State2}
    after
        0 ->
            checkout(State2)
    end;
active({stop, HRef},
       #state{config=#config{handler_ref=HRef} = Config} = State) ->
    Config2 = Config#config{handler_ref=undefined},
    {stop, normal, State#state{config=Config2}}.

active(Event, _From, State) ->
    {stop, {bad_event, Event}, State}.

checkout(#state{config=#config{pool_ref=PRef, manager=Manager, handler_ref=HRef,
                               socket=Socket, timeout=Timeout},
                               client=Client, client_ref=CRef} = State) ->
    % Don't need to monitor Client as exit signals will propagate. This allows
    % client to use gen_tcp:controlling_process/2 freely.
    try erlang:port_connect(Socket, Client) of
        true ->
            Client ! {socket, CRef, Socket},
            {next_state, busy, State}
    catch
        error:badarg ->
            sd_manager:checkin(Manager, PRef, HRef),
            State2 = State#state{client=undefined, client_ref=undefined},
            {next_state, passive, State2, Timeout}
    end.

busy({checkin, CRef},
     #state{config=#config{pool_ref=PRef, manager=Manager, handler_ref=HRef,
                           timeout=Timeout, socket=Socket} = Config,
            client_ref=CRef} = State) ->
    case erlang:port_info(Socket, connected) of
        {connected, Self} when Self =:= self() ->
            sd_manager:checkin(Manager, PRef, HRef),
            ok = inet:setopts(Socket, [{active, false}]),
            State2 = State#state{client=undefined, client_ref=undefined},
            {next_state, passive, State2, Timeout};
        % Client has not returned Socket! This is a bad error in client logic!
        {connected, _Other} = Reason ->
            {stop, Reason, State};
        % Socket is closed.
        undefined ->
            Config2 = Config#config{socket=undefined},
            {stop, shutdown, State#state{config=Config2}}
    end.

busy(Event, _From, State) ->
    {stop, {bad_event, Event}, State}.

handle_event(Event, _StateName, State) ->
    {stop, {bad_event, Event}, State}.

handle_sync_event(Event, _From, _StateName, State) ->
    {stop, {bad_event, Event}, State}.

handle_info({socket, PRef, Socket}, create,
            #state{config=#config{pool_ref=PRef,
                                  manager=Manager,
                                  timeout=Timeout} = Config} = State) ->
    case sd_manager:checkin(Manager, PRef) of
        {ok, HRef} ->
            Config2 = Config#config{socket=Socket, handler_ref=HRef},
            {next_state, passive, State#state{config=Config2}, Timeout};
        {error, _Reason} ->
            Config2 = Config#config{socket=Socket},
            {stop, normal, State#state{config=Config2}}
    end;
handle_info({tcp, Socket, Data}, _StateName,
            #state{config=#config{socket=Socket}} = State) ->
    {stop, {tcp, Data}, State};
handle_info({tcp_error, Socket, Error}, _StateName,
            #state{config=#config{socket=Socket}} = State) ->
    {stop, {tcp_error, Error}, State};
handle_info({tcp_closed, Socket}, _StateName,
            #state{config=#config{socket=Socket}} = State) ->
    {stop, shutdown, State};
handle_info({'EXIT', Socket, _Reason}, _StateName,
            #state{config=#config{socket=Socket} = Config} = State)
  when is_port(Socket) ->
    Config2 = Config#config{socket=undefined},
    {stop, shutdown, State#state{config=Config2}};
handle_info({'EXIT', _Other, normal}, StateName, State) ->
    {next_state, StateName, State};
handle_info({'EXIT', _Other, Reason}, _StateName, State) ->
    {stop, Reason, State}.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

terminate(_Reason, create, _State) ->
    ok;
terminate(normal, passive, State) ->
    normal_terminate(State);
terminate(_Reason, passive, State) ->
    remove_terminate(State);
terminate(normal, active, #state{config=#config{socket=Socket}} = State) ->
    _ = inet:setopts(Socket, [{active, false}]),
    receive
        {tcp, Socket, Data} ->
            exit({tcp, Data});
        {tcp_error, Socket, Error} ->
            exit({tcp_error, Error});
        {tcp_closed, Socket} ->
            gen_tcp:close(Socket)
    after
        0 ->
            normal_terminate(State)
    end;
terminate(_Reason, active, State) ->
    remove_terminate(State);
terminate(_Reason, busy, State) ->
    busy_terminate(State).

normal_terminate(#state{config=#config{socket=Socket}}) ->
    _ = gen_tcp:shutdown(Socket, write),
    % Wait for read close so that remote should have read all data.
    case gen_tcp:recv(Socket, 0, 30000) of
        {ok, Data} ->
            exit({tcp, Data});
        {error, closed} ->
            gen_tcp:close(Socket);
        {error, timeout} ->
            gen_tcp:close(Socket);
        {error, Reason} ->
            exit({tcp_error, Reason})
    end.

remove_terminate(#state{config=#config{manager=Manager, pool_ref=PRef,
                                       handler_ref=HRef,
                                       socket=Socket}} = State) ->
    case sd_manager:remove(Manager, PRef, HRef) of
        ok ->
            ok;
        {error, not_found} ->
            flush_removed(State)
    end,
    gen_tcp:close(Socket).

flush_removed(#state{config=#config{handler_ref=HRef}}) ->
    receive
        {'$gen_event', {checkout, HRef, Client, CRef}} ->
            Client ! {socket_closed, CRef},
            ok;
        {'$gen_event', {stop, HRef}} ->
            ok
    after
        0 ->
            ok
    end.

busy_terminate(#state{config=#config{socket=Socket}}) when is_port(Socket) ->
    % shutdown exit signal will propagate to client.
    exit(Socket, shutdown);
busy_terminate(_State) ->
    ok.
