#!/bin/bash
# Resumable Zimbra Migration Script
# Usage: ./zimbra_export_accounts.sh [OPTIONS]
# Version: 12.1

### Configuration ###
readonly ZIMBRA_FOLDER="/opt/zimbra"
readonly ZIMBRA_BIN="${ZIMBRA_FOLDER}/bin"
readonly EXPORT_USER_FOLDER="${ZIMBRA_FOLDER}/backups/accounts-data"
readonly LOG_FILE="${EXPORT_USER_FOLDER}/zimbra_export_$(date +%Y%m%d_%H%M%S).log"
readonly IMPORT_SCRIPT_DIR="${EXPORT_USER_FOLDER}/import_scripts"
readonly STATE_FILE="${EXPORT_USER_FOLDER}/export_state.json"

declare -Ar SUB_DIRS=(
    ["MAILBOX_SIZES"]="${EXPORT_USER_FOLDER}/mailbox_sizes"
    ["USERPASS"]="${EXPORT_USER_FOLDER}/userpass"
    ["USERDATA"]="${EXPORT_USER_FOLDER}/userdata"
    ["DL_MEMBERS"]="${EXPORT_USER_FOLDER}/dl_members"
    ["FORWARDING"]="${EXPORT_USER_FOLDER}/forwarding"
    ["ALIAS"]="${EXPORT_USER_FOLDER}/alias"
    ["SIGNATURES"]="${EXPORT_USER_FOLDER}/signatures"
    ["FILTERS"]="${EXPORT_USER_FOLDER}/filters"
    ["DOMAINS"]="${EXPORT_USER_FOLDER}/domains"
    ["DL_ATTRIBUTES"]="${EXPORT_USER_FOLDER}/dl_attributes"
    ["RESOURCES"]="${EXPORT_USER_FOLDER}/resources"
    ["GLOBAL_CONFIG"]="${EXPORT_USER_FOLDER}/global_config"
)

### Options ###
FORCE_PASSWORD_RESET=false
INCLUDE_GLOBAL_CONFIG=false
RSYNC_USER="zimbra"
RESUME=false

### Help Functions ###
show_help() {
    cat <<EOF
Usage: ${0##*/} [OPTIONS]

Resumable Zimbra migration with progress tracking:
- Password retention/reset control
- Global config export (safe)
- Custom rsync user specification
- Resume from last completed step

Options:
  -h, --help                  Show this help
  -r, --force-password-reset  Force password reset on new server
  -g, --include-global-config Export safe global settings
  -u, --rsync-user USER       Specify rsync user (default: zimbra)
  --resume                    Resume from last interrupted state

Examples:
  # Standard migration
  sudo ./${0##*/}
  
  # Resume previous migration
  sudo ./${0##*/} --resume
  
  # Full migration with resume capability
  sudo ./${0##*/} -r -g -u ubuntu --resume
EOF
    exit 0
}

### Parse Arguments ###
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -r | --force-password-reset)
            FORCE_PASSWORD_RESET=true
            shift
            ;;
        -g | --include-global-config)
            INCLUDE_GLOBAL_CONFIG=true
            shift
            ;;
        -u | --rsync-user)
            [[ -n $2 ]] || {
                echo "ERROR: Missing username for --rsync-user" >&2
                exit 1
            }
            RSYNC_USER="$2"
            shift 2
            ;;
        --resume)
            RESUME=true
            shift
            ;;
        -h | --help | help)
            show_help
            ;;
        *)
            echo "ERROR: Unknown option $1" >&2
            show_help
            exit 1
            ;;
        esac
    done
}

### Utility Functions ###
log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

create_dir() {
    mkdir -p "$1" || {
        log "ERROR: Failed to create directory $1"
        exit 1
    }
    chown zimbra:zimbra "$1" && chmod 775 "$1" || {
        log "ERROR: Permission change failed for $1"
        exit 1
    }
}

# Initialize state file
init_state() {
    if $RESUME && [[ -f "$STATE_FILE" ]]; then
        log "Resuming from previous state"
    else
        log "Starting new export"
        cat >"$STATE_FILE" <<EOF
{
    "global_config": false,
    "domains": false,
    "distribution_lists": false,
    "resources": false,
    "admins": false,
    "users": false,
    "user_data": false,
    "import_scripts": false,
    "transfer_instructions": false,
    "exported_users": []
}
EOF
    fi
}

# Update state file
update_state() {
    local key="$1"
    local value="$2"
    local tmpfile="${STATE_FILE}.tmp"

    jq ".${key} = ${value}" "$STATE_FILE" >"$tmpfile" &&
        mv "$tmpfile" "$STATE_FILE" &&
        chown zimbra:zimbra "$STATE_FILE"
}

# Read state value
get_state() {
    local key="$1"
    jq -r ".${key}" "$STATE_FILE"
}

