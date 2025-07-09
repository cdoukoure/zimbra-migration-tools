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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$EXPORT_DIR/global.log"
}

acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE")
        if ! ps -p "$pid" >/dev/null 2>&1; then
            echo "Verrou orphelin détecté. Suppression du lock."
            rm -f "$LOCK_FILE"
        else
            log "Un autre processus est déjà en cours (PID $pid)."
            exit 1
        fi
    fi
    echo $$ >"$LOCK_FILE"
    trap release_lock EXIT INT TERM
}

release_lock() {
    rm -f "$LOCK_FILE"
}

get_optimal_jobs() {
    local cores=$(nproc)
    local hour=$(date +%H)
    if ((hour >= 0 && hour < 6)); then
        echo $((cores * 2))
    elif ((hour >= 6 && hour < 20)); then
        echo $((cores / 2))
    else
        echo $cores
    fi
}

#######################################
# AUTH TOKEN POUR VERSION TOKEN
#######################################
get_admin_token() {
    local admin_user="$1"
    local admin_pass="$2"
    local zimbra_host="$3"

    curl -s -k -X POST \
        -H "Content-Type: application/soap+xml" \
        -d "<soap:Envelope xmlns:soap=\"http://www.w3.org/2003/05/soap-envelope\"><soap:Body><AuthRequest xmlns=\"urn:zimbraAdmin\"><name>$admin_user</name><password>$admin_pass</password></AuthRequest></soap:Body></soap:Envelope>" \
        https://$zimbra_host:7071/service/admin/soap/ |
        grep -oP '<authToken>\K[^<]+'
}

#######################################
# FULLSYNC UTILISANT LOGIN/PASSWORD
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

    mkdir -p "$export_dir/logs"
    touch "$export_dir/global.log"
    log "Execution du mode FullSync avec $jobs jobs..."

    total=$(grep -v '^#\|^$' "$user_file" | tr -d '\r' | sort | uniq | wc -l)
    export EXPORT_DIR="$export_dir"
    export HOST="$zimbra_host"
    export ADMIN_USER="$admin_user"
    export ADMIN_PASS="$admin_pass"
    export TOTAL_USERS="$total"

    grep -v '^#\|^$' "$user_file" | tr -d '\r' | sort | uniq |
        xargs -P "$jobs" -I {} bash -c '
        user="$1"
        user=$(echo "$user" | tr -d "\r")
        out="$EXPORT_DIR/$user.tgz"
        log_exp="$EXPORT_DIR/logs/$user.export.log"
        log_imp="$EXPORT_DIR/logs/$user.import.log"

        if grep -qx "$user" "$EXPORT_DIR/success_list.txt"; then
            log "[$user] Déjà exporté. Ignoré."
            exit 0
        fi

        mount_point=$(df --output=target "$EXPORT_DIR" | tail -n 1)

        while true; do
            free_gb=$(df -BG "$mount_point" | awk "NR==2 {gsub(\"G\", \"\", \$4); print \$4}")
            if [ "$free_gb" -ge 20 ]; then break; fi
            log "[$user] Espace disque insuffisant ($free_gb Go). Attente 15min..."
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$user] Espace disque insuffisant ($free_gb Go)." >> "$log_exp"
            sleep 900
        done

        log "[$user] EXPORT en cours..."
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Export $user" >> "$log_exp"
        if [ ! -s "$out" ]; then
            if wget --no-check-certificate \
                --http-user="$ADMIN_USER" --http-password="$ADMIN_PASS" \
                "https://$HOST:7071/home/$user/?fmt=tgz" \
                -O "$out" >> "$log_exp" 2>&1; then
                echo "$user" >> "$EXPORT_DIR/success_list.txt"
            else
                echo "$user" >> "$EXPORT_DIR/failed_list.txt"
                last_error=$(tail -n 5 "$log_exp" | tr '\n' ' ')
                log "[$user] ❌ Échec de l'EXPORT. Dernière erreur : $last_error"
                exit 1
            fi
        fi

        if grep -qx "$user" "$EXPORT_DIR/import_success.txt"; then
            log "[$user] Déjà importé. Ignoré."
            exit 0
        fi

        log "[$user] IMPORT en cours..."
        if [ -s "$out" ]; then
            if su - zimbra -c "/opt/zimbra/bin/zmmailbox -z -m $user postRestURL \"/?fmt=tgz\" \"$out\"" >> "$log_imp" 2>&1; then
                echo "$user" >> "$EXPORT_DIR/import_success.txt"
                rm -f "$out"
            else
                echo "$user" >> "$EXPORT_DIR/import_failed.txt"
                last_error=$(tail -n 5 "$log_imp" | tr '\n' ' ')
                log "[$user] ❌ Échec de l'IMPORT. Dernière erreur : $last_error"
            fi
        else
            log "[$user] ⚠️ Archive vide, import ignoré"
        fi

        count=$(wc -l < "$EXPORT_DIR/success_list.txt")
        log "[$user] Terminé ($count/$TOTAL_USERS traités, $(awk "BEGIN {printf \"%.2f\", ($count/$TOTAL_USERS)*100}")%)"
    ' _ {}
}

