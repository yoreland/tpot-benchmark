#!/usr/bin/env bash
# =============================================================================
# tpot-benchmark i18n (internationalization) library — issue #9
# =============================================================================
# Minimal, dependency-light message-catalog loader for the shell CLIs.
#
# Usage from a script:
#     source "$(dirname "$0")/lib/i18n.sh"
#     i18n_init "$LANG_FLAG"        # LANG_FLAG may be empty
#     t usage.title "$0"           # prints the localized string, %s expanded
#
# Language resolution order (first non-empty wins), English as the fallback:
#     1. explicit argument to i18n_init (the --lang CLI flag)
#     2. $TPOT_LANG environment variable
#     3. the language part of $LANG / $LC_ALL (e.g. zh_CN.UTF-8 -> zh)
#     4. "en"
#
# Only languages that have a locale file (locales/<lang>.json) are honored;
# an unknown request falls back to English. Any key missing from the selected
# locale falls back to the English catalog, and a key missing there too is
# printed verbatim so a typo is visible rather than silent.
#
# Requires: jq (already used elsewhere in this repo).
# =============================================================================

# Resolve the repository's locales/ directory relative to this file so the
# library works from any worktree / checkout path.
I18N_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
I18N_LOCALES_DIR="${I18N_LOCALES_DIR:-$(cd "$I18N_LIB_DIR/../.." && pwd)/locales}"

I18N_LANG="en"
I18N_FALLBACK_LANG="en"
# Associative arrays holding the loaded catalogs (key -> message).
declare -A I18N_MESSAGES
declare -A I18N_FALLBACK

# _i18n_detect_lang <explicit> -> echoes the resolved language code
_i18n_detect_lang() {
    local explicit="${1:-}"
    local raw=""
    if [[ -n "$explicit" ]]; then
        raw="$explicit"
    elif [[ -n "${TPOT_LANG:-}" ]]; then
        raw="$TPOT_LANG"
    elif [[ -n "${LC_ALL:-}" ]]; then
        raw="$LC_ALL"
    elif [[ -n "${LANG:-}" ]]; then
        raw="$LANG"
    fi
    # Normalize "zh_CN.UTF-8" / "en_US" -> "zh" / "en"
    raw="${raw%%.*}"
    raw="${raw%%_*}"
    raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    [[ -z "$raw" ]] && raw="$I18N_FALLBACK_LANG"
    printf '%s' "$raw"
}

# _i18n_load_catalog <lang> <assoc-array-name>
# Loads locales/<lang>.json into the named associative array. Returns 1 if the
# locale file does not exist, so the caller can fall back.
_i18n_load_catalog() {
    local lang="$1" target="$2" file="$I18N_LOCALES_DIR/$1.json"
    [[ -f "$file" ]] || return 1
    local key val
    # jq emits NUL-delimited key<TAB>value pairs; _meta.* is skipped.
    while IFS=$'\t' read -r -d '' key val; do
        printf -v "${target}[$key]" '%s' "$val"
    done < <(jq -j 'to_entries[] | select(.key | startswith("_meta") | not)
                    | .key + "\t" + (.value|tostring) + "\u0000"' "$file")
    return 0
}

# i18n_init [explicit-lang]
# Call once after argument parsing. Loads the fallback (English) catalog and
# the selected-language catalog (if different and available).
i18n_init() {
    local requested
    requested="$(_i18n_detect_lang "${1:-}")"

    # Always load English as the fallback catalog.
    I18N_FALLBACK=()
    _i18n_load_catalog "$I18N_FALLBACK_LANG" I18N_FALLBACK || true

    I18N_MESSAGES=()
    if [[ "$requested" == "$I18N_FALLBACK_LANG" ]]; then
        I18N_LANG="$I18N_FALLBACK_LANG"
    elif _i18n_load_catalog "$requested" I18N_MESSAGES; then
        I18N_LANG="$requested"
    else
        # Requested locale has no file — fall back to English.
        I18N_LANG="$I18N_FALLBACK_LANG"
    fi
}

# t <key> [printf-args...]
# Prints the localized message for <key>, expanding %s/%d placeholders with the
# remaining arguments. Falls back to English, then to the raw key.
t() {
    local key="$1"; shift
    local template=""
    if [[ "$I18N_LANG" != "$I18N_FALLBACK_LANG" && -n "${I18N_MESSAGES[$key]+_}" ]]; then
        template="${I18N_MESSAGES[$key]}"
    elif [[ -n "${I18N_FALLBACK[$key]+_}" ]]; then
        template="${I18N_FALLBACK[$key]}"
    else
        template="$key"
    fi
    # shellcheck disable=SC2059  # template is a trusted catalog format string
    printf "$template" "$@"
}

# i18n_lang -> echoes the resolved language code (for diagnostics/tests)
i18n_lang() {
    printf '%s' "$I18N_LANG"
}
