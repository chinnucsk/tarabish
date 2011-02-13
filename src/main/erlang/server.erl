-module(server).

-include("tarabish_thrift.hrl").
-include("tarabish_constants.hrl").

-export([start/0, start/1, stop/1, handle_function/2, getVersion/0,
    createAccount/3]).

getVersion() ->
  ?tarabish_PROTOCOL_VERSION.

% TODO: return Client object from server.
createAccount(Name, Email, Password) ->
  case account:create(Name, Email, Password) of
      {ok, _} -> ok;
      {error, Reason} -> throw(#invalidOperation{why=atom_to_list(Reason)});
      _ -> throw(#invalidOperation{why="Unknown"})
  end.
 
start() ->
  start(65222).

start(Port) ->
  Handler = ?MODULE,
  {ok, Pid} = thrift_socket_server:start([{handler, Handler},
%  thrift_socket_server:start([{handler, Handler},
                              {service, tarabish_thrift},
                              {port, Port},
                              {name, tarabish_server},
                              {socket_opts, [{recv_timeout, 60*60*1000}]}]),
  unlink(Pid),
  {ok, Pid}.

stop(Server) ->
  Server ! thrift_socket_server:stop(Server).

handle_function(Function, Args) when is_atom(Function), is_tuple(Args) ->
  case apply(?MODULE, Function, tuple_to_list(Args)) of
    ok -> ok;
    Reply -> {reply, Reply}
  end.