#######################################
# FULLSYNC UTILISANT TOKEN
#######################################
do_fullsync_token() {
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
    touch "$export_dir/global.log"
    log "🔐 Obtention du token d'authentification..."
    token=$(get_admin_token "$admin_user" "$admin_pass" "$zimbra_host")
    log "🔐 Token d'authentification obtenu."

    log "🚀 Lancement du mode FullSync (auth token) avec $jobs jobs..."

    total=$(grep -v '^#\|^$' "$user_file" | tr -d '\r' | sort | uniq | wc -l)
    export EXPORT_DIR="$export_dir"
    export HOST="$zimbra_host"
    export TOKEN="$token"
    export TOTAL_USERS="$total"

    grep -v '^#\|^$' "$user_file" | tr -d '\r' | sort | uniq | \
    xargs -P "$jobs" -I {} bash -c '
        user="$1"
        user=$(echo "$user" | tr -d "\r")
        out="$EXPORT_DIR/$user.tgz"
        log_exp="$EXPORT_DIR/logs/$user.export.log"
        log_imp="$EXPORT_DIR/logs/$user.import.log"

        # Si déjà importé, ignorer
        if grep -qx "$user" "$EXPORT_DIR/import_success.txt"; then
            log "[$user] ✅ Déjà importé. Ignoré."
            exit 0
        fi

        # Vérifie si l’archive .tgz est présente et valide
        if [ -s "$out" ]; then
            log "[$user] 📦 Archive déjà exportée."
        else
            # Vérifie espace disque
            mount_point=$(df --output=target "$EXPORT_DIR" | tail -n 1)
            while true; do
                free_gb=$(df -BG "$mount_point" | awk "NR==2 {gsub(\"G\", \"\", \$4); print \$4}")
                if [ "$free_gb" -ge 20 ]; then break; fi
                log "[$user] ⛔ Espace disque insuffisant ($free_gb Go). Pause 15 min..."
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$user] Espace disque insuffisant ($free_gb Go)." >> "$log_exp"
                sleep 900
            done

            # Lance export
            log "[$user] 🔄 Export en cours..."
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Export $user" >> "$log_exp"
            if wget --no-check-certificate \
                --header="Authorization: ZnAdminAuthToken $TOKEN" \
                "https://$HOST:7071/home/$user/?fmt=tgz" \
                -O "$out" >> "$log_exp" 2>&1; then
                echo "$user" >> "$EXPORT_DIR/success_list.txt"
                log "[$user] ✅ Export réussi."
            else
                echo "$user" >> "$EXPORT_DIR/failed_list.txt"
                last_error=$(tail -n 5 "$log_exp" | tr "\n" " ")
                log "[$user] ❌ Échec de l’export. Erreur : $last_error"
                exit 1
            fi
        fi

        # Lance import
        log "[$user] ⬇️ Import en cours..."
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Import $user" >> "$log_imp"
        if [ -s "$out" ]; then
            if su - zimbra -c "/opt/zimbra/bin/zmmailbox -z -m $user postRestURL \"/?fmt=tgz\" \"$out\"" >> "$log_imp" 2>&1; then
                echo "$user" >> "$EXPORT_DIR/import_success.txt"
                rm -f "$out"
                log "[$user] ✅ Import réussi."
            else
                echo "$user" >> "$EXPORT_DIR/import_failed.txt"
                last_error=$(tail -n 5 "$log_imp" | tr "\n" " ")
                log "[$user] ❌ Échec de l’import. Erreur : $last_error"
            fi
        else
            log "[$user] ⚠️ Fichier d’archive vide. Suppression et import annulé."
            rm -f "$out"
        fi

        count=$(wc -l < "$EXPORT_DIR/import_success.txt")
        log "[$user] 🧮 Avancement : $count/$TOTAL_USERS (≈$(awk "BEGIN {printf \"%.1f\", ($count/$TOTAL_USERS)*100}")%)"
    ' _ {}
}


