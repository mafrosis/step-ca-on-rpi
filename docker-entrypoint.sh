#! /bin/bash
set -e

# The path to step-ca config is the only param, passed via docker command
# Substitute the Yubikey pin, passed via environment
# Also substitute the OIDC oAuth client secret, passed via environment
cat $1 | jq '.kms.pin |= env.YUBIKEY_PIN' | jq '.authority.provisioners[1].clientSecret |= env.OAUTH_CLIENT_SECRET' > /tmp/ca.json

exec step-ca /tmp/ca.json
