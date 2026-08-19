#!/usr/bin/env bash
# lemmy-migrator.sh
# Copyright (c) 2026 Oliver Pifferi, E-Mail: oliver@pifferi.io
# ---------------------
# Migrates community subscriptions between two Lemmy instances.
# Dependencies: curl, jq

set -o pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

EXPORT_DIR="${EXPORT_DIR:-lemmy_export}"
if [[ "$EXPORT_DIR" != /* ]]; then
    EXPORT_DIR="$(pwd)/${EXPORT_DIR}"
fi

REQUEST_DELAY="${REQUEST_DELAY:-0.5}"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_BASE_DELAY="${RETRY_BASE_DELAY:-1}"
DEBUG=0
DRY_RUN=0
ASSUME_YES=0
API_VERSION=""
API_BASE=""
API_TOKEN=""
RESUME_FILE="${EXPORT_DIR}/.imported_communities"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

usage() {
    cat <<'EOF'
Lemmy Migrator — export and import subscribed communities

Usage:
  ./lemmy-migrator.sh export --source URL [--user NAME --password PASS | --token TOKEN]
  ./lemmy-migrator.sh import --target URL [--user NAME --password PASS | --token TOKEN] [--dry-run] [--yes]
  ./lemmy-migrator.sh full   --source URL --source-user NAME --source-password PASS \
                             --target URL --target-user NAME --target-password PASS [--yes]

Options:
  --source URL       Source Lemmy instance
  --target URL       Target Lemmy instance
  --user NAME        Username or email for export/import
  --password PASS    Account password
  --token TOKEN      Lemmy JWT/Bearer token
  --dry-run          Resolve communities without subscribing
  --yes              Skip the confirmation prompt
  --debug            Verbose curl output (authorization headers are hidden)
  --export-dir PATH  Export directory (default: ./lemmy_export)
  -h, --help         Show this help

Credentials can also be supplied via SOURCE_TOKEN, SOURCE_PASSWORD,
TARGET_TOKEN and TARGET_PASSWORD environment variables.
EOF
}

die() { echo "  ✗ $*" >&2; exit 1; }
rdelay() { sleep "$REQUEST_DELAY"; }

check_deps() {
    local missing=() cmd
    for cmd in curl jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: Missing required tools: ${missing[*]}"
        echo "  Debian/Ubuntu: sudo apt install curl jq"
        echo "  macOS:         brew install jq"
        exit 1
    fi
}

normalise_url() {
    local url="${1%/}"
    [[ "$url" =~ ^https?://[^/]+$ ]] || die "Invalid instance URL: ${1}"
    printf '%s' "$url"
}

curl_args() {
    CURL_ARGS=(-sS --connect-timeout 15 --max-time 120)
}

api_request() {
    local method="$1" url="$2" data="${3:-}" tmp headers http_code rc
    local attempt=0 retry_delay retry_after
    while true; do
        tmp=$(mktemp)
        headers=$(mktemp)
        curl_args
        local args=("${CURL_ARGS[@]}" -D "$headers" -o "$tmp" -w '%{http_code}' -X "$method" \
            -H 'Accept: application/json')
        [[ -n "$API_TOKEN" ]] && args+=(-H "Authorization: Bearer ${API_TOKEN}")
        [[ -n "$data" ]] && args+=(-H 'Content-Type: application/json' -d "$data")
        [[ "$DEBUG" -eq 1 ]] && echo "  → ${method} ${url}" >&2
        rdelay
        rc=0
        http_code=$(curl "${args[@]}" "$url") || rc=$?
        API_RESPONSE=$(<"$tmp")
        API_HTTP_CODE="${http_code:-000}"
        retry_after=$(tr -d '\r' <"$headers" | sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*//p' | tail -n 1)
        rm -f "$tmp" "$headers"
        [[ "$DEBUG" -eq 1 ]] && echo "  ← HTTP ${API_HTTP_CODE}" >&2

        if [[ "$rc" -eq 0 && "$API_HTTP_CODE" != 429 && ! "$API_HTTP_CODE" =~ ^5[0-9][0-9]$ ]]; then
            return
        fi
        if [[ "$attempt" -ge "$MAX_RETRIES" ]]; then
            [[ "$rc" -eq 0 ]] && return
            die "Request failed after $((MAX_RETRIES + 1)) attempts: ${method} ${url} (curl ${rc})"
        fi

        retry_delay=$((RETRY_BASE_DELAY * (2 ** attempt)))
        if [[ "$API_HTTP_CODE" == 429 && "$retry_after" =~ ^[0-9]+$ ]]; then
            retry_delay="$retry_after"
        fi
        ((attempt++))
        echo "  Retrying ${method} ${url} in ${retry_delay}s (attempt $((attempt + 1))/$((MAX_RETRIES + 1))) ..." >&2
        sleep "$retry_delay"
    done
}

require_success() {
    local context="$1"
    if [[ "$API_HTTP_CODE" -lt 200 || "$API_HTTP_CODE" -gt 299 ]]; then
        local message
        message=$(jq -r '.error // .message // .' <<<"$API_RESPONSE" 2>/dev/null || printf '%s' "$API_RESPONSE")
        die "${context} failed (HTTP ${API_HTTP_CODE}): ${message}"
    fi
}

detect_api() {
    local instance="$1"
    api_request GET "${instance}/api/v4/site"
    if [[ "$API_HTTP_CODE" -ge 200 && "$API_HTTP_CODE" -le 299 ]]; then
        API_VERSION=4
    else
        api_request GET "${instance}/api/v3/site"
        require_success "API detection"
        API_VERSION=3
    fi
    API_BASE="${instance}/api/v${API_VERSION}"
}

login() {
    local instance="$1" username="$2" password="$3" token="$4"
    API_TOKEN="$token"
    detect_api "$instance"

    if [[ -n "$API_TOKEN" ]]; then
        echo "  Using Bearer token (API v${API_VERSION})."
        return
    fi
    [[ -n "$username" && -n "$password" ]] || \
        die "Provide --token or both --user and --password."

    echo "  Logging in to ${instance} as '${username}' (API v${API_VERSION}) ..."
    local path
    [[ "$API_VERSION" -eq 4 ]] && path="account/auth/login" || path="user/login"
    api_request POST "${API_BASE}/${path}" \
        "$(jq -nc --arg user "$username" --arg pass "$password" \
            '{username_or_email:$user,password:$pass}')"
    require_success "Login"
    API_TOKEN=$(jq -r '.jwt // empty' <<<"$API_RESPONSE")
    [[ -n "$API_TOKEN" ]] || die "Login response did not contain a token. Is 2FA enabled?"
    echo "  ✓ Login successful."
}

community_host() {
    jq -r 'try (.ap_id | capture("^https?://(?<host>[^/]+)").host) catch ""' <<<"$1"
}

community_handle() {
    local item="$1" name host
    name=$(jq -r '.name' <<<"$item")
    host=$(community_host "$item")
    [[ -n "$name" && -n "$host" ]] || return 1
    printf '!%s@%s' "$name" "$host"
}

resume_key() {
    printf '%s\t%s' "$1" "$2"
}

prepare_resume_state() {
    local target="$1" line tmp
    mkdir -p "$EXPORT_DIR"
    RESUME_FILE="${EXPORT_DIR}/.imported_communities"
    [[ -f "$RESUME_FILE" ]] || { touch "$RESUME_FILE"; return; }
    grep -qv $'\t' "$RESUME_FILE" || return

    tmp=$(mktemp "${EXPORT_DIR}/.imported_communities.XXXXXX")
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        if [[ "$line" == *$'\t'* ]]; then
            printf '%s\n' "$line"
        else
            resume_key "$target" "$line"
            printf '\n'
        fi
    done <"$RESUME_FILE" >"$tmp"
    mv "$tmp" "$RESUME_FILE"
}

require_option_value() {
    [[ $# -ge 2 ]] || die "${1} requires a non-empty value."
    [[ -n "$2" && "$2" != --* ]] || die "${1} requires a non-empty value."
}

validate_runtime_options() {
    [[ "$REQUEST_DELAY" =~ ^[0-9]+([.][0-9]+)?$ ]] || \
        die "REQUEST_DELAY must be a non-negative number."
    [[ "$MAX_RETRIES" =~ ^[0-9]+$ ]] || \
        die "MAX_RETRIES must be a non-negative integer."
    [[ "$RETRY_BASE_DELAY" =~ ^[0-9]+$ ]] || \
        die "RETRY_BASE_DELAY must be a non-negative integer."
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

do_export() {
    local source="$1" username="$2" password="$3" token="$4"
    mkdir -p "$EXPORT_DIR"
    echo "=== Lemmy subscription export ==="
    echo ""
    login "$source" "$username" "$password" "$token"
    echo ""
    echo "Fetching subscribed communities ..."

    local all='[]' page=1 cursor='' seen_cursors='' items next count backup_count
    if [[ "$API_VERSION" -eq 3 ]]; then
        # Lemmy 0.19 provides the canonical follow URLs directly in its settings
        # backup. This also works on private instances and has no pagination cap.
        api_request GET "${API_BASE}/user/export_settings"
        if [[ "$API_HTTP_CODE" -ge 200 && "$API_HTTP_CODE" -le 299 ]] && \
            jq -e '.followed_communities | type == "array"' <<<"$API_RESPONSE" >/dev/null 2>&1; then
            backup_count=$(jq '.followed_communities | length' <<<"$API_RESPONSE")
            all=$(jq -c --arg source "$source" '
                [.followed_communities[] as $ap_id
                 | ($ap_id | capture("^https?://(?<host>[^/]+)/c/(?<name>[^/?#]+)$")?) as $parts
                 | select($parts != null)
                 | {community: {
                     name: $parts.name,
                     title: $parts.name,
                     actor_id: $ap_id,
                     nsfw: false,
                     local: ($ap_id | startswith($source + "/"))
                   }}]' <<<"$API_RESPONSE")
            count=$(jq 'length' <<<"$all")
            [[ "$count" -eq "$backup_count" ]] || \
                die "The settings backup contained an invalid community URL."
        else
            # Compatibility fallback for Lemmy releases without settings backup.
            all='[]'
            while true; do
                api_request GET "${API_BASE}/community/list?type_=Subscribed&limit=50&page=${page}"
                require_success "Fetching communities"
                jq -e '.communities | type == "array"' <<<"$API_RESPONSE" >/dev/null 2>&1 || \
                    die "Fetching communities returned an incomplete pagination response."
                items=$(jq '.communities' <<<"$API_RESPONSE")
                count=$(jq 'length' <<<"$items")
                all=$(jq -cn --argjson a "$all" --argjson b "$items" '$a + $b')
                [[ "$count" -lt 50 ]] && break
                ((page++))
            done
        fi
    else
        while true; do
            local url="${API_BASE}/community/list?type_=subscribed&limit=50"
            [[ -n "$cursor" ]] && url+="&page_cursor=$(jq -rn --arg v "$cursor" '$v|@uri')"
            api_request GET "$url"
            require_success "Fetching communities"
            jq -e '(.items | type == "array") and has("next_page")' <<<"$API_RESPONSE" >/dev/null 2>&1 || \
                die "Fetching communities returned an incomplete pagination response."
            items=$(jq '.items' <<<"$API_RESPONSE")
            next=$(jq -r '.next_page // empty' <<<"$API_RESPONSE")
            count=$(jq 'length' <<<"$items")
            all=$(jq -cn --argjson a "$all" --argjson b "$items" '$a + $b')
            [[ "$count" -eq 0 ]] && break
            [[ -z "$next" ]] && break
            if grep -qxF "$next" <<<"$seen_cursors"; then
                die "Fetching communities returned a repeated page cursor."
            fi
            seen_cursors+="${next}"$'\n'
            cursor="$next"
        done
    fi

    local exported_at output
    exported_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    output=$(jq -cn --arg format 'lemmy-migrator' --argjson version 1 \
        --arg exported_at "$exported_at" --arg source "$source" --argjson api "$API_VERSION" \
        --argjson views "$all" '
        {format:$format,format_version:$version,exported_at:$exported_at,
         source_instance:$source,source_api_version:$api,
         communities: [$views[] | (.community // {}) | {
           name, title, ap_id:(.ap_id // .actor_id), nsfw, local
         }] | sort_by(.ap_id)}')
    jq -e '.communities | all(.name and .ap_id)' <<<"$output" >/dev/null || \
        die "The instance returned incomplete community data."
    printf '%s\n' "$output" >"${EXPORT_DIR}/communities.json"
    count=$(jq '.communities | length' <<<"$output")
    echo "  ✓ ${count} subscriptions saved to ${EXPORT_DIR}/communities.json"
}

# ---------------------------------------------------------------------------
# Import
# ---------------------------------------------------------------------------

resolve_community() {
    local ap_id="$1" handle="$2" query url
    query=$(jq -rn --arg v "$ap_id" '$v|@uri')
    url="${API_BASE}/resolve_object?q=${query}"
    api_request GET "$url"
    if [[ "$API_HTTP_CODE" -lt 200 || "$API_HTTP_CODE" -gt 299 ]]; then
        query=$(jq -rn --arg v "$handle" '$v|@uri')
        api_request GET "${API_BASE}/resolve_object?q=${query}"
    fi
    [[ "$API_HTTP_CODE" -ge 200 && "$API_HTTP_CODE" -le 299 ]] || return 1
    if [[ "$API_VERSION" -eq 4 ]]; then
        RESOLVED_ID=$(jq -r 'select(.type_ == "community") | .community.id // empty' <<<"$API_RESPONSE")
    else
        RESOLVED_ID=$(jq -r '.community.community.id // empty' <<<"$API_RESPONSE")
    fi
    [[ -n "$RESOLVED_ID" ]]
}

do_import() {
    local target="$1" username="$2" password="$3" token="$4"
    local file="${EXPORT_DIR}/communities.json"
    [[ -f "$file" ]] || die "Export not found: ${file}. Run 'export' first."
    jq -e '.format == "lemmy-migrator" and .format_version == 1 and (.communities|type == "array")' \
        "$file" >/dev/null || die "Invalid or unsupported export file: ${file}"

    echo "=== Lemmy subscription import ==="
    echo ""
    login "$target" "$username" "$password" "$token"
    RESUME_FILE="${EXPORT_DIR}/.imported_communities"
    local total
    total=$(jq '.communities | length' "$file")
    echo ""
    echo "${total} communities will be resolved on ${target}."
    [[ "$DRY_RUN" -eq 1 ]] && echo "Dry-run mode: no subscriptions will be changed."
    if [[ "$ASSUME_YES" -ne 1 && "$DRY_RUN" -ne 1 ]]; then
        [[ -t 0 ]] || die "Import needs confirmation. Re-run with --yes in non-interactive mode."
        read -r -p "Continue? [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] || { echo "Import cancelled."; return; }
    fi

    [[ "$DRY_RUN" -eq 1 ]] || prepare_resume_state "$target"
    local index=0 imported=0 skipped=0 failed=0 item ap_id handle payload
    while IFS= read -r item; do
        ((index++))
        ap_id=$(jq -r '.ap_id' <<<"$item")
        handle=$(community_handle "$item") || { echo "[${index}/${total}] ✗ Invalid entry"; ((failed++)); continue; }
        if [[ -f "$RESUME_FILE" ]] && grep -qxF "$(resume_key "$target" "$ap_id")" "$RESUME_FILE"; then
            echo "[${index}/${total}] ↩ Skipped (already imported): ${handle}"
            ((skipped++)); continue
        fi
        printf '[%s/%s] Resolving %s ... ' "$index" "$total" "$handle"
        if ! resolve_community "$ap_id" "$handle"; then
            echo "✗ not found"
            ((failed++)); continue
        fi
        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "✓ community ID ${RESOLVED_ID} (dry run)"
            ((imported++)); continue
        fi
        payload=$(jq -nc --argjson id "$RESOLVED_ID" '{community_id:$id,follow:true}')
        api_request POST "${API_BASE}/community/follow" "$payload"
        if [[ "$API_HTTP_CODE" -ge 200 && "$API_HTTP_CODE" -le 299 ]]; then
            echo "✓ subscribed"
            resume_key "$target" "$ap_id" >>"$RESUME_FILE"
            printf '\n' >>"$RESUME_FILE"
            ((imported++))
        else
            echo "✗ HTTP ${API_HTTP_CODE}: $(jq -r '.error // .message // "unknown error"' <<<"$API_RESPONSE" 2>/dev/null)"
            ((failed++))
        fi
    done < <(jq -c '.communities[]' "$file")

    echo ""
    echo "Import complete: ${imported} successful, ${skipped} skipped, ${failed} failed."
    [[ "$failed" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

main() {
    local command="${1:-}"
    [[ -n "$command" ]] || { usage; return 1; }
    case "$command" in export|import|full) shift ;; -h|--help) usage; return 0 ;; *) usage; return 1 ;; esac

    local source='' target='' username='' password='' token=''
    local source_user='' source_password="${SOURCE_PASSWORD:-}" source_token="${SOURCE_TOKEN:-}"
    local target_user='' target_password="${TARGET_PASSWORD:-}" target_token="${TARGET_TOKEN:-}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source) require_option_value "$@"; source="$2"; shift 2 ;;
            --target) require_option_value "$@"; target="$2"; shift 2 ;;
            --user) require_option_value "$@"; username="$2"; shift 2 ;;
            --password) require_option_value "$@"; password="$2"; shift 2 ;;
            --token) require_option_value "$@"; token="$2"; shift 2 ;;
            --source-user) require_option_value "$@"; source_user="$2"; shift 2 ;;
            --source-password) require_option_value "$@"; source_password="$2"; shift 2 ;;
            --source-token) require_option_value "$@"; source_token="$2"; shift 2 ;;
            --target-user) require_option_value "$@"; target_user="$2"; shift 2 ;;
            --target-password) require_option_value "$@"; target_password="$2"; shift 2 ;;
            --target-token) require_option_value "$@"; target_token="$2"; shift 2 ;;
            --export-dir)
                require_option_value "$@"
                EXPORT_DIR="$2"
                [[ "$EXPORT_DIR" != /* ]] && EXPORT_DIR="$(pwd)/$EXPORT_DIR"
                shift 2
                ;;
            --dry-run) DRY_RUN=1; shift ;; --yes) ASSUME_YES=1; shift ;;
            --debug) DEBUG=1; shift ;; -h|--help) usage; return 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    validate_runtime_options
    check_deps
    case "$command" in
        export)
            [[ -n "$source" ]] || die "--source is required."
            do_export "$(normalise_url "$source")" "$username" "${password:-${source_password:-}}" "${token:-${source_token:-}}"
            ;;
        import)
            [[ -n "$target" ]] || die "--target is required."
            do_import "$(normalise_url "$target")" "$username" "${password:-${target_password:-}}" "${token:-${target_token:-}}"
            ;;
        full)
            [[ -n "$source" && -n "$target" ]] || die "--source and --target are required."
            [[ -n "$source_token" || ( -n "$source_user" && -n "$source_password" ) ]] || \
                die "Provide --source-token or source username and password."
            [[ -n "$target_token" || ( -n "$target_user" && -n "$target_password" ) ]] || \
                die "Provide --target-token or target username and password."
            do_export "$(normalise_url "$source")" "$source_user" "$source_password" "$source_token"
            API_TOKEN=''; API_VERSION=''; API_BASE=''
            do_import "$(normalise_url "$target")" "$target_user" "$target_password" "$target_token"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