#######################################
# AIDE
#######################################
show_help() {
    cat <<EOF
Usage:
  $0 export   -z IP -a ADMIN -p PASS -o EXPORT_DIR -u USERS [-j JOBS|auto]
  $0 import   -o EXPORT_DIR [-j JOBS|auto] [--import-only-success]
  $0 fullsync -z IP -a ADMIN -p PASS -o EXPORT_DIR -u USERS [-j JOBS|auto]

Options:
  -z      Adresse IP ou FQDN du serveur Zimbra
  -a      Compte admin Zimbra
  -p      Mot de passe du compte admin
  -o      Dossier d'export/import (.tgz + logs)
  -u      Fichier liste des utilisateurs
  -j      Nombre de jobs parallèles (ou 'auto' → ajuste selon heure)
  --import-only-success  N'importe que les comptes exportés avec succès
  -h      Affiche cette aide

Exemples :
  ./zimbra_unified_migration.sh export   -z 192.168.1.10 -a admin@domain.com -p pass -o /data -u users.txt -j auto
  ./zimbra_unified_migration.sh import   -o /data --import-only-success -j 10
  ./zimbra_unified_migration.sh fullsync -z 192.168.1.10 -a admin@domain.com -p pass -o /data -u users.txt -j auto
  ./zimbra_unified_migration.sh fullsync_token -z 192.168.1.10 -a admin@domain.com -p pass -o /data -u users.txt -j auto
  nohup ./zimbra_unified_migration.sh fullsync -z 192.168.1.10 -a admin@domain.com -p pass -j auto -u users.txt > zimbra_unified_migration.log 2>&1 &
EOF
}

#######################################
# POINT D'ENTRÉE
#######################################
MODE="${1:-}"
shift || true

ZIMBRA_HOST=""
ADMIN_USER="admin@domain.com"
ADMIN_PASS=""
EXPORT_DIR="$DEFAULT_EXPORT_DIR"
USER_LIST="$DEFAULT_USER_LIST"
JOBS="$DEFAULT_JOBS"
ONLY_SUCCESS=0

while [[ "$#" -gt 0 ]]; do
    case "$1" in
    -z)
        ZIMBRA_HOST="$2"
        shift 2
        ;;
    -a)
        ADMIN_USER="$2"
        shift 2
        ;;
    -p)
        ADMIN_PASS="$2"
        shift 2
        ;;
    -o)
        EXPORT_DIR="$2"
        shift 2
        ;;
    -u)
        USER_LIST="$2"
        shift 2
        ;;
    -j)
        JOBS="$2"
        shift 2
        ;;
    --import-only-success)
        ONLY_SUCCESS=1
        shift
        ;;
    -h | --help)
        show_help
        exit 0
        ;;
    *)
        echo "Option inconnue: $1"
        show_help
        exit 1
        ;;
    esac
done

acquire_lock

