#!/usr/bin/env bash

set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
script="$project_dir/ss-2022-alpine.sh"

sh -n "$script"

# Load the functions without invoking main. Process substitution keeps the
# production script POSIX-sh compatible while allowing this test to use Bash.
# shellcheck disable=SC1090
source <(sed '$d' "$script")

validate_port 443
! validate_port 0
! validate_port 65536
! validate_port abc

validate_node_name node-443
validate_node_name hk_01
! validate_node_name BadName
! validate_node_name -bad
! validate_node_name bad-
[[ "$(normalize_node_name OVHupload-1)" == "ovhupload-1" ]]

validate_method 2022-blake3-aes-128-gcm
validate_method 2022-blake3-aes-256-gcm
validate_method 2022-blake3-chacha20-poly1305
! validate_method aes-256-gcm

password_128=$(generate_password 2022-blake3-aes-128-gcm)
password_256=$(generate_password 2022-blake3-aes-256-gcm)
validate_password 2022-blake3-aes-128-gcm "$password_128"
validate_password 2022-blake3-aes-256-gcm "$password_256"
! validate_password 2022-blake3-aes-256-gcm "$password_128"
! validate_password 2022-blake3-aes-128-gcm 'not base64'

validate_host ss.example.com
validate_host 2001:db8::1
! validate_host 'bad/host'
! validate_host 'bad host'

uri=$(make_share_uri hk 1.2.3.4 443 2022-blake3-aes-128-gcm 'AAAAAAAAAAAAAAAAAAAAAA==')
[[ "$uri" == ss://*@1.2.3.4:443#hk ]]
[[ "$uri" != *'='* ]]

ipv6_uri=$(make_share_uri hk 2001:db8::1 443 2022-blake3-aes-128-gcm 'AAAAAAAAAAAAAAAAAAAAAA==')
[[ "$ipv6_uri" == ss://*@\[2001:db8::1\]:443#hk ]]

ensure_dependencies() { :; }
menu_output=$(printf '0\n' | interactive_menu 2>&1)
[[ "$menu_output" == *'Shadowsocks 2022 - Alpine'* ]]

printf 'smoke tests: ok\n'
