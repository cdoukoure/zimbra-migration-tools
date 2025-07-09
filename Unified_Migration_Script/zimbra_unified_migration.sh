#!/bin/bash

### Zimbra Unified Migration Script (Export, Import & FullSync)
# Auteur : Jean Charles DOUKOURE
# License : GNU GPL v3 + clause de non-responsabilité (voir README)

set -euo pipefail
shopt -s failglob

#######################################
# CONFIGURATION PAR DÉFAUT
#######################################
DEFAULT_EXPORT_DIR="/opt/zimbra/backups/remote"
DEFAULT_USER_LIST="/home/ubuntu/users.txt"
DEFAULT_JOBS=10
LOCK_FILE="/tmp/zimbra_migration.lock"
MIN_DISK_SPACE=20  # en Go

#######################################
# FONCTIONS UTILITAIRES
#######################################
log() {
    local level="INFO"
    [[ "$1" == *"❌"* ]] && level="ERROR"
    [[ "$1" == *"⚠️"* ]] && level="WARNING"
    printf "[%s] [%s] [PID:%d] %s\n" \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$$" "$1" \
      | tee -a "$EXPORT_DIR/global.log"
}

acquire_lock() {
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        local pid; pid=$(<"$LOCK_FILE")
        if ps -p "$pid" >/dev/null; then
            log "Un autre processus est déjà en cours (PID $pid)."
            exit 1
        else
            log "Verrou orphelin détecté. Nettoyage..."
            rm -f "$LOCK_FILE"
            flock -n 200 || exit 1
        fi
    fi
    echo $$ >"$LOCK_FILE"
    trap release_lock EXIT INT TERM
}

release_lock() {
    rm -f "$LOCK_FILE"
    exec 200>&-
}

get_optimal_jobs() {
    local cores; cores=$(nproc)
    local hour; hour=$(date +%H)
    if ((hour < 6)); then
        echo $((cores * 2))
    elif ((hour < 20)); then
        echo $((cores / 2))
    else
        echo "$cores"
    fi
}

validate_tgz() {
    tar tzf "$1" >/dev/null 2>&1
}

atomic_append() {
    local file="$1" content="$2" lock="${file}.lock"
    ( flock -x 200; echo "$content" >>"$file" ) 200>"$lock"
}

get_admin_token() {
    local user="$1" pass="$2" host="$3"
    curl -s -k -X POST -H "Content-Type: application/soap+xml" \
      -d "<soap:Envelope xmlns:soap=\"http://www.w3.org/2003/05/soap-envelope\">
             <soap:Body><AuthRequest xmlns=\"urn:zimbraAdmin\">
               <name>$user</name><password>$pass</password>
             </AuthRequest></soap:Body>
           </soap:Envelope>" \
      https://"$host":7071/service/admin/soap/ \
    | grep -oP '<authToken>\K[^<]+'
}

#######################################
# WORKER
#######################################
run_fullsync_worker() {
    local method="$1" user="$2" pass="$3"
    local out="$EXPORT_DIR/$user.tgz" temp_out="$out.tmp"
    local log_exp="$EXPORT_DIR/logs/$user.export.log"
    local log_imp="$EXPORT_DIR/logs/$user.import.log"

    printf "[%s] Début traitement pour %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$user" \
      >"$log_exp"
    printf "[%s] Début traitement pour %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$user" \
      >"$log_imp"

    # Ignorer si déjà importé
    if grep -qxF "$user" "$EXPORT_DIR/import_success.txt"; then
        log "[$user] ✅ Déjà importé. Ignoré."
        return 0
    fi

    # Attente d'espace disque
    while true; do
        local free_gb; free_gb=$(df -BG "$EXPORT_DIR" \
          | awk 'NR==2 {gsub("G","",$4);print $4}')
        (( free_gb >= MIN_DISK_SPACE )) && break
        log "[$user] ⛔ Espace insuffisant (${free_gb}G). Pause 15 min..."
        sleep 900
    done

    # Export si besoin
    if [ ! -s "$out" ] || ! validate_tgz "$out"; then
        rm -f "$out" "$temp_out"
        if [[ "$method" == token ]]; then
            wget -q --no-check-certificate \
              --header="Authorization: ZnAdminAuthToken $TOKEN" \
              "https://$HOST:7071/home/$user/?fmt=tgz" \
              -O "$temp_out" 2>>"$log_exp"
        else
            wget -q --no-check-certificate \
              --http-user="$ADMIN_USER" \
              --http-password="$pass" \
              "https://$HOST:7071/home/$user/?fmt=tgz" \
              -O "$temp_out" 2>>"$log_exp"
        fi
        if mv "$temp_out" "$out" && validate_tgz "$out"; then
            atomic_append "$EXPORT_DIR/success_list.txt" "$user"
            log "[$user] ✅ Export réussi."
        else
            rm -f "$temp_out"
            atomic_append "$EXPORT_DIR/failed_list.txt" "$user"
            log "[$user] ❌ Échec export."
            return 1
        fi
    else
        log "[$user] 📦 Archive déjà prête."
    fi

    # Import
    if [ -s "$out" ] && validate_tgz "$out"; then
        if su - zimbra -c \
           "/opt/zimbra/bin/zmmailbox -z -m $user postRestURL \"/?fmt=tgz\" \"$out\"" \
           >>"$log_imp" 2>&1; then
            atomic_append "$EXPORT_DIR/import_success.txt" "$user"
            rm -f "$out"
            log "[$user] ✅ Import réussi."
        else
            atomic_append "$EXPORT_DIR/import_failed.txt" "$user"
            log "[$user] ❌ Échec import."
        fi
    fi

    local done; done=$(wc -l <"$EXPORT_DIR/import_success.txt")
    log "[$user] 📊 Progression: $done/$TOTAL_USERS"
}