case "$MODE" in
export) do_export "$ZIMBRA_HOST" "$ADMIN_USER" "$ADMIN_PASS" "$EXPORT_DIR" "$USER_LIST" "$JOBS" ;;
import) do_import "$EXPORT_DIR" "$JOBS" "$ONLY_SUCCESS" ;;
fullsync) do_fullsync "$ZIMBRA_HOST" "$ADMIN_USER" "$ADMIN_PASS" "$EXPORT_DIR" "$USER_LIST" "$JOBS" ;;
fullsync_token) do_fullsync_token "$ZIMBRA_HOST" "$ADMIN_USER" "$ADMIN_PASS" "$EXPORT_DIR" "$USER_LIST" "$JOBS" ;;
*)
    show_help
    exit 1
    ;;
esac





#!/bin/bash

### Zimbra Unified Migration Script (Export, Import & FullSync)
# Version améliorée avec corrections de résilience

set -euo pipefail
shopt -s failglob

#######################################
# CONFIGURATION PAR DEFAUT
#######################################
DEFAULT_EXPORT_DIR="/opt/zimbra/backups/remote"
DEFAULT_USER_LIST="/home/ubuntu/users.txt"
DEFAULT_JOBS=10
LOCK_FILE="/tmp/zimbra_migration.lock"
MIN_DISK_SPACE=20 # en Go

#######################################
# FONCTIONS UTILITAIRES
#######################################
log() {
    local level="INFO"
    local message="$1"
    [[ "$message" == *"❌"* ]] && level="ERROR"
    [[ "$message" == *"⚠️"* ]] && level="WARNING"
    printf "[%s] [%s] [PID:%d] %s\n" \
           "$(date '+%Y-%m-%d %H:%M:%S')" \
           "$level" \
           "$$" \
           "$message" | tee -a "$EXPORT_DIR/global.log"
}

acquire_lock() {
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        local pid=$(cat "$LOCK_FILE")
        if ps -p "$pid" >/dev/null 2>&1; then
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
    local cores=$(nproc)
    local hour=$(date +%H)
    if ((hour >= 0 && hour < 6)); then
        echo $((cores * 2))
    elif ((hour >= 6 && hour < 20)); then
        echo $((cores / 2))
    else
        echo $cores
    fi
}

validate_tgz() {
    local file="$1"
    tar tzf "$file" >/dev/null 2>&1
    return $?
}

atomic_append() {
    local file="$1"
    local content="$2"
    local lock="${file}.lock"
    
    (
        flock -x 200
        echo "$content" >> "$file"
    ) 200>"$lock"
}

