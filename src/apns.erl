%%-------------------------------------------------------------------
%% @author Fernando Benavides <fernando.benavides@inakanetworks.com>
%% @copyright (C) 2010 Fernando Benavides <fernando.benavides@inakanetworks.com>
%% @doc Apple Push Notification Server for Erlang
%% @end
%%-------------------------------------------------------------------
-module(apns).
-vsn('1.0').

-include("apns.hrl").
-include("localized.hrl").

-define(EPOCH, 62167219200).

-export([start/0, stop/0]).
-export([send_message/3]).
-export([message_id/0, expiry/1, timestamp/1]).

-type alert() :: string() | #loc_alert{}.
-export_type([alert/0]).

%% @doc Starts the application
-spec start() -> ok | {error, {already_started, apns}}.
start() ->
  _ = application:start(public_key),
  _ = application:start(ssl),
  application:start(apns).

%% @doc Stops the application
-spec stop() -> ok.
stop() ->
  application:stop(apns).

%% @doc Sends a message to Apple
send_message(Alert, Badge, DeviceToken) ->
    apns_scheduler:send_message(Alert, Badge, DeviceToken).

%% @doc  Generates an "unique" and valid message Id
-spec message_id() -> binary().
message_id() ->
  {_, _, MicroSecs} = erlang:now(),
  Secs = calendar:datetime_to_gregorian_seconds(calendar:universal_time()),
  First = Secs rem 65536,
  Last = MicroSecs rem 65536,
  <<First:2/unsigned-integer-unit:8, Last:2/unsigned-integer-unit:8>>.

%% @doc  Generates a valid expiry value for messages.
%%       If called with <code>none</code> as the parameter, it will return a <a>no-expire</a> value.
%%       If called with a datetime as the parameter, it will convert it to a valid expiry value.
%%       If called with an integer, it will add that many seconds to current time and return a valid
%%        expiry value for that date.
-spec expiry(none | {{1970..9999,1..12,1..31},{0..24,0..60,0..60}} | pos_integer()) -> non_neg_integer().
expiry(none) -> 0;
expiry(Secs) when is_integer(Secs) ->
  calendar:datetime_to_gregorian_seconds(calendar:universal_time()) - ?EPOCH + Secs;
expiry(Date) ->
  calendar:datetime_to_gregorian_seconds(Date) - ?EPOCH.

-spec timestamp(pos_integer()) -> calendar:datetime().
timestamp(Secs) ->
  calendar:gregorian_seconds_to_datetime(Secs + ?EPOCH).