export -f run_fullsync_worker log validate_tgz atomic_append

#######################################
# LAUNCHER
#######################################
launch_sync() {
    local mode="$1" pass="$2"
    grep -v '^#\|^$' "$USER_LIST" | tr -d '\r' | sort | uniq \
    | xargs -P "$JOBS" -I {} \
        bash -c 'run_fullsync_worker "$1" "$2" "$3"' _ "$mode" {} "$pass"
}

#######################################
# MODE FULLSYNC (login/mdp)
#######################################
do_fullsync() {
    HOST="$1"; ADMIN_USER="$2"; local pass="$3"
    EXPORT_DIR="$4"; USER_LIST="$5"; JOBS="$6"
    TOTAL_USERS=$(grep -v '^#\|^$' "$USER_LIST" | sort | uniq | wc -l)
    export EXPORT_DIR HOST ADMIN_USER TOTAL_USERS JOBS
    launch_sync password "$pass"
}

#######################################
# MODE FULLSYNC_TOKEN (token SOAP)
#######################################
do_fullsync_token() {
    HOST="$1"; ADMIN_USER="$2"; local pass="$3"
    EXPORT_DIR="$4"; USER_LIST="$5"; JOBS="$6"
    TOKEN=$(get_admin_token "$ADMIN_USER" "$pass" "$HOST")
    TOTAL_USERS=$(grep -v '^#\|^$' "$USER_LIST" | sort | uniq | wc -l)
    export EXPORT_DIR HOST TOKEN TOTAL_USERS JOBS
    launch_sync token "-"
}

#######################################
# AIDE
#######################################
show_help() {
    cat <<EOF
Usage:
  $0 fullsync       -z HOST -a ADMIN -p PASS -o DIR -u USERS [-j JOBS]
  $0 fullsync_token -z HOST -a ADMIN -p PASS -o DIR -u USERS [-j JOBS]
EOF
}

#######################################
# MAIN
#######################################
main() {
    MODE="${1:-}"; shift || true
    [[ -z "$MODE" ]] && show_help && exit 1

    ZIMBRA_HOST=""; ADMIN_USER="admin@domain.com"; ADMIN_PASS=""
    EXPORT_DIR="$DEFAULT_EXPORT_DIR"; USER_LIST="$DEFAULT_USER_LIST"
    JOBS="$DEFAULT_JOBS"

    while [[ $# -gt 0 ]]; do
        case $1 in
            -z) ZIMBRA_HOST="$2"; shift 2;;
            -a) ADMIN_USER="$2"; shift 2;;
            -p) ADMIN_PASS="$2"; shift 2;;
            -o) EXPORT_DIR="$2"; shift 2;;
            -u) USER_LIST="$2"; shift 2;;
            -j) JOBS="$2"; shift 2;;
            -h|--help) show_help; exit 0;;
            *) echo "Option inconnue: $1"; exit 1;;
        esac
    done

    acquire_lock
    mkdir -p "$EXPORT_DIR/logs"
    touch "$EXPORT_DIR/global.log"
    for f in success_list.txt failed_list.txt import_success.txt import_failed.txt; do
        touch "$EXPORT_DIR/$f"
    done

    case "$MODE" in
        fullsync)       do_fullsync       "$ZIMBRA_HOST" "$ADMIN_USER" "$ADMIN_PASS" "$EXPORT_DIR" "$USER_LIST" "$JOBS";;
        fullsync_token) do_fullsync_token "$ZIMBRA_HOST" "$ADMIN_USER" "$ADMIN_PASS" "$EXPORT_DIR" "$USER_LIST" "$JOBS";;
        *) show_help; exit 1;;
    esac
}

main "$@"
