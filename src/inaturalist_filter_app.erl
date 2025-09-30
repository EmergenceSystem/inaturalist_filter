-module(inaturalist_filter_app).
-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% Handler callbacks
-export([handle/1]).

-define(INATURALIST_AUTOCOMPLETE_URL, "https://api.inaturalist.org/v1/taxa/autocomplete").
-define(INATURALIST_TAXA_URL, "https://api.inaturalist.org/v1/taxa").

%% Application behavior
start(_StartType, _StartArgs) ->
    {ok, Port} = em_filter:find_port(),
    em_filter_sup:start_link(inaturalist_filter, ?MODULE, Port).

stop(_State) ->
    ok.

%% @doc Handle incoming requests from the filter server.
%% This function is called by em_filter_server through Wade.
%% @param Body The request body (JSON binary or string)
%% @return JSON response as binary or string
handle(Body) when is_binary(Body) ->
    handle(binary_to_list(Body));

handle(Body) when is_list(Body) ->
    io:format("Bing Filter received body: ~p~n", [Body]),
    EmbryoList = generate_embryo_list(list_to_binary(Body)),
    Response = #{embryo_list => EmbryoList},
    jsone:encode(Response);

handle(_) ->
    jsone:encode(#{error => <<"Invalid request body">>}).

generate_embryo_list(JsonBinary) ->
    Search = case jsone:decode(JsonBinary, [{keys, atom}]) of
        SearchMap when is_map(SearchMap) ->
            Query = binary_to_list(maps:get(value, SearchMap, <<"">>)),
            Timeout = list_to_integer(binary_to_list(maps:get(timeout, SearchMap, <<"10">>))),
            Rank = binary_to_list(maps:get(rank, SearchMap, <<"">>)),
            MinObservations = list_to_integer(binary_to_list(maps:get(min_observations, SearchMap, <<"0">>))),
            IconicTaxonId = binary_to_list(maps:get(iconic_taxon_id, SearchMap, <<"">>)),
            {Query, Timeout, Rank, MinObservations, IconicTaxonId};
        _ ->
            {"", 10, "", 0, ""}
    end,
    
    {QueryValue, TimeoutSecs, RankFilter, MinObs, IconicTaxon} = Search,
    
    % Build the search URL
    SearchUrl = build_search_url(QueryValue, RankFilter, IconicTaxon),
    
    io:format("Search URL: ~s~n", [SearchUrl]),
    
    case httpc:request(get, {SearchUrl, []}, [{ssl, [{verify, verify_none}, {cacerts, public_key:cacerts_get()}]}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            extract_taxa_from_results(Body, QueryValue, TimeoutSecs, MinObs);
        {error, Reason} ->
            io:format("Error fetching search results: ~p~n", [Reason]),
            []
    end.

build_search_url(Query, Rank, IconicTaxonId) ->
    BaseUrl = ?INATURALIST_AUTOCOMPLETE_URL,
    QueryParam = case Query of
        "" -> "";
        _ -> "?q=" ++ uri_string:quote(Query)
    end,
    
    RankParam = case Rank of
        "" -> "";
        _ -> case QueryParam of
            "" -> "?rank=" ++ Rank;
            _ -> "&rank=" ++ Rank
        end
    end,
    
    IconicParam = case IconicTaxonId of
        "" -> "";
        _ -> case {QueryParam, RankParam} of
            {"", ""} -> "?iconic_taxon_id=" ++ IconicTaxonId;
            _ -> "&iconic_taxon_id=" ++ IconicTaxonId
        end
    end,
    
    lists:concat([BaseUrl, QueryParam, RankParam, IconicParam]).

extract_taxa_from_results(JsonData, SearchValue, TimeoutSecs, MinObservations) ->
    try jsone:decode(JsonData) of
        ParsedJson ->
            Results = case maps:get(<<"results">>, ParsedJson, []) of
                ResultsList when is_list(ResultsList) -> ResultsList;
                _ -> []
            end,
            
            StartTime = erlang:system_time(second),
            process_taxa(Results, SearchValue, StartTime, TimeoutSecs, MinObservations, [])
    catch
        _:Error ->
            io:format("Error parsing JSON: ~p~n", [Error]),
            []
    end.

process_taxa([], _SearchValue, _StartTime, _Timeout, _MinObs, Acc) ->
    lists:reverse(Acc);
process_taxa([Taxon | Rest], SearchValue, StartTime, Timeout, MinObs, Acc) ->
    CurrentTime = erlang:system_time(second),
    case CurrentTime - StartTime >= Timeout of
        true ->
            lists:reverse(Acc);
        false ->
            Name = safe_binary_to_list(maps:get(<<"name">>, Taxon, <<"">>)),
            CommonName = safe_binary_to_list(maps:get(<<"preferred_common_name">>, Taxon, <<"">>)),
            Rank = safe_binary_to_list(maps:get(<<"rank">>, Taxon, <<"">>)),
            ObsCount = maps:get(<<"observations_count">>, Taxon, 0),
            WikipediaUrl = safe_binary_to_list(maps:get(<<"wikipedia_url">>, Taxon, <<"">>)),
            IconicTaxonName = safe_binary_to_list(maps:get(<<"iconic_taxon_name">>, Taxon, <<"">>)),
            
            % Extract default photo URL
            PhotoUrl = case maps:get(<<"default_photo">>, Taxon, #{}) of
                PhotoMap when is_map(PhotoMap) ->
                    safe_binary_to_list(maps:get(<<"medium_url">>, PhotoMap, <<"">>));
                _ -> ""
            end,
            
            % Check filtering criteria
            case should_include_taxon(SearchValue, Name, CommonName, ObsCount, MinObs) of
                true ->
                    Resume = build_resume(Name, CommonName, Rank, ObsCount, IconicTaxonName),
                    Embryo = #{
                        properties => #{
                            <<"url">> => list_to_binary(WikipediaUrl),
                            <<"resume">> => list_to_binary(Resume),
                            <<"photo_url">> => list_to_binary(PhotoUrl),
                            <<"scientific_name">> => list_to_binary(Name),
                            <<"common_name">> => list_to_binary(CommonName),
                            <<"rank">> => list_to_binary(Rank),
                            <<"observations_count">> => ObsCount,
                            <<"iconic_taxon">> => list_to_binary(IconicTaxonName)
                        }
                    },
                    process_taxa(Rest, SearchValue, StartTime, Timeout, MinObs, [Embryo | Acc]);
                false ->
                    process_taxa(Rest, SearchValue, StartTime, Timeout, MinObs, Acc)
            end
    end.

should_include_taxon(SearchValue, Name, CommonName, ObsCount, MinObs) ->
    % Check minimum observations requirement
    ObsCountOk = ObsCount >= MinObs,
    
    % Check if search term matches
    SearchMatch = case SearchValue of
        "" -> true; % If no specific search, include all
        _ -> 
            contains_search_term(SearchValue, [Name, CommonName])
    end,
    
    ObsCountOk andalso SearchMatch.

contains_search_term(SearchValue, Targets) ->
    LowerSearchValue = string:to_lower(SearchValue),
    lists:any(fun(Target) ->
        LowerTarget = string:to_lower(Target),
        string:str(LowerTarget, LowerSearchValue) > 0 orelse
        string:str(LowerSearchValue, LowerTarget) > 0
    end, Targets).

build_resume(Name, CommonName, Rank, ObsCount, IconicTaxon) ->
    CommonNamePart = case CommonName of
        "" -> "";
        _ -> " (" ++ CommonName ++ ")"
    end,
    
    % Capitalize first letter of rank
    CapitalizedRank = case Rank of
        "" -> "";
        [H|T] -> [string:to_upper(H)] ++ string:to_lower(T)
    end,
    
    lists:concat([
        Name, CommonNamePart, 
        " - ", CapitalizedRank,
        " - ", integer_to_list(ObsCount), " observations",
        " - ", IconicTaxon
    ]).

%% Utility function to handle null values in binaries
safe_binary_to_list(null) -> "";
safe_binary_to_list(undefined) -> "";
safe_binary_to_list(<<>>) -> "";
safe_binary_to_list(Binary) when is_binary(Binary) -> binary_to_list(Binary);
safe_binary_to_list(_) -> "".
