%% @copyright 2026 Marc Worrell
%% @doc Handle PayPal webhook callbacks.
%% @end

%% Copyright 2026 Marc Worrell
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(controller_paypal_webhook).

-author("Marc Worrell <marc@worrell.nl>").

-export([
    allowed_methods/1,
    is_authorized/1,
    process/4
]).

-include_lib("zotonic_core/include/zotonic.hrl").

allowed_methods(Context) ->
    {[ <<"POST">> ], Context}.

is_authorized(Context) ->
    {Body, Context1} = cowmachine_req:req_body(Context),
    case decode_json(Body) of
        {ok, Event} ->
            case m_payment_paypal_api:is_valid_webhook_signature(Body, Context1) of
                true ->
                    Context2 = z_context:set(<<"body">>, Body, Context1),
                    {true, z_context:set(<<"paypal_event">>, Event, Context2)};
                false ->
                    ?LOG_ERROR(#{
                        in => zotonic_mod_payment_paypal,
                        text => <<"PayPal webhook: invalid signature">>,
                        result => error,
                        reason => invalid_signature
                    }),
                    {<<"PayPal-Transmission-Sig">>, Context1}
            end;
        {error, Reason} ->
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_paypal,
                text => <<"PayPal webhook: invalid JSON">>,
                result => error,
                reason => Reason
            }),
            {<<"PayPal-Webhook-JSON">>, Context1}
    end.

process(<<"POST">>, _AcceptedCT, _ProvidedCT, Context) ->
    Event = z_context:get(<<"paypal_event">>, Context),
    case m_payment_paypal_api:webhook_event(Event, Context) of
        ok ->
            {true, Context};
        {error, notfound} ->
            {{halt, 404}, Context};
        {error, _} ->
            {{halt, 500}, Context}
    end.

decode_json(Body) ->
    try
        case z_json:decode(Body) of
            Event when is_map(Event) ->
                {ok, Event};
            _ ->
                {error, json_not_object}
        end
    catch
        _:_ ->
            {error, json_decode}
    end.