#######################################
# FULLSYNC UTILISANT LOGIN/PASSWORD
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

    mkdir -p "$export_dir/logs" || { log "❌ Impossible de créer $export_dir/logs"; return 1; }
    touch "$export_dir/global.log" || { log "❌ Impossible de créer global.log"; return 1; }
    log "🚀 Lancement du mode FullSync avec $jobs jobs..."

    total=$(grep -v '^#\|^$' "$user_file" | tr -d '\r' | sort | uniq | wc -l)
    export EXPORT_DIR="$export_dir"
    export HOST="$zimbra_host"
    export ADMIN_USER="$admin_user"
    export TOTAL_USERS="$total"
    
    # Création des fichiers de suivi
    for file in success_list.txt failed_list.txt import_success.txt import_failed.txt; do
        touch "$export_dir/$file" || { log "❌ Impossible de créer $file"; return 1; }
    done

    grep -v '^#\|^$' "$user_file" | tr -d '\r' | sort | uniq |
        xargs -P "$jobs" -I {} bash -c '
        user="$1"
        user=$(echo "$user" | tr -d "\r")
        out="$EXPORT_DIR/$user.tgz"
        temp_out="${out}.tmp"
        log_exp="$EXPORT_DIR/logs/$user.export.log"
        log_imp="$EXPORT_DIR/logs/$user.import.log"
        
        # Initialisation des logs
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Début traitement pour $user" > "$log_exp"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Début traitement pour $user" > "$log_imp"

        # Vérification si déjà importé
        if grep -qxF "$user" "$EXPORT_DIR/import_success.txt"; then
            log "[$user] ✅ Déjà importé. Ignoré."
            exit 0
        fi

        # Vérification espace disque
        mount_point=$(df --output=target "$EXPORT_DIR" | tail -n 1)
        while true; do
            free_gb=$(df -BG "$mount_point" | awk "NR==2 {gsub(\"G\", \"\", \$4); print \$4}")
            if [ "$free_gb" -ge 20 ]; then break; fi
            log "[$user] ⛔ Espace disque insuffisant ($free_gb Go). Attente 15 min..."
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$user] Espace disque insuffisant ($free_gb Go)." >> "$log_exp"
            sleep 900
        done

        # EXPORT
        log "[$user] 🔄 Export en cours..."
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Export $user" >> "$log_exp"
        
        if [ -s "$out" ] && validate_tgz "$out"; then
            log "[$user] 📦 Archive valide déjà présente."
        else
            rm -f "$out" "$temp_out"
            
            # Téléchargement avec timeout et fichier temporaire
            if timeout 3600 wget --no-check-certificate \
                --http-user="$ADMIN_USER" --http-password="$4" \
                "https://$HOST:7071/home/$user/?fmt=tgz" \
                -O "$temp_out" >> "$log_exp" 2>&1 && \
                mv "$temp_out" "$out" && \
                validate_tgz "$out"; then
                
                atomic_append "$EXPORT_DIR/success_list.txt" "$user"
                log "[$user] ✅ Export réussi."
            else
                rm -f "$temp_out"
                atomic_append "$EXPORT_DIR/failed_list.txt" "$user"
                last_error=$(tail -n 5 "$log_exp" | tr '\n' ' ' | head -c 200)
                log "[$user] ❌ Échec export. Erreur: ${last_error:-unknown}"
                exit 1
            fi
        fi

        # IMPORT
        log "[$user] ⬇️ Import en cours..."
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Import $user" >> "$log_imp"
        
        if [ -s "$out" ] && validate_tgz "$out"; then
            # Double vérification de l'utilisateur
            if grep -qxF "$user" "$EXPORT_DIR/import_success.txt"; then
                log "[$user] ✅ Déjà importé (vérification finale)."
                exit 0
            fi

            if timeout 3600 su - zimbra -c "/opt/zimbra/bin/zmmailbox -z -m $user postRestURL \"/?fmt=tgz\" \"$out\"" >> "$log_imp" 2>&1; then
                atomic_append "$EXPORT_DIR/import_success.txt" "$user"
                rm -f "$out"
                log "[$user] ✅ Import réussi."
            else
                atomic_append "$EXPORT_DIR/import_failed.txt" "$user"
                last_error=$(tail -n 5 "$log_imp" | tr '\n' ' ' | head -c 200)
                log "[$user] ❌ Échec import. Erreur: ${last_error:-unknown}"
            fi
        else
            log "[$user] ⚠️ Archive invalide ou vide. Import annulé."
            rm -f "$out"
            atomic_append "$EXPORT_DIR/import_failed.txt" "$user"
        fi

        # Calcul progression
        count=$(wc -l < "$EXPORT_DIR/import_success.txt")
        percentage=$(awk "BEGIN {printf \"%.1f\", ($count/$TOTAL_USERS)*100}")
        log "[$user] 📊 Progression: $count/$TOTAL_USERS ($percentage%)"
    ' _ {} "$admin_pass"  # Passage du mot de passe comme argument
    
    unset ADMIN_USER
}

