%% @copyright 2026 Marc Worrell
%% @doc Handle PayPal return redirects after checkout approval or cancellation.
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

-module(controller_paypal_redirect).

-export([
    allowed_methods/1,
    resource_exists/1,
    previously_existed/1,
    moved_temporarily/1
]).

-include_lib("zotonic_core/include/zotonic.hrl").

allowed_methods(Context) ->
    {[ <<"GET">>, <<"POST">> ], Context}.

resource_exists(Context) ->
    {false, Context}.

previously_existed(Context) ->
    {true, Context}.

moved_temporarily(Context) ->
    % Args: token / status=cancel|ok / payment_nr / state
    PaymentNr = z_context:get_q(<<"payment_nr">>, Context),
    OrderId = z_context:get_q(<<"token">>, Context),
    case z_context:get_q(<<"status">>, Context) of
        <<"ok">> ->
            case m_payment_paypal_api:capture_order(OrderId, Context) of
                {ok, {CapturedPaymentNr, _Status}} ->
                    redirect(CapturedPaymentNr, Context);
                {error, _} ->
                    redirect(PaymentNr, Context)
            end;
        <<"cancel">> ->
            handle_cancel(PaymentNr, OrderId, Context);
        Status ->
            ?LOG_WARNING(#{
                in => zotonic_mod_payment_paypal,
                text => <<"PayPal redirect with unknown status">>,
                result => error,
                reason => unknown_status,
                payment_nr => PaymentNr,
                status => Status
            }),
            redirect(PaymentNr, Context)
    end.

%% PayPal's browser redirect is not signed and the Referer header is optional.
%% Authenticate the callback using our own signed, expiring state instead.
handle_cancel(PaymentNr, OrderId, Context) ->
    State = z_context:get_q(<<"state">>, Context),
    case decode_cancel_state(State, Context) of
        {ok, SignedPaymentNr} ->
            handle_signed_cancel(SignedPaymentNr, OrderId, Context);
        {error, Reason} ->
            ?LOG_WARNING(#{
                in => zotonic_mod_payment_paypal,
                text => <<"PayPal cancel redirect with invalid signed state">>,
                result => error,
                reason => Reason,
                payment_nr => PaymentNr
            }),
            sync_cancel_order(PaymentNr, OrderId, Context)
    end.

-spec decode_cancel_state(State, Context) -> Result
    when
        State :: binary() | undefined,
        Context :: z:context(),
        Result :: {ok, binary()} | {error, missing | expired | invalid}.
decode_cancel_state(undefined, _Context) ->
    {error, missing};
decode_cancel_state(State, Context) when is_binary(State) ->
    try z_crypto:decode_value_expire(State, Context) of
        {ok, {paypal_cancel, PaymentNr}} when is_binary(PaymentNr), PaymentNr =/= <<>> ->
            {ok, PaymentNr};
        {error, expired} ->
            {error, expired};
        _Other ->
            {error, invalid}
    catch
        _:_ ->
            {error, invalid}
    end.

handle_signed_cancel(PaymentNr, OrderId, Context) ->
    case m_payment:get(PaymentNr, Context) of
        {ok, #{
            <<"psp_module">> := mod_payment_paypal,
            <<"psp_external_id">> := OrderId
        }} when is_binary(OrderId), OrderId =/= <<>> ->
            case m_payment_paypal_api:cancel_payment(PaymentNr, OrderId, Context) of
                {ok, cancelled, {PaymentNr, cancelled}, PaypalStatus} ->
                    ?LOG_INFO(#{
                        in => zotonic_mod_payment_paypal,
                        text => <<"PayPal payment set to cancelled after checking the PayPal order status">>,
                        result => ok,
                        reason => paypal_cancel_redirect,
                        payment_nr => PaymentNr,
                        paypal_order_id => OrderId,
                        paypal_status => PaypalStatus,
                        status => cancelled
                    });
                {ok, synchronized, {PaymentNr, Status}, PaypalStatus} ->
                    ?LOG_WARNING(#{
                        in => zotonic_mod_payment_paypal,
                        text => <<"PayPal cancel redirect did not cancel an order in a non-cancelable PayPal state">>,
                        result => ok,
                        reason => paypal_order_not_cancelable,
                        payment_nr => PaymentNr,
                        paypal_order_id => OrderId,
                        paypal_status => PaypalStatus,
                        status => Status
                    });
                {error, {status, Status}} ->
                    ?LOG_WARNING(#{
                        in => zotonic_mod_payment_paypal,
                        text => <<"PayPal cancel redirect ignored for finalized payment">>,
                        result => error,
                        reason => finalized,
                        payment_nr => PaymentNr,
                        paypal_order_id => OrderId,
                        status => Status
                    });
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        in => zotonic_mod_payment_paypal,
                        text => <<"Could not cancel payment after valid signed PayPal cancel state">>,
                        result => error,
                        reason => Reason,
                        payment_nr => PaymentNr,
                        paypal_order_id => OrderId
                    })
            end,
            redirect(PaymentNr, Context);
        {ok, Payment} ->
            ?LOG_WARNING(#{
                in => zotonic_mod_payment_paypal,
                text => <<"PayPal cancel redirect does not match the local payment order">>,
                result => error,
                reason => order_mismatch,
                payment_nr => PaymentNr,
                paypal_order_id => OrderId,
                expected_paypal_order_id => maps:get(<<"psp_external_id">>, Payment, undefined)
            }),
            redirect(PaymentNr, Context);
        {error, Reason} ->
            ?LOG_WARNING(#{
                in => zotonic_mod_payment_paypal,
                text => <<"PayPal cancel redirect for unknown local payment">>,
                result => error,
                reason => Reason,
                payment_nr => PaymentNr,
                paypal_order_id => OrderId
            }),
            redirect(PaymentNr, Context)
    end.

sync_cancel_order(PaymentNr, OrderId, Context) ->
    case m_payment_paypal_api:sync_order_status(OrderId, Context) of
        {ok, {SyncedPaymentNr, _Status}} ->
            redirect(SyncedPaymentNr, Context);
        {error, _} ->
            redirect(PaymentNr, Context)
    end.

redirect(PaymentNr, Context) ->
    Args = [
        {payment_nr, PaymentNr}
    ],
    Location = z_context:abs_url(
        z_dispatcher:url_for(payment_psp_done, Args, none, Context),
        Context),
    {{true, Location}, Context}.
