%% Concurrent ping-pong. Run with: escript main.erl

-module(main).
-mode(compile).
-export([main/1]).

ping(0, Pong) ->
    Pong ! finished,
    io:format("ping done~n");
ping(N, Pong) ->
    Pong ! {ping, self()},
    receive
        pong -> ping(N - 1, Pong)
    end.

pong() ->
    receive
        finished ->
            io:format("pong done~n");
        {ping, From} ->
            From ! pong,
            pong()
    end.

main(_Args) ->
    Pong = spawn(fun pong/0),
    spawn(fun() -> ping(5, Pong) end),
    timer:sleep(100),
    Numbers = lists:seq(1, 5),
    Squares = [N * N || N <- Numbers],
    io:format("squares: ~p~n", [Squares]),
    Total = lists:foldl(fun(X, Acc) -> X + Acc end, 0, Squares),
    io:format("sum: ~p~n", [Total]).