#######################################
# FULLSYNC UTILISANT TOKEN
#######################################
do_fullsync_token() {
    local zimbra_host="$1"
    local admin_user="$2"
    local admin_pass="$3"
    local export_dir="$4"
    local user_file="$5"
    local jobs="$6"

    if [ "$jobs" == "auto" ]; then
        jobs=$(get_optimal_jobs)
    fi

    mkdir -p "$export_dir/logs" || { log "❌ Impossible de créer $export_dir/logs"; return 1; }
    touch "$export_dir/global.log" || { log "❌ Impossible de créer global.log"; return 1; }
    log "🔐 Obtention du token d'authentification..."
    
    token=$(get_admin_token "$admin_user" "$admin_pass" "$zimbra_host")
    if [ -z "$token" ]; then
        log "❌ Échec d'obtention du token"
        return 1
    fi
    
    log "🔐 Token obtenu avec succès."
    log "🚀 Lancement du mode FullSync (token) avec $jobs jobs..."

    total=$(grep -v '^#\|^$' "$user_file" | tr -d '\r' | sort | uniq | wc -l)
    export EXPORT_DIR="$export_dir"
    export HOST="$zimbra_host"
    export TOKEN="$token"
    export TOTAL_USERS="$total"
    
    # Création des fichiers de suivi
    for file in success_list.txt failed_list.txt import_success.txt import_failed.txt; do
        touch "$export_dir/$file" || { log "❌ Impossible de créer $file"; return 1; }
    done

    grep -v '^#\|^$' "$user_file" | tr -d '\r' | sort | uniq | \
    xargs -P "$jobs" -I {} bash -c '
        user="$1"
        user=$(echo "$user" | tr -d "\r")
        out="$EXPORT_DIR/$user.tgz"
        temp_out="${out}.tmp"
        log_exp="$EXPORT_DIR/logs/$user.export.log"
        log_imp="$EXPORT_DIR/logs/$user.import.log"
        
        # Initialisation des logs
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Début traitement pour $user" > "$log_exp"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Début traitement pour $user" > "$log_imp"

        # Vérification si déjà importé
        if grep -qxF "$user" "$EXPORT_DIR/import_success.txt"; then
            log "[$user] ✅ Déjà importé. Ignoré."
            exit 0
        fi

        # Vérification espace disque
        mount_point=$(df --output=target "$EXPORT_DIR" | tail -n 1)
        while true; do
            free_gb=$(df -BG "$mount_point" | awk "NR==2 {gsub(\"G\", \"\", \$4); print \$4}")
            if [ "$free_gb" -ge 20 ]; then break; fi
            log "[$user] ⛔ Espace disque insuffisant ($free_gb Go). Pause 15 min..."
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$user] Espace disque insuffisant ($free_gb Go)." >> "$log_exp"
            sleep 900
        done

        # EXPORT
        log "[$user] 🔄 Export en cours..."
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Export $user" >> "$log_exp"
        
        if [ -s "$out" ] && validate_tgz "$out"; then
            log "[$user] 📦 Archive valide déjà présente."
        else
            rm -f "$out" "$temp_out"
            
            # Téléchargement avec timeout et fichier temporaire
            if wget --no-check-certificate \
                --header="Authorization: ZnAdminAuthToken $TOKEN" \
                "https://$HOST:7071/home/$user/?fmt=tgz" \
                -O "$temp_out" >> "$log_exp" 2>&1 && \
                mv "$temp_out" "$out" && \
                validate_tgz "$out"; then
                
                atomic_append "$EXPORT_DIR/success_list.txt" "$user"
                log "[$user] ✅ Export réussi."
            else
                rm -f "$temp_out"
                atomic_append "$EXPORT_DIR/failed_list.txt" "$user"
                last_error=$(tail -n 5 "$log_exp" | tr "\n" " " | head -c 200)
                log "[$user] ❌ Échec export. Erreur: ${last_error:-unknown}"
                exit 1
            fi
        fi

        # IMPORT
        log "[$user] ⬇️ Import en cours..."
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Import $user" >> "$log_imp"
        
        if [ -s "$out" ] && validate_tgz "$out"; then
            # Double vérification de l'utilisateur
            if grep -qxF "$user" "$EXPORT_DIR/import_success.txt"; then
                log "[$user] ✅ Déjà importé (vérification finale)."
                exit 0
            fi

            if su - zimbra -c "/opt/zimbra/bin/zmmailbox -z -m $user postRestURL \"/?fmt=tgz\" \"$out\"" >> "$log_imp" 2>&1; then
                atomic_append "$EXPORT_DIR/import_success.txt" "$user"
                rm -f "$out"
                log "[$user] ✅ Import réussi."
            else
                atomic_append "$EXPORT_DIR/import_failed.txt" "$user"
                last_error=$(tail -n 5 "$log_imp" | tr "\n" " " | head -c 200)
                log "[$user] ❌ Échec import. Erreur: ${last_error:-unknown}"
            fi
        else
            log "[$user] ⚠️ Archive invalide ou vide. Import annulé."
            rm -f "$out"
            atomic_append "$EXPORT_DIR/import_failed.txt" "$user"
        fi

        # Calcul progression
        count=$(wc -l < "$EXPORT_DIR/import_success.txt")
        percentage=$(awk "BEGIN {printf \"%.1f\", ($count/$TOTAL_USERS)*100}")
        log "[$user] 📊 Progression: $count/$TOTAL_USERS ($percentage%)"
    ' _ {}
    
    unset TOKEN
}

