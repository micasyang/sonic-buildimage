#!/usr/bin/env bash

mkdir -p /etc/supervisor/conf.d

# Generate supervisord router advertiser config, /etc/radvd.conf config file, and
# the script that waits for pertinent interfaces to come up and make it executable
CFGGEN_PARAMS=" \
    -d \
    -t /usr/share/sonic/templates/docker-bmc.supervisord.conf.j2,/etc/supervisor/conf.d/supervisord.conf \
"
sonic-cfggen $CFGGEN_PARAMS

exec /usr/local/bin/supervisord
