%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2007 - 2015, Rogvall Invest AB, <tony@rogvall.se>
%%%
%%% This software is licensed as described in the file COPYRIGHT, which
%%% you should have received as part of this distribution. The terms
%%% are also available at http://www.rogvall.se/docs/copyright.txt.
%%%
%%% You may opt to use, copy, modify, merge, publish, distribute and/or sell
%%% copies of the Software, and permit persons to whom the Software is
%%% furnished to do so, under the terms of the COPYRIGHT file.
%%%
%%% This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
%%% KIND, either express or implied.
%%%
%%%---- END COPYRIGHT ---------------------------------------------------------
%%%-------------------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2015, Tony Rogvall
%%% @doc
%%%    Modbus TCP client
%%% @end
%%% Created : 18 Oct 2015 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(modbus_tcp_client).

-behaviour(gen_server).

%% API
-export([start/1]).
-export([start_link/1]).
-export([stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(DEFAULT_TCP_PORT, 502).
-define(DEFAULT_TIMEOUT, 5000).
-define(DEFAULT_RECONNECT_INTERVAL, 3000).

-record(exo_tags,
	{
	  data=tcp,
	  closed=tcp_closed,
	  error=tcp_error
	}).

-record(state,
	{
	  socket,
	  is_active = false,
	  options = [],
	  tags  = #exo_tags{},
	  reconnect = true,
	  reconnect_interval = ?DEFAULT_RECONNECT_INTERVAL,
	  reconnect_timer,
	  proto_id = 0,
	  trans_id = 1,
	  unit_id  = 255,
	  requests = [],
	  buf = <<>>
	}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------

start_link(Opts) -> do_start(Opts, true).
start(Opts) -> do_start(Opts, false).

do_start(Opts, Link) when is_list(Opts), is_boolean(Link) ->
    case connect(Opts) of
	{ok,Socket} ->
	    case gen_server:start_link(?MODULE, [Socket|Opts], []) of
		{ok, Pid} ->
		    ok = exo_socket:controlling_process(Socket, Pid),
		    activate(Pid),
		    if Link -> ok;
		       true -> unlink(Pid)
		    end,
		    {ok,Pid};
		Error ->
		    Error
	    end;
	Error ->
	    Error
    end.

stop(Pid) ->
    gen_server:call(Pid, stop).

activate(Pid) ->
    gen_server:call(Pid, activate).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Socket | Opts]) ->
    IVal = proplists:get_value(reconnect_interval,Opts, 
			       ?DEFAULT_RECONNECT_INTERVAL),
    {ok, #state{ is_active = false,
		 unit_id = proplists:get_value(unit_id, Opts, 255),
		 reconnect = proplists:get_value(reconnect, Opts, true),
		 reconnect_interval = IVal,
		 socket=Socket,
		 options = Opts,
		 tags = exo_tags(Socket)
	       }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({pdu,Func,Params}, From, State) 
  when is_binary(Params), State#state.is_active ->
    TransID = State#state.trans_id,
    ProtoID = State#state.proto_id,
    UnitID  = State#state.unit_id,
    Length  = byte_size(Params)+2, %% func,unitid,params
    Data    = <<TransID:16,ProtoID:16,Length:16,UnitID,Func,Params/binary>>,
    lager:debug("send data ~p", [Data]),
    exo_socket:send(State#state.socket, Data),
    Req = {TransID, UnitID, Func, From },
    {noreply, State#state { trans_id = (TransID+1) band 16#ffff,
			    requests = [Req | State#state.requests]}};
handle_call({pdu,_Func,Params}, _From, State) 
  when is_binary(Params), not State#state.is_active ->
    {reply, {error,not_connected}, State};
handle_call(activate, _From, State) ->
    exo_socket:setopts(State#state.socket, [{active, once}]),
    {reply, ok, State#state { is_active = true }};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error,badarg}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({Tag,_Socket,Data}, State)
  when Tag =:= (State#state.tags)#exo_tags.data ->
    exo_socket:setopts(State#state.socket, [{active, once}]),
    Buf = <<(State#state.buf)/binary, Data/binary>>,
    lager:debug("got data ~p", [Buf]),
    case Buf of
	%% victron bug for error codes?
	<<TransID:16,_ProtoID:16,2:16,UnitID,1:1,Func:7,Params:1/binary,
	  Buf1/binary>> ->
	    State1 = handle_pdu(TransID, UnitID, 16#80+Func,
				Params, State#state { buf = Buf1 }),
	    {noreply, State1};
	<<TransID:16,_ProtoID:16,Length:16,Data1:Length/binary,Buf1/binary>> ->
	    case Data1 of
		<<UnitID,Func,Params/binary>> ->
		    State1 = handle_pdu(TransID, UnitID, Func,
					Params, State#state { buf = Buf1 }),
		    {noreply, State1};
		_ ->
		    lager:debug("data too short ~p", [Buf]),
		    {noreply, State#state { buf = Buf1 }}
	    end;
	_ ->
	    {noreply, State#state { buf = Buf }}
    end;
handle_info({Tag,_Socket},State) when
      Tag =:= (State#state.tags)#exo_tags.closed ->
    if State#state.reconnect ->
	    State1 = State#state { socket = undefined, is_active = false },
	    {noreply, handle_reconnect({error,closed}, State1 )};
       true ->
	    {stop, closed, State}
    end;
handle_info({Tag,_Socket,Error},State) 
  when Tag =:= (State#state.tags)#exo_tags.error ->
    if State#state.reconnect ->
	    State1 = State#state { socket = undefined, is_active = false },
	    {noreply, handle_reconnect({error,Error}, State1)};
       true ->
	    {stop, error, State}
    end;
handle_info({timeout,T,reconnect}, State) 
  when T =:= State#state.reconnect_timer ->
    if State#state.socket =:= undefined ->
	    case connect(State#state.options) of
		{ok,Socket} ->
		    exo_socket:setopts(Socket, [{active, once}]),
		    {noreply, State#state { socket=Socket,
					    is_active = true}};
		Error ->
		    lager:debug("unable to open socket ~p", [Error]),
		    Timer = start_timer(State#state.reconnect_interval,
					reconnect),
		    {noreply, State#state { reconnect_timer = Timer }}
	    end;
       true ->
	    lager:warning("reconnect timeout while socket open",[]),
	    {noreply,State}
    end;
handle_info(_Info, State) ->
    lager:warning("got info ~p", [_Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

handle_pdu(TransID, UnitID1, Func1, Pdu, State) ->
    case lists:keytake(TransID, 1, State#state.requests) of
	false ->
	    lager:warning("transaction ~p not found", [TransID]),
	    State;
	{value,{_,UnitID,Func,From},Reqs} when 
	      UnitID =:= UnitID1; UnitID =:= 255 ->
	    lager:debug("unit_id=~p,func=~p, matched unit_id=~p,func=~p",
			[UnitID1,Func1,UnitID,Func]),
	    case Pdu of
		<<ErrorCode>> when  Func + 16#80 =:= Func1 ->
		    gen_server:reply(From, {error, ErrorCode}),
		    State#state { requests = Reqs };
		Data when Func =:= Func1 ->
		    %% FIXME: some more cases here
		    gen_server:reply(From, {ok,Data}),
		    State#state { requests = Reqs };
		_ ->
		    lager:warning("unmatched response pdu ~p", [Pdu]),
		    gen_server:reply(From, {error, internal}),
		    State#state { requests = Reqs }
	    end;
	_ ->
	    lager:warning("reply from other unit ~p", [Pdu]),
	    State
    end.

exo_tags(Socket) ->
    {Data,Closed,Error} = exo_socket:tags(Socket),
    #exo_tags { data = Data,
		closed = Closed,
		error = Error }.

handle_reconnect(Error, State) ->
    lists:foreach(
      fun({_,_UnitID,_Func,From}) ->
	      gen_server:reply(From, Error)
      end, State#state.requests),
    Timer = start_timer(State#state.reconnect_interval, reconnect),
    State#state { reconnect_timer = Timer, requests = [], buf = <<>> }.

connect(Opts0) ->
    Opts = Opts0 ++ application:get_all_env(modbus),
    Host = proplists:get_value(host, Opts, "localhost"),
    Port = proplists:get_value(port, Opts, ?DEFAULT_TCP_PORT),
    Timeout = proplists:get_value(timeout, Opts, ?DEFAULT_TIMEOUT),
    Protocol = proplists:get_value(protocol, Opts, [tcp]),
    SocketOptions = [{mode,binary},{active,false},{nodelay,true},{packet,0}],
    exo_socket:connect(Host, Port, Protocol, SocketOptions, Timeout).

start_timer(undefined, _Tag) ->
    undefined;
start_timer(Timeout, Tag) ->
    erlang:start_timer(Timeout, self(), Tag).
