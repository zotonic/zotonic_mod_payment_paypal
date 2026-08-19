%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Payment PSP module for PayPal
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

-module(mod_payment_paypal).

-mod_title("Payments using PayPal").
-mod_description("Payments using Payment Service Provider PayPal").
-mod_author("Driebit").
-mod_depends([ mod_payment ]).
-mod_config([
    #{
        key => is_live,
        type => boolean,
        default => false,
        description => "Use the live PayPal checkout environment instead of the sandbox environment."
    },
    #{
        key => client_id,
        type => binary,
        default => <<>>,
        description => "PayPal REST API client id."
    },
    #{
        key => secret,
        type => binary,
        default => <<>>,
        description => "PayPal REST API secret."
    },
    #{
        key => webhook_id,
        type => binary,
        default => <<>>,
        description => "PayPal webhook id, used for webhook signature verification."
    }
]).

-author("Marc Worrell <marc@worrell.nl>").

-export([
    observe_payment_psp_request/2,
    observe_payment_psp_view_url/2,
    observe_payment_psp_status_sync/2
]).

-include_lib("zotonic_core/include/zotonic.hrl").
-include_lib("zotonic_mod_payment/include/payment.hrl").


%% @doc Payment request, make new payment with PayPal, return payment details and a
%% redirect uri for the user to handle the payment.
observe_payment_psp_request(#payment_psp_request{
        payment_nr = PaymentNr,
        preferred_psp_module = PreferredPspModule
    }, Context) when PreferredPspModule =:= undefined;
                     PreferredPspModule =:= ?MODULE ->
    m_payment_paypal_api:create(PaymentNr, Context);
observe_payment_psp_request(#payment_psp_request{}, _Context) ->
    undefined.

%% @doc Return the URL where the given payment can be viewed on the PayPal website.
observe_payment_psp_view_url(#payment_psp_view_url{ psp_module = ?MODULE, psp_external_id = OrderId }, Context) ->
    {ok, m_payment_paypal_api:payment_url(OrderId, Context)};
observe_payment_psp_view_url(#payment_psp_view_url{}, _Context) ->
    undefined.

%% @doc Synchronize the payment status from PayPal to the local payment tables.
observe_payment_psp_status_sync(#payment_psp_status_sync{
        payment_id = PaymentId,
        psp_module = ?MODULE,
        psp_external_id = OrderId
    }, Context) ->
    case m_payment_paypal_api:sync_order_status(OrderId, Context) of
        {ok, _} ->
            ok;
        {error, 404} = Error ->
            ?LOG_WARNING(#{
                in => zotonic_mod_payment_paypal,
                text => <<"PayPal payment order not found for payment">>,
                result => error,
                reason => not_found,
                payment_id => PaymentId,
                paypal_order_id => OrderId
            }),
            cancel_missing_open_payment(PaymentId, OrderId, Error, Context);
        {error, _} = Error ->
            Error
    end;
observe_payment_psp_status_sync(#payment_psp_status_sync{}, _Context) ->
    undefined.

-spec cancel_missing_open_payment(PaymentId, OrderId, Error, Context) -> Result
    when
        PaymentId :: integer(),
        OrderId :: binary(),
        Error :: {error, 404},
        Context :: z:context(),
        Result :: ok | {error, term()}.
cancel_missing_open_payment(PaymentId, OrderId, Error, Context) ->
    case m_payment:get(PaymentId, Context) of
        {ok, #{
            <<"payment_nr">> := PaymentNr,
            <<"status">> := Status
        }}
            when Status =:= new;
                 Status =:= pending ->
            case m_payment_paypal_api:mark_order_cancelled(PaymentNr, Context) of
                {ok, {PaymentNr, cancelled}} ->
                    ?LOG_WARNING(#{
                        in => zotonic_mod_payment_paypal,
                        text => <<"PayPal payment set to cancelled because the order could not be found">>,
                        result => ok,
                        reason => paypal_order_not_found,
                        payment_id => PaymentId,
                        paypal_order_id => OrderId,
                        previous_status => Status,
                        status => cancelled
                    }),
                    ok;
                {error, _} = CancelError ->
                    CancelError
            end;
        {ok, _Payment} ->
            Error;
        {error, _} = PaymentError ->
            PaymentError
    end.
