%%%-------------------------------------------------------------------
%%% @author Fernando Benavides <fernando.benavides@inakanetworks.com>
%%% @copyright (C) 2010 Fernando Benavides <fernando.benavides@inakanetworks.com>
%%% @doc apns4erl connection process
%%% @end
%%%-------------------------------------------------------------------
-module(apns_connection).
-author('Fernando Benavides <fernando.benavides@inakanetworks.com>').

-behaviour(gen_server).

-include("apns.hrl").
-include("localized.hrl").

-export([start_link/1, start_link/2, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([send_message/2, stop/1]).

-record(state, {is_connected = false,
		msg,
	        out_socket        :: tuple(),
                in_socket         :: tuple(),
                connection        :: #apns_connection{},
                in_buffer = <<>>  :: binary(),
                out_buffer = <<>> :: binary()}).
-type state() :: #state{}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Public API
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc  Sends a message to apple through the connection
-spec send_message(apns:conn_id(), #apns_msg{}) -> ok.
send_message(ConnId, Msg) ->
  gen_server:cast(ConnId, Msg).

%% @doc  Stops the connection
-spec stop(apns:conn_id()) -> ok.
stop(ConnId) ->
  gen_server:cast(ConnId, stop).

%% @hidden
-spec start_link(atom(), #apns_connection{}) -> {ok, pid()} | {error, {already_started, pid()}}.
start_link(Name, Connection) ->
  gen_server:start_link({local, Name}, ?MODULE, Connection, []).
%% @hidden
-spec start_link(#apns_connection{}) -> {ok, pid()}.
start_link(Connection) ->
  gen_server:start_link(?MODULE, Connection, []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Server implementation, a.k.a.: callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @hidden
-spec init(#apns_connection{}) -> {ok, state()} | {stop, term()}.
init(Connection) ->
    {ok, #state{connection = Connection}}.

%% @hidden
-spec handle_call(X, reference(), state()) -> {stop, {unknown_request, X}, {unknown_request, X}, state()}.
handle_call(Request, _From, State) ->
  {stop, {unknown_request, Request}, {unknown_request, Request}, State}.

%% @hidden
-spec handle_cast(stop | #apns_msg{}, state()) -> {noreply, state()} | {stop, normal | {error, term()}, state()}.
handle_cast(Msg, State) when is_record(Msg, apns_msg) ->
  {Res, Data} = case State#state.is_connected of
	       true ->
		   {ok, State#state.out_socket};
	       false ->
		   case connect(State#state.connection) of
		       {ok, Sock} ->
			   {ok, Sock};
		       {error, Rea} ->
			   error_logger:error_msg("SSL connect error ~p", [Rea]),
			   {error, Rea}
		   end
		end,
    
    case Res of
	ok ->
	    Socket = Data,
	    Payload = build_payload([{alert, Msg#apns_msg.alert},
                           {badge, Msg#apns_msg.badge},
                           {sound, Msg#apns_msg.sound}], Msg#apns_msg.extra),
	    BinToken = hexstr_to_bin(Msg#apns_msg.device_token),
	    case send_payload(Socket, Msg#apns_msg.id, Msg#apns_msg.expiry, BinToken, Payload) of
		ok ->
		    apns_scheduler:done_working(self()),
		    {noreply, State#state{is_connected = true, out_socket = Socket, msg = Msg}};
		{error, Reason} ->
		    error_logger:error_msg("Send message: ~p error: ~p", [Msg, Reason]),
		    apns_scheduler:send_message_failed(Msg),
		    apns_scheduler:done_working(self())
	    end;
	error ->
	    apns_scheduler:send_message_failed(Msg),
	    apns_scheduler:done_working(self()),

	    {noreply, State}
    end;

handle_cast(stop, State) ->
  {stop, normal, State}.

%% @hidden
-spec handle_info({ssl, tuple(), binary()} | {ssl_closed, tuple()} | X, state()) -> {noreply, state()} | {stop, ssl_closed | {unknown_request, X}, state()}.
handle_info({ssl, SslSocket, Data}, State = #state{out_socket = SslSocket,
                                                   connection =
                                                     #apns_connection{error_fun = Error},
                                                   out_buffer = CurrentBuffer}) ->
    NewState = State#state{msg = undefined},
  case <<CurrentBuffer/binary, Data/binary>> of
    <<Command:1/unit:8, StatusCode:1/unit:8, MsgId:4/binary, Rest/binary>> ->
      case Command of
        8 -> %% Error
	      apns_scheduler:send_message_failed(NewState#state.msg),
          Status = parse_status(StatusCode),
          try Error(MsgId, Status) of
            stop -> throw({stop, {msg_error, MsgId, Status}, NewState});
            _ -> noop
          catch
            _:ErrorResult ->
              error_logger:error_msg("Error trying to inform error (~p) msg ~p:~n\t~p~n",
                                     [Status, MsgId, ErrorResult])
          end,
          case erlang:size(Rest) of
            0 -> {noreply, State#state{out_buffer = <<>>}}; %% It was a whole package
            _ -> handle_info({ssl, SslSocket, Rest}, State#state{out_buffer = <<>>})
          end;
        Command ->
          throw({stop, {unknown_command, Command}, NewState})
      end;
    NextBuffer -> %% We need to wait for the rest of the message
      {noreply, State#state{out_buffer = NextBuffer}}
  end;

handle_info({ssl_closed, SslSocket}, State = #state{out_socket = SslSocket}) ->
  {stop, normal, State};
handle_info(Request, State) ->
  {stop, {unknown_request, Request}, State}.

%% @hidden
-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) -> 
    apns_scheduler:stop_working(self()),
    ok.

%% @hidden
-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->  {ok, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Private functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
build_payload(Params, Extra) ->
  apns_mochijson2:encode(
    {[{<<"aps">>, do_build_payload(Params, [])} | Extra]}).
do_build_payload([{Key,Value}|Params], Payload) ->
  case Value of
    Value when is_list(Value); is_binary(Value) ->
      do_build_payload(Params, [{atom_to_binary(Key, utf8), unicode:characters_to_binary(Value)} | Payload]);
    Value when is_integer(Value) ->
      do_build_payload(Params, [{atom_to_binary(Key, utf8), Value} | Payload]);
    #loc_alert{action = Action,
               args   = Args,
               body   = Body,
               image  = Image,
               key    = LocKey} ->
      Json = {case Body of
                none -> [];
                Body -> [{<<"body">>, unicode:characters_to_binary(Body)}]
              end ++ case Action of
                       none -> [];
                       Action -> [{<<"action-loc-key">>, unicode:characters_to_binary(Action)}]
                     end ++ case Image of
                              none -> [];
                              Image -> [{<<"launch-image">>, unicode:characters_to_binary(Image)}]
                            end ++
                [{<<"loc-key">>, unicode:characters_to_binary(LocKey)},
                 {<<"loc-args">>, lists:map(fun unicode:characters_to_binary/1, Args)}]},
      do_build_payload(Params, [{atom_to_binary(Key, utf8), Json} | Payload]);
    _ ->
      do_build_payload(Params,Payload)
  end;
do_build_payload([], Payload) ->
  {Payload}.

-spec send_payload(tuple(), binary(), non_neg_integer(), binary(), iolist()) -> ok | {error, term()}.
send_payload(Socket, MsgId, Expiry, BinToken, Payload) ->
    BinPayload = list_to_binary(Payload),
    PayloadLength = erlang:size(BinPayload),
    Packet = [<<1:8, MsgId/binary, Expiry:4/big-unsigned-integer-unit:8,
                32:16/big,
                BinToken/binary,
                PayloadLength:16/big,
                BinPayload/binary>>],
    error_logger:info_msg("Sending msg ~p (expires on ~p):~s~n~p~n",
                         [MsgId, Expiry, BinPayload, Packet]),
    ssl:send(Socket, Packet),
    error_logger:info_msg("Sending done").

hexstr_to_bin(S) ->
  hexstr_to_bin(S, []).
hexstr_to_bin([], Acc) ->
  list_to_binary(lists:reverse(Acc));
hexstr_to_bin([$ |T], Acc) ->
    hexstr_to_bin(T, Acc);
hexstr_to_bin([X,Y|T], Acc) ->
  {ok, [V], []} = io_lib:fread("~16u", [X,Y]),
  hexstr_to_bin(T, [V | Acc]).

bin_to_hexstr(Binary) ->
    L = size(Binary),
    Bits = L * 8,
    <<X:Bits/big-unsigned-integer>> = Binary,
    F = lists:flatten(io_lib:format("~~~B.16.0B", [L * 2])),
    lists:flatten(io_lib:format(F, [X])).

parse_status(0) -> no_errors;
parse_status(1) -> processing_error;
parse_status(2) -> missing_token;
parse_status(3) -> missing_topic;
parse_status(4) -> missing_payload;
parse_status(5) -> missing_token_size;
parse_status(6) -> missing_topic_size;
parse_status(7) -> missing_payload_size;
parse_status(8) -> invalid_token;
parse_status(_) -> unknown.

connect(Connection) ->
    try
	SSLParameters = [{certfile, filename:absname(Connection#apns_connection.cert_file)},
			 {mode, binary} |
			 case Connection#apns_connection.key_file of
			     undefined -> [];
			     KeyFile -> [{keyfile, filename:absname(KeyFile)}]
			 end],
	SSLParameters2 =  case Connection#apns_connection.cert_password of
			      undefined -> SSLParameters;
			      Password -> [{password, Password} | SSLParameters]
			  end,
	case ssl:connect(
	       Connection#apns_connection.apple_host,
	       Connection#apns_connection.apple_port,
	       SSLParameters2,
	       Connection#apns_connection.timeout) of
	    {ok, OutSocket} ->
		{ok,  OutSocket};
	    {error, Reason} ->
		{error, Reason}
	end
    catch
	_:{error, Reason2} ->
	    {error, Reason2}
    end.
