#!/bin/bash

### Zimbra Unified Migration Script (Export, Import & FullSync)
# Auteur : Jean Charles DOUKOURE
# License : GNU GPL v3 + clause de non-responsabilité (voir README)

set -euo pipefail

#######################################
# CONFIGURATION PAR DEFAUT
#######################################
DEFAULT_EXPORT_DIR="/opt/zimbra/backups/remote"
DEFAULT_USER_LIST="/home/ubuntu/users.txt"
DEFAULT_JOBS=10
LOCK_FILE="/tmp/zimbra_migration.lock"

#######################################
# FONCTIONS UTILITAIRES
#######################################
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            log "Un autre processus est déjà en cours (PID $pid)."
            exit 1
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap release_lock EXIT INT TERM
}

release_lock() {
    rm -f "$LOCK_FILE"
}

get_admin_token() {
    local admin_user="$1"
    local admin_pass="$2"
    local zimbra_host="$3"

    curl -s -k -X POST \
        -H "Content-Type: application/soap+xml" \
        -d "<soap:Envelope xmlns:soap=\"http://www.w3.org/2003/05/soap-envelope\"><soap:Body><AuthRequest xmlns=\"urn:zimbraAdmin\"><name>$admin_user</name><password>$admin_pass</password></AuthRequest></soap:Body></soap:Envelope>" \
        https://$zimbra_host:7071/service/admin/soap/ | \
        grep -oP '<authToken>\K[^<]+'
}

get_optimal_jobs() {
    local cores=$(nproc)
    local hour=$(date +%H)
    if (( hour >= 0 && hour < 6 )); then
        echo $(( cores * 2 ))
    elif (( hour >= 6 && hour < 20 )); then
        echo $(( cores / 2 ))
    else
        echo $cores
    fi
}

#######################################
# EXPORT & IMPORT EN CHAINE (FullSync)
#######################################
do_fullsync() {
    local zimbra_host="$1"
    local admin_user="$2"
    local admin_pass="$3"
    local export_dir="$4"
    local user_file="$5"
    local jobs="$6"

    if [ "$jobs" == "auto" ]; then
        jobs=$(get_optimal_jobs)
    fi

    local success_export="$export_dir/success_list.txt"
    local failed_export="$export_dir/failed_list.txt"
    local success_import="$export_dir/import_success.txt"
    local failed_import="$export_dir/import_failed.txt"
    mkdir -p "$export_dir/logs"

    log "Obtention du token d'authentification..."
    token=$(get_admin_token "$admin_user" "$admin_pass" "$zimbra_host")

    export EXPORT_DIR="$export_dir"
    export TOKEN="$token"
    export HOST="$zimbra_host"

    log "Execution du mode FullSync avec $jobs jobs..."
    grep -v '^#\|^$' "$user_file" | sort | uniq | \
    xargs -P "$jobs" -I {} bash -c '
        user="$1"
        out="$EXPORT_DIR/$user.tgz"
        log_exp="$EXPORT_DIR/logs/$user.export.log"
        log_imp="$EXPORT_DIR/logs/$user.import.log"

        if [ ! -s "$out" ]; then
            curl --progress-bar --max-time 0 --connect-timeout 10 -k \
                -H "Authorization: ZnAdminAuthToken $TOKEN" \
                "https://$HOST:7071/home/$user/?fmt=tgz" -o "$out" >> "$log_exp" 2>&1 && \
            echo "$user" >> "$EXPORT_DIR/success_list.txt" || \
            { echo "$user" >> "$EXPORT_DIR/failed_list.txt"; exit 1; }
        fi

        if [ -s "$out" ]; then
            su - zimbra -c "/opt/zimbra/bin/zmmailbox -z -m $user postRestURL \"/?fmt=tgz\" \"$out\"" >> "$log_imp" 2>&1 && \
            echo "$user" >> "$EXPORT_DIR/import_success.txt" && rm -f "$out" || \
            echo "$user" >> "$EXPORT_DIR/import_failed.txt"
        fi
    ' _ {}
}

#######################################
# EXPORT DES BOITES MAIL
#######################################
do_export() {
    local zimbra_host="$1"
    local admin_user="$2"
    local admin_pass="$3"
    local export_dir="$4"
    local user_file="$5"
    local jobs="$6"

    if [ "$jobs" == "auto" ]; then
        jobs=$(get_optimal_jobs)
    fi

    mkdir -p "$export_dir/logs"

    log "Obtention du token d'authentification..."
    token=$(get_admin_token "$admin_user" "$admin_pass" "$zimbra_host")

    export EXPORT_DIR="$export_dir"
    export TOKEN="$token"
    export HOST="$zimbra_host"

    log "Début de l'export en parallèle ($jobs jobs)..."
    grep -v '^#\|^$' "$user_file" | sort | uniq | \
    xargs -P "$jobs" -I {} bash -c '
        user="$1"
        out="$EXPORT_DIR/$user.tgz"
        log_file="$EXPORT_DIR/logs/$user.log"
        if [ -s "$out" ]; then
            echo "$user" >> "$EXPORT_DIR/success_list.txt"
            exit 0
        fi
        curl --progress-bar --max-time 0 --connect-timeout 10 -k \
            -H "Authorization: ZnAdminAuthToken $TOKEN" \
            "https://$HOST:7071/home/$user/?fmt=tgz" -o "$out" >> "$log_file" 2>&1 && \
        echo "$user" >> "$EXPORT_DIR/success_list.txt" || \
        echo "$user" >> "$EXPORT_DIR/failed_list.txt"
    ' _ {}
}