# Progress bar with resume support
progress_bar() {
    local current=$1
    local total=$2
    local width=50
    local percent=$((current * 100 / total))
    local done_chars=$((current * width / total))
    local left_chars=$((width - done_chars))

    printf "\r  ["
    [[ $done_chars -gt 0 ]] && printf "%0.s#" $(seq 1 $done_chars)
    [[ $left_chars -gt 0 ]] && printf "%0.s " $(seq 1 $left_chars)
    printf "] %d%% (%d/%d)" $percent $current $total
}

### Initialization ###
init_environment() {
    [[ $EUID -eq 0 ]] || {
        log "ERROR: Must run as root"
        exit 1
    }

    [[ -d "${ZIMBRA_BIN}" ]] || {
        log "ERROR: Zimbra not installed or incorrect path"
        exit 1
    }

    create_dir "$EXPORT_USER_FOLDER"
    create_dir "$IMPORT_SCRIPT_DIR"

    for dir in "${SUB_DIRS[@]}"; do
        create_dir "$dir"
    done

    init_state

    log "=== Environment initialized ==="
    log "OPTIONS:"
    log "  Password reset: $($FORCE_PASSWORD_RESET && echo "ENABLED" || echo "DISABLED")"
    log "  Global config: $($INCLUDE_GLOBAL_CONFIG && echo "INCLUDED" || echo "EXCLUDED")"
    log "  Rsync user: $RSYNC_USER"
    log "  Resume mode: $($RESUME && echo "ENABLED" || echo "DISABLED")"
}

### Export Functions with Resume Support ###
export_global_config() {
    if $(get_state "global_config"); then
        log "Skipping global config (already exported)"
        return
    fi

    if $INCLUDE_GLOBAL_CONFIG; then
        log "Exporting global configuration"
        local file="${SUB_DIRS[GLOBAL_CONFIG]}/global_settings.txt"

        "${ZIMBRA_BIN}/zmprov" gcf |
            grep -Ev '^(zimbraLdap|zimbraAuth|zimbraMail|zimbraMta|zimbraSpam|zimbraServerHostname|zimbraServiceHostname)' \
                >"$file"

        echo "# WARNING: Do not import LDAP/auth/mail settings to new server" >>"$file"
        log "Global config exported"
        update_state "global_config" "true"
    else
        log "Skipping global config export (not requested)"
        update_state "global_config" "true"
    fi
}

