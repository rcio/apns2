%% Connection Parameters
-record(apns_connection, {apple_host        = "gateway.push.apple.com"      :: string(),
                          apple_port        = 2195                                  :: integer(),
                          cert_file         = "priv/cert.pem"                       :: string(),
                          key_file          = undefined                             :: undefined | string(),
			  cert_password     = undefined				    :: undefined | string(),
                          timeout           = 30000                                 :: integer()
                          }).
-record(apns_msg, {id = apns:message_id()       :: binary(),
                   expiry = apns:expiry(86400)  :: non_neg_integer(), %% default = 1 day
                   device_token                 :: string(),
                   alert = none                 :: none | apns:alert(),
                   badge = none                 :: none | integer(),
                   sound = none                 :: none | string(),
                   extra = []                   :: [apns_mochijson2:json_property()],
		   retry = 0}).
