#!/bin/bash
### Zimbra Unified Migration Script (Export, Import & FullSync)
# Version finale corrigée

set -euo pipefail
shopt -s failglob

trap 'kill -- -$$' EXIT

#######################################
# CONFIGURATION PAR DÉFAUT
#######################################
DEFAULT_EXPORT_DIR="/opt/zimbra/backups/remote"
DEFAULT_USER_LIST="/home/ubuntu/USERS_LIST.txt"
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
    [[ "$1" == *"✅"* ]] && level="SUCCESS"
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

validate_tgz() {
    tar tzf "$1" >/dev/null 2>&1
    return $?
}

atomic_append() {
    local file="$1" content="$2" lock="${file}.lock"
    ( 
        flock -x 200
        echo "$content" >> "$file"
    ) 200>"$lock"
}

get_admin_token() {
    local user="$1" pass="$2" host="$3"
    curl -s -k -X POST -H "Content-Type: application/soap+xml" \
      -d "<soap:Envelope xmlns:soap=\"http://www.w3.org/2003/05/soap-envelope\">
             <soap:Body><AuthRequest xmlns=\"urn:zimbraAdmin\">
               <name>$user</name><password>$pass</password>
             </AuthRequest></soap:Body>
           </soap:Envelope>" \
      "https://$host:7071/service/admin/soap/" \
    | grep -oP '<authToken>\K[^<]+' || echo ""
}

#######################################
# WORKER
#######################################
run_fullsync_worker() {
    local method="$1" user="$2" pass="$3"
    local out="$EXPORT_DIR/$user.tgz"
    local temp_out="${out}.tmp"
    local log_exp="$EXPORT_DIR/logs/$user.export.log"
    local log_imp="$EXPORT_DIR/logs/$user.import.log"

    # Créer les entrées de log
    {
        printf "═%.0s" {1..80}
        printf "\n[%s] Début traitement pour %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$user"
        printf "━%.0s" {1..80}
        printf "\n"
    } >> "$log_exp"
    
    cp "$log_exp" "$log_imp"

    # Vérifier si déjà importé
    if grep -qxF "$user" "$EXPORT_DIR/import_success.txt"; then
        log "[$user] ✅ Déjà importé. Ignoré."
        return 0
    fi

    # Contrôle espace disque avec timeout
    local attempts=0 max_attempts=20
    while :; do
        local free_bytes min_bytes
        free_bytes=$(df -P -B1 "$EXPORT_DIR" | awk 'NR==2 {print $4}')
        min_bytes=$((MIN_DISK_SPACE * 1073741824))  # 20GB en octets (1024^3)

        if (( free_bytes < min_bytes )); then
            ((attempts++))
            if (( attempts > max_attempts )); then
                log "[$user] ❌ Échec: Espace disque insuffisant après $max_attempts tentatives"
                return 1
            fi
            
            local free_gb=$((free_bytes / 1073741824))
            log "[$user] ⚠️ Espace insuffisant (${free_gb}G < ${MIN_DISK_SPACE}G). Pause 15 min..."
            sleep 900
        else
            break
        fi
    done

    # Export si nécessaire
    local need_export=true
    if [[ -f "$out" ]]; then
        if validate_tgz "$out"; then
            need_export=false
            log "[$user] 📦 Archive valide déjà présente ($(du -h "$out" | cut -f1))"
        else
            log "[$user] ⚠️ Archive corrompue. Nouvel export nécessaire."
            rm -f "$out"
        fi
    fi

    if $need_export; then
        log "[$user] ✅ Lancement de l'export."
        
        local wget_args=(
            --no-check-certificate
            --quiet
            --header="Connection: close"
            "https://$HOST:7071/home/$user/?fmt=tgz"
            -O "$temp_out"
        )
        
        if [[ "$method" == "token" ]]; then
            wget_args+=(--header="Authorization: ZnAdminAuthToken $TOKEN")
            log "[$user] 🔑 Utilisation token d'authentification"
        else
            wget_args+=(--http-user="$ADMIN_USER" --http-password="$pass")
            log "[$user] 🔑 Utilisation compte administrateur"
        fi

        if timeout 14400 wget "${wget_args[@]}"; then
            if mv "$temp_out" "$out" && validate_tgz "$out"; then
                atomic_append "$EXPORT_DIR/success_list.txt" "$user"
                log "[$user] ✅ Export réussi ($(du -h "$out" | cut -f1))"
                printf "[%s] ✅ Export réussi pour %s\n" \
                    "$(date '+%Y-%m-%d %H:%M:%S')" "$user" >> "$log_exp"
            else
                log "[$user] ❌ Échec validation archive exportée"
                atomic_append "$EXPORT_DIR/failed_list.txt" "$user"
                return 1
            fi
        else
            rm -f "$temp_out"
            atomic_append "$EXPORT_DIR/failed_list.txt" "$user"
            log "[$user] ❌ Échec export (wget error:$?)"
            return 1
        fi
    fi

    # Import
    if [[ -f "$out" ]] && validate_tgz "$out"; then
        log "[$user] ↑ Lancement import..."
        
        local import_cmd="/opt/zimbra/bin/zmmailbox -z -m '$user' postRestURL '/?fmt=tgz' '$out'"
        if sudo -u zimbra bash -c "$import_cmd" >> "$log_imp" 2>&1; then
            atomic_append "$EXPORT_DIR/import_success.txt" "$user"
            rm -f "$out"
            log "[$user] ✅ Import réussi"
        else
            atomic_append "$EXPORT_DIR/import_failed.txt" "$user"
            log "[$user] ❌ Échec import (code:$?)"
            log "[$user] ℹ️ Consulter le log: $log_imp"
            return 1
        fi
    else
        log "[$user] ❌ Impossible d'importer: archive manquante ou invalide"
        return 1
    fi

    # Mise à jour progression
    local done total
    done=$(wc -l < "$EXPORT_DIR/import_success.txt")
    total="$TOTAL_USERS"
    log "[$user] 📊 Progression: $done/$total ($((done * 100 / total))%)"
}