export_domains() {
    if $(get_state "domains"); then
        log "Skipping domains (already exported)"
        return
    fi

    log "Exporting domains"
    local file="${SUB_DIRS[DOMAINS]}/domains.txt"
    "${ZIMBRA_BIN}/zmprov" gad | sort >"$file"

    local domains=($(cat "$file"))
    local total=${#domains[@]}
    local current=0

    log "Found $total domains"
    for domain in "${domains[@]}"; do
        current=$((current + 1))
        # Sanitize domain for filename
        local domain_safe=$(echo "$domain" | sed 's/[^a-zA-Z0-9]/_/g')
        local domain_file="${SUB_DIRS[DOMAINS]}/${domain_safe}.txt"

        # Skip if domain file already exists
        if [[ -f "$domain_file" ]]; then
            log "Skipping domain $current/$total: $domain (already exists)"
            continue
        fi

        log "Exporting domain $current/$total: $domain"
        "${ZIMBRA_BIN}/zmprov" gd "$domain" >"$domain_file"
        progress_bar $current $total
    done
    printf "\n"
    log "Domain export completed"
    update_state "domains" "true"
}

export_admins() {
    if $(get_state "admins"); then
        log "Skipping admins (already exported)"
        return
    fi

    log "Exporting admin accounts"
    local file="${EXPORT_USER_FOLDER}/admins.txt"
    "${ZIMBRA_BIN}/zmprov" gaaa | sort >"$file"

    local count=$(wc -l <"$file")
    log "$count admin accounts exported"
    update_state "admins" "true"
}

export_distribution_lists() {
    if $(get_state "distribution_lists"); then
        log "Skipping distribution lists (already exported)"
        return
    fi

    log "Exporting distribution lists"
    local file="${SUB_DIRS[DL_ATTRIBUTES]}/distribution_lists.txt"
    "${ZIMBRA_BIN}/zmprov" gadl | sort >"$file"

    local dls=($(cat "$file"))
    local total=${#dls[@]}
    local current=0

    log "Found $total distribution lists"
    for dl in "${dls[@]}"; do
        current=$((current + 1))
        # Sanitize DL for filename
        local dl_safe=$(echo "$dl" | sed 's/[^a-zA-Z0-9]/_/g')
        
        log "Exporting DL $current/$total: $dl"

        # DL attributes
        local dl_file="${SUB_DIRS[DL_ATTRIBUTES]}/${dl_safe}.txt"
        if [[ ! -f "$dl_file" ]]; then
            "${ZIMBRA_BIN}/zmprov" gdl "$dl" >"$dl_file"
        fi

        # DL members
        local members_file="${SUB_DIRS[DL_MEMBERS]}/${dl_safe}_members.txt"
        if [[ ! -f "$members_file" ]]; then
            "${ZIMBRA_BIN}/zmprov" gdlm "$dl" >"$members_file"
        fi

        progress_bar $current $total
    done
    printf "\n"
    log "Distribution lists exported"
    update_state "distribution_lists" "true"
}

export_resources() {
    if $(get_state "resources"); then
        log "Skipping resources (already exported)"
        return
    fi

    log "Exporting resources"
    local file="${SUB_DIRS[RESOURCES]}/resources.txt"
    "${ZIMBRA_BIN}/zmprov" gar | sort >"$file"

    local resources=($(cat "$file"))
    local total=${#resources[@]}
    local current=0

    log "Found $total resources"
    for resource in "${resources[@]}"; do
        current=$((current + 1))
        # Sanitize resource for filename
        local resource_safe=$(echo "$resource" | sed 's/[^a-zA-Z0-9]/_/g')
        local resource_file="${SUB_DIRS[RESOURCES]}/${resource_safe}.txt"

        if [[ -f "$resource_file" ]]; then
            log "Skipping resource $current/$total: $resource (already exists)"
            continue
        fi

        log "Exporting resource $current/$total: $resource"
        "${ZIMBRA_BIN}/zmprov" gr "$resource" >"$resource_file"
        progress_bar $current $total
    done
    printf "\n"
    log "Resources exported"
    update_state "resources" "true"
}

export_users() {
    if $(get_state "users"); then
        log "Skipping user list (already exported)"
        return
    fi

    log "Exporting user accounts"
    local file="${EXPORT_USER_FOLDER}/emails.txt"
    "${ZIMBRA_BIN}/zmprov" -l gaa | sort >"$file"

    local count=$(wc -l <"$file")
    log "$count user accounts found"
    update_state "users" "true"
}

export_user_data() {
    if $(get_state "user_data"); then
        log "Skipping user data (already exported)"
        return
    fi

    [[ -f "${EXPORT_USER_FOLDER}/emails.txt" ]] || {
        log "ERROR: User list not found"
        return 1
    }

    local users=($(cat "${EXPORT_USER_FOLDER}/emails.txt"))
    local total=${#users[@]}
    local current=0

    # Get already exported users from state
    local saved_users=($(jq -r '.exported_users[]' "$STATE_FILE"))
    local saved_count=${#saved_users[@]}

    log "Exporting user data ($saved_count/$total already completed)"

    for user in "${users[@]}"; do
        # Check if user already processed
        if printf '%s\n' "${saved_users[@]}" | grep -q "^${user}$"; then
            current=$((current + 1))
            progress_bar $current $total
            continue
        fi

        process_user "$user"
        current=$((current + 1))

        # Update state with new user
        jq --arg user "$user" '.exported_users += [$user]' "$STATE_FILE" >"${STATE_FILE}.tmp"
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
        chown zimbra:zimbra "$STATE_FILE"

        progress_bar $current $total
    done
    printf "\n"
    log "User data exported"
    update_state "user_data" "true"
}

process_user() {
    local user="$1"
    export_mailbox_size "$user"
    export_user_attributes "$user"
}

export_mailbox_size() {
    local user="$1"
    local user_safe=$(echo "$user" | sed 's/[^a-zA-Z0-9]/_/g')
    local size_file="${SUB_DIRS[MAILBOX_SIZES]}/${user_safe}.txt"

    if [[ ! -f "$size_file" ]]; then
        local size
        size=$("${ZIMBRA_BIN}/zmmailbox" -z -m "$user" getMailboxSize 2>/dev/null | awk '{print $2}')
        [[ -n "$size" ]] && echo "$size" >"$size_file"
    fi
}

export_user_attributes() {
    local user="$1"
    local user_safe=$(echo "$user" | sed 's/[^a-zA-Z0-9]/_/g')

    # Export password hash
    local pass_file="${SUB_DIRS[USERPASS]}/${user_safe}.shadow"
    "${ZIMBRA_BIN}/zmprov" -l ga "$user" userPassword 2>/dev/null |
        awk '/userPassword:/ {print $2}' >"$pass_file"

    # Export full user attributes
    local user_file="${SUB_DIRS[USERDATA]}/${user_safe}.txt"
    "${ZIMBRA_BIN}/zmprov" ga "$user" >"$user_file"

    # Export aliases
    local alias_file="${SUB_DIRS[ALIAS]}/${user_safe}.txt"
    "${ZIMBRA_BIN}/zmprov" ga "$user" |
        awk '/zimbraMailAlias/ {print $2}' >"$alias_file"

    # Export forwarding
    local forward_file="${SUB_DIRS[FORWARDING]}/${user_safe}.txt"
    "${ZIMBRA_BIN}/zmprov" -l ga "$user" zimbraPrefMailForwardingAddress 2>/dev/null |
        awk '!/#/ && NF {print $2}' >"$forward_file"

    # Export signatures
    local sig_file="${SUB_DIRS[SIGNATURES]}/${user_safe}.html"
    "${ZIMBRA_BIN}/zmprov" ga "$user" zimbraPrefMailSignatureHTML |
        sed -n '/zimbraPrefMailSignatureHTML:/,$p' |
        sed '1s/zimbraPrefMailSignatureHTML: //' >"$sig_file"

    # Export signature name
    local sig_name_file="${SUB_DIRS[SIGNATURES]}/${user_safe}.name"
    "${ZIMBRA_BIN}/zmprov" ga "$user" zimbraSignatureName |
        sed '1d;s/zimbraSignatureName: //' >"$sig_name_file"

    # Export filters
    local filter_file="${SUB_DIRS[FILTERS]}/${user_safe}.filter"
    "${ZIMBRA_BIN}/zmprov" ga "$user" zimbraMailSieveScript |
        sed -n '/zimbraMailSieveScript:/,$p' |
        sed '1s/zimbraMailSieveScript: //' >"$filter_file"
}

generate_transfer_instructions() {
    if $(get_state "transfer_instructions"); then
        log "Skipping transfer instructions (already generated)"
        return
    fi

    log "Generating transfer instructions"
    local instructions="${EXPORT_USER_FOLDER}/transfer_instructions.txt"
    
    cat >"$instructions" <<EOF
Zimbra Migration Transfer Instructions
=====================================
Generated: $(date)

1. Transfer Data to New Server:
   rsync -avz -e ssh --progress \\
   ${EXPORT_USER_FOLDER}/ \\
   ${RSYNC_USER}@new-server:${EXPORT_USER_FOLDER}/

   rsync -avz -e ssh --progress /opt/zimbra/backups/accounts-data/ ubuntu@mbox.emploijeunes.ci:/opt/zimbra/backups/accounts-data

rsync -avz -e "ssh -T -o StrictHostKeyChecking=no -o Compression=no" \
--progress -c --stats --human-readable \
/opt/zimbra/backups/accounts-data/ \
ubuntu@mbox.emploijeunes.ci:/opt/zimbra/backups/accounts-data

2. On New Server, Run Import Scripts in Order:
   sudo ${IMPORT_SCRIPT_DIR}/0_recover_store.sh
   sudo -u zimbra ${IMPORT_SCRIPT_DIR}/1_import_domains.sh
   sudo -u zimbra ${IMPORT_SCRIPT_DIR}/2_import_accounts.sh
   sudo -u zimbra ${IMPORT_SCRIPT_DIR}/3_import_dls.sh
   sudo -u zimbra ${IMPORT_SCRIPT_DIR}/4_import_resources.sh
   sudo -u zimbra ${IMPORT_SCRIPT_DIR}/5_import_settings.sh

3. Post-Import Verification:
   - Check import logs in ${EXPORT_USER_FOLDER}/import_logs/
   - Validate mailbox access for test accounts
   - Verify distribution list membership
   - Test resource booking functionality

Notes:
- Store location: /opt/zimbra/store/0
- All scripts support resume functionality
- Total accounts exported: $(wc -l < "${EXPORT_USER_FOLDER}/emails.txt")
- Total domains exported: $(wc -l < "${SUB_DIRS[DOMAINS]}/domains.txt")
EOF

    update_state "transfer_instructions" "true"
}

### Cleanup ###
cleanup() {
    log "Cleaning empty files"
    find "${EXPORT_USER_FOLDER}" -type f -empty -delete -print |
        while read -r file; do
            log "Deleted: $file"
        done
}

### Main ###
main() {
    parse_arguments "$@"
    init_environment

    # Export sequence with resume support
    export_global_config
    export_domains
    export_distribution_lists
    export_resources
    export_admins
    export_users
    export_user_data
    generate_transfer_instructions

    cleanup
    log "Export completed successfully (Duration: ${SECONDS}s)"

    # Archive state file after successful run
    if [[ -f "$STATE_FILE" ]]; then
        archive_file="${STATE_FILE}.completed_$(date +%Y%m%d_%H%M%S)"
        mv "$STATE_FILE" "$archive_file"
        log "State file archived: $archive_file"
    fi
}

### Execution ###
trap 'log "Script interrupted"; exit 1' INT TERM
SECONDS=0
main "$@"
exit 0