#######################################
# VALIDATION DES PARAMÈTRES
#######################################
validate_params() {
    # Vérification des dépendances
    for cmd in wget curl su grep sort uniq tar flock; do
        if ! command -v "$cmd" >/dev/null; then
            log "❌ Commande $cmd manquante"
            exit 1
        fi
    done

    case "$MODE" in
        export|fullsync|fullsync_token)
            [ -z "$ZIMBRA_HOST" ] && { log "Erreur: -z obligatoire"; exit 1; }
            [ -z "$ADMIN_PASS" ] && { log "Erreur: -p obligatoire"; exit 1; }
            ;;
    esac
    
    [ ! -f "$USER_LIST" ] && { log "Erreur: Fichier utilisateur introuvable"; exit 1; }
    mkdir -p "$EXPORT_DIR/logs" || { log "❌ Impossible de créer $EXPORT_DIR/logs"; exit 1; }
}

#######################################
# POINT D'ENTRÉE AMÉLIORÉ
#######################################
main() {
    MODE="${1:-}"
    shift || true

    [ -z "$MODE" ] && { show_help; exit 1; }

    # Initialisation des variables
    ZIMBRA_HOST=""
    ADMIN_USER="admin@domain.com"
    ADMIN_PASS=""
    EXPORT_DIR="$DEFAULT_EXPORT_DIR"
    USER_LIST="$DEFAULT_USER_LIST"
    JOBS="$DEFAULT_JOBS"
    ONLY_SUCCESS=0

    # Parse arguments
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
        -z) ZIMBRA_HOST="$2"; shift 2 ;;
        -a) ADMIN_USER="$2"; shift 2 ;;
        -p) ADMIN_PASS="$2"; shift 2 ;;
        -o) EXPORT_DIR="$2"; shift 2 ;;
        -u) USER_LIST="$2"; shift 2 ;;
        -j) JOBS="$2"; shift 2 ;;
        --import-only-success) ONLY_SUCCESS=1; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) log "Option inconnue: $1"; show_help; exit 1 ;;
        esac
    done

    acquire_lock
    validate_params
    rotate_logs

    case "$MODE" in
        export) do_export "$ZIMBRA_HOST" "$ADMIN_USER" "$ADMIN_PASS" "$EXPORT_DIR" "$USER_LIST" "$JOBS" ;;
        import) do_import "$EXPORT_DIR" "$JOBS" "$ONLY_SUCCESS" ;;
        fullsync) do_fullsync "$ZIMBRA_HOST" "$ADMIN_USER" "$ADMIN_PASS" "$EXPORT_DIR" "$USER_LIST" "$JOBS" ;;
        fullsync_token) do_fullsync_token "$ZIMBRA_HOST" "$ADMIN_USER" "$ADMIN_PASS" "$EXPORT_DIR" "$USER_LIST" "$JOBS" ;;
        *) show_help; exit 1 ;;
    esac
}

main "$@"
