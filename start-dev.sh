#!/bin/sh
# NOTE: mustache templates need \ because they are not awesome.
exec erl -pa ebin -boot start_sasl \
    -s ssl \
    -s mnesia \
    -s appmon \
    -s apns