# EXTRÊMEMENT IMPORTANT : Exporter les fonctions
export -f run_fullsync_worker log validate_tgz atomic_append

#######################################
# LAUNCHER
#######################################

launch_sync() {
    local mode="$1" pass="$2"
    # Traitement des noms avec caractères spéciaux
    grep -v '^#\|^$' "$USER_LIST" | tr -d '\r' | sort | uniq \
    | xargs -P "$JOBS" -I {} bash -c \
        "run_fullsync_worker \"$mode\" \"{}\" \"$pass\"" _
}

#######################################
# MODE FULLSYNC (login/mdp)
#######################################
do_fullsync() {
    HOST="$1"; ADMIN_USER="$2"; local pass="$3"
    EXPORT_DIR="$4"; USER_LIST="$5"; JOBS="$6"
    TOTAL_USERS=$(grep -v '^#\|^$' "$USER_LIST" | sort | uniq | wc -l)
    export ADMIN_USER HOST JOBS EXPORT_DIR TOTAL_USERS
    launch_sync password "$pass"
}

#######################################
# MODE FULLSYNC_TOKEN (token SOAP)
#######################################
do_fullsync_token() {
    HOST="$1"; ADMIN_USER="$2"; local pass="$3"
    EXPORT_DIR="$4"; USER_LIST="$5"; JOBS="$6"
    TOTAL_USERS=$(grep -v '^#\|^$' "$USER_LIST" | sort | uniq | wc -l)
    
    log "⏳ Obtention token admin..."
    TOKEN=$(get_admin_token "$ADMIN_USER" "$pass" "$HOST")
    
    if [[ -z "$TOKEN" ]]; then
        log "❌ Échec de l'obtention du token"
        exit 1
    fi
    log "🔑 Token admin obtenu avec succès"

    export EXPORT_DIR HOST TOKEN TOTAL_USERS JOBS ADMIN_USER
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

Options:
  -z  Serveur Zimbra source (FQDN ou IP)
  -a  Compte admin Zimbra source
  -p  Mot de passe admin
  -o  Répertoire de travail (défaut: $DEFAULT_EXPORT_DIR)
  -u  Fichier liste utilisateurs (défaut: $DEFAULT_USER_LIST)
  -j  Nombre de jobs parallèles (défaut: $DEFAULT_JOBS)
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

    # Validation des paramètres
    [[ -z "$ZIMBRA_HOST" ]] && { echo "❌ HOST manquant"; show_help; exit 1; }
    [[ -z "$ADMIN_USER" ]] && { echo "❌ ADMIN manquant"; show_help; exit 1; }
    [[ -z "$ADMIN_PASS" ]] && { echo "❌ PASSWORD manquant"; show_help; exit 1; }
    [[ -f "$USER_LIST" ]] || { echo "❌ Fichier utilisateurs introuvable: $USER_LIST"; exit 1; }

    acquire_lock
    mkdir -p "$EXPORT_DIR/logs"
    touch "$EXPORT_DIR/global.log"
    for f in success_list.txt failed_list.txt import_success.txt import_failed.txt; do
        touch "$EXPORT_DIR/$f"
    done

    log "🚀 Début migration - Mode: $MODE"
    log "🔧 Configuration:"
    log "  - Serveur: $ZIMBRA_HOST"
    log "  - Admin: $ADMIN_USER"
    log "  - Répertoire: $EXPORT_DIR"
    log "  - Liste: $USER_LIST ($(wc -l < "$USER_LIST") utilisateurs)"
    log "  - Jobs: $JOBS"
    log "  - Espace min: ${MIN_DISK_SPACE}G"

    case "$MODE" in
        fullsync)       do_fullsync       "$ZIMBRA_HOST" "$ADMIN_USER" "$ADMIN_PASS" "$EXPORT_DIR" "$USER_LIST" "$JOBS";;
        fullsync_token) do_fullsync_token "$ZIMBRA_HOST" "$ADMIN_USER" "$ADMIN_PASS" "$EXPORT_DIR" "$USER_LIST" "$JOBS";;
        *) show_help; exit 1;;
    esac

    # Nettoyer l'environnement
    unset -f run_fullsync_worker log validate_tgz atomic_append
    
    # Nettoyage sécurité
    unset ADMIN_PASS
    log "✅ Traitement terminé avec succès"
}

main "$@"