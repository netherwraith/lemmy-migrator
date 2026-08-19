#!/usr/bin/env bash

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${ROOT}/lemmy-migrator.sh"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

# shellcheck source=../lemmy-migrator.sh
source "$SCRIPT"

passed=0
failed=0

pass() { echo "ok - $1"; ((passed++)); }
fail() { echo "not ok - $1"; ((failed++)); }

run_test() {
    local name="$1"
    shift
    if ("$@"); then pass "$name"; else fail "$name"; fi
}

test_resume_state_is_target_scoped() {
    EXPORT_DIR="${TEST_TMP}/export"
    [[ "$(resume_key 'https://one.example' 'https://remote.example/c/test')" != \
       "$(resume_key 'https://two.example' 'https://remote.example/c/test')" ]]
}

test_legacy_resume_state_is_migrated() {
    EXPORT_DIR="${TEST_TMP}/legacy"
    mkdir -p "$EXPORT_DIR"
    printf '%s\n' 'https://remote.example/c/test' >"${EXPORT_DIR}/.imported_communities"
    prepare_resume_state 'https://target.example'
    grep -qxF "$(resume_key 'https://target.example' 'https://remote.example/c/test')" "$RESUME_FILE"
}

test_dry_run_does_not_create_resume_state() {
    local export_dir="${TEST_TMP}/dry-run"
    mkdir -p "$export_dir"
    printf '%s\n' '{"format":"lemmy-migrator","format_version":1,"communities":[{"name":"test","ap_id":"https://remote.example/c/test"}]}' >"${export_dir}/communities.json"
    (
        EXPORT_DIR="$export_dir"
        DRY_RUN=1
        login() { API_VERSION=4; API_BASE='https://target.example/api/v4'; }
        resolve_community() { RESOLVED_ID=42; }
        do_import 'https://target.example' '' '' 'token' >/dev/null
    )
    [[ ! -e "${export_dir}/.imported_communities" ]]
}

test_incomplete_v4_page_is_rejected() {
    local output
    if output=$( (
        EXPORT_DIR="${TEST_TMP}/incomplete"
        login() { API_VERSION=4; API_BASE='https://source.example/api/v4'; }
        api_request() { API_HTTP_CODE=200; API_RESPONSE='{"items":[]}'; }
        do_export 'https://source.example' '' '' 'token'
    ) 2>&1); then
        return 1
    fi
    [[ "$output" == *'incomplete pagination response'* ]]
}

test_repeated_v4_cursor_is_rejected() {
    local output counter_file="${TEST_TMP}/cursor-count"
    printf '0\n' >"$counter_file"
    if output=$( (
        EXPORT_DIR="${TEST_TMP}/cursor"
        login() { API_VERSION=4; API_BASE='https://source.example/api/v4'; }
        api_request() {
            local count
            count=$(<"$counter_file")
            printf '%s\n' "$((count + 1))" >"$counter_file"
            API_HTTP_CODE=200
            API_RESPONSE='{"items":[{"community":{"name":"test","ap_id":"https://remote.example/c/test"}}],"next_page":"same"}'
        }
        do_export 'https://source.example' '' '' 'token'
    ) 2>&1); then
        return 1
    fi
    [[ "$output" == *'repeated page cursor'* ]]
}

test_status_is_retried() {
    local initial_status="$1" counter_file="${TEST_TMP}/retry-count-${1}"
    printf '0\n' >"$counter_file"
    REQUEST_DELAY=0
    MAX_RETRIES=2
    RETRY_BASE_DELAY=0
    sleep() { :; }
    curl() {
        local output_file='' header_file='' previous='' arg count
        for arg in "$@"; do
            [[ "$previous" == '-o' ]] && output_file="$arg"
            [[ "$previous" == '-D' ]] && header_file="$arg"
            previous="$arg"
        done
        count=$(<"$counter_file")
        count=$((count + 1))
        printf '%s\n' "$count" >"$counter_file"
        if [[ "$count" -eq 1 ]]; then
            [[ "$initial_status" -eq 429 ]] && printf 'Retry-After: 0\r\n' >"$header_file" || : >"$header_file"
            printf '{"error":"transient"}' >"$output_file"
            printf '%s' "$initial_status"
        else
            : >"$header_file"
            printf '{"ok":true}' >"$output_file"
            printf '200'
        fi
    }
    api_request GET 'https://target.example/api/v4/site' >/dev/null 2>&1
    [[ "$(<"$counter_file")" -eq 2 && "$API_HTTP_CODE" -eq 200 && "$API_RESPONSE" == '{"ok":true}' ]]
}

test_rate_limit_is_retried() { test_status_is_retried 429; }
test_server_error_is_retried() { test_status_is_retried 503; }

test_missing_option_value_is_rejected() {
    local output
    output=$("$SCRIPT" export --source 2>&1)
    [[ $? -ne 0 && "$output" == *'--source requires a non-empty value'* ]]
}

test_empty_option_value_is_rejected() {
    local output
    output=$("$SCRIPT" import --export-dir '' 2>&1)
    [[ $? -ne 0 && "$output" == *'--export-dir requires a non-empty value'* ]]
}

test_next_option_is_not_consumed_as_value() {
    local output
    output=$("$SCRIPT" export --source --token token 2>&1)
    [[ $? -ne 0 && "$output" == *'--source requires a non-empty value'* ]]
}

test_invalid_retry_configuration_is_rejected() {
    local output
    output=$(MAX_RETRIES=invalid "$SCRIPT" export --source https://source.example --token token 2>&1)
    [[ $? -ne 0 && "$output" == *'MAX_RETRIES must be a non-negative integer'* ]]
}

run_test 'resume state is scoped to the target' test_resume_state_is_target_scoped
run_test 'legacy resume state is migrated to the current target' test_legacy_resume_state_is_migrated
run_test 'dry runs do not create resume state' test_dry_run_does_not_create_resume_state
run_test 'incomplete API v4 pages are rejected' test_incomplete_v4_page_is_rejected
run_test 'repeated API v4 cursors are rejected' test_repeated_v4_cursor_is_rejected
run_test 'HTTP 429 responses are retried' test_rate_limit_is_retried
run_test 'HTTP 503 responses are retried' test_server_error_is_retried
run_test 'missing option values are rejected' test_missing_option_value_is_rejected
run_test 'empty option values are rejected' test_empty_option_value_is_rejected
run_test 'another option is not consumed as a value' test_next_option_is_not_consumed_as_value
run_test 'invalid retry configuration is rejected' test_invalid_retry_configuration_is_rejected

echo "${passed} passed, ${failed} failed"
[[ "$failed" -eq 0 ]]