#######################################
# IMPORT DES ARCHIVES TGZ
#######################################
do_import() {
    local export_dir="$1"
    local jobs="$2"
    local only_success="$3"

    if [ "$jobs" == "auto" ]; then
        jobs=$(get_optimal_jobs)
    fi

    local source_list=""
    if [ "$only_success" = "1" ] && [ -f "$export_dir/success_list.txt" ]; then
        source_list="$export_dir/success_list.txt"
    else
        source_list=$(find "$export_dir" -type f -name "*.tgz" | sed 's#.*/##' | sed 's/.tgz$//')
    fi

    export EXPORT_DIR="$export_dir"

    log "Début de l'import en parallèle ($jobs jobs)..."
    echo "$source_list" | tr ' ' '\n' | sort | uniq | \
    xargs -P "$jobs" -I {} bash -c '
        user="$1"
        archive="$EXPORT_DIR/$user.tgz"
        log_file="$EXPORT_DIR/logs/import_$user.log"
        if [ -s "$archive" ]; then
            su - zimbra -c "/opt/zimbra/bin/zmmailbox -z -m $user postRestURL \"/?fmt=tgz\" \"$archive\"" >> "$log_file" 2>&1 && \
            echo "$user" >> "$EXPORT_DIR/import_success.txt" && rm -f "$archive" || \
            echo "$user" >> "$EXPORT_DIR/import_failed.txt"
        fi
    ' _ {}
}

#######################################
# AFFICHER L'AIDE
#######################################
show_help() {
cat << EOF
Usage:
  $0 export -z IP -a ADMIN -p PASS -o EXPORT_DIR -u USERS [-j JOBS|auto]
  $0 import -o EXPORT_DIR [-j JOBS|auto] [--import-only-success]
  $0 fullsync -z IP -a ADMIN -p PASS -o EXPORT_DIR -u USERS [-j JOBS|auto]

Options:
  -z      Adresse IP ou FQDN du serveur Zimbra
  -a      Compte admin Zimbra
  -p      Mot de passe du compte admin
  -o      Dossier d'export/import (.tgz + logs)
  -u      Fichier liste des utilisateurs
  -j      Nombre de jobs parallèles (ou 'auto' → ajuste selon l'heure)
  --import-only-success  N'importe que les comptes exportés avec succès
  -h      Affiche cette aide

Exemples :
  ./zimbra_migration.sh export -z 192.168.1.10 -a admin@domain.com -p secret -o /data/export -u users.txt -j auto
  ./zimbra_migration.sh import -o /data/export --import-only-success -j 10
  ./zimbra_migration.sh fullsync -z 192.168.1.10 -a admin@domain.com -p secret -o /data/export -u users.txt -j 12
  nohup ./zimbra_migration.sh fullsync -z 192.168.1.10 -a admin@domain.com -p secret -o /data/export -u users.txt -j auto > /var/log/zimbra_migration.log 2>&1 &
EOF
}

#######################################
# POINT D'ENTREE
#######################################

MODE="$1"; shift || { show_help; exit 1; }

ZIMBRA_HOST=""
ADMIN_USER="admin@domain.com"
ADMIN_PASS=""
EXPORT_DIR="$DEFAULT_EXPORT_DIR"
USER_LIST="$DEFAULT_USER_LIST"
JOBS="$DEFAULT_JOBS"
ONLY_SUCCESS=0

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -z) ZIMBRA_HOST="$2"; shift 2;;
        -a) ADMIN_USER="$2"; shift 2;;
        -p) ADMIN_PASS="$2"; shift 2;;
        -o) EXPORT_DIR="$2"; shift 2;;
        -u) USER_LIST="$2"; shift 2;;
        -j) JOBS="$2"; shift 2;;
        --import-only-success) ONLY_SUCCESS=1; shift;;
        -h|--help) show_help; exit 0;;
        *) echo "Option inconnue: $1"; show_help; exit 1;;
    esac

done

[ ! -f "$USER_LIST" ] && { echo "Fichier utilisateur introuvable: $USER_LIST"; exit 1; }

acquire_lock

case "$MODE" in
    export)
        do_export "$ZIMBRA_HOST" "$ADMIN_USER" "$ADMIN_PASS" "$EXPORT_DIR" "$USER_LIST" "$JOBS"
        ;;
    import)
        do_import "$EXPORT_DIR" "$JOBS" "$ONLY_SUCCESS"
        ;;
    fullsync)
        do_fullsync "$ZIMBRA_HOST" "$ADMIN_USER" "$ADMIN_PASS" "$EXPORT_DIR" "$USER_LIST" "$JOBS"
        ;;
    *)
        echo "Mode invalide: $MODE"
        show_help
        exit 1
        ;;
esac
