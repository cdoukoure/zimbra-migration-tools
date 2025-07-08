#!/bin/bash
# Script optimisé pour l'import des boîtes mail Zimbra avec suivi des succès/échecs
# Version: 2.1
# Usage: nohup sudo ./zimbra_import_accounts_mailbox.sh > zimbra_import_accounts_mailbox.log 2>&1 &

### Configuration ###
ZIMBRA_FOLDER="/opt/zimbra"
ZIMBRA_BIN="${ZIMBRA_FOLDER}/bin"
ZMBOX="${ZIMBRA_BIN}/zmmailbox"
ZBACKUP="${ZIMBRA_FOLDER}/backups/zmmailbox-all"

### Paramètres ###
TIMEOUT=60                  # Timeout de vérification fichier (secondes)
SLEEP_INTERVAL=5            # Intervalle de vérification (secondes)
MAX_RETRIES=3               # Tentatives de restauration
RETRY_DELAY=10              # Délai entre tentatives (secondes)

### Initialisation des fichiers ###
init_log_files() {
    # Vérification des droits
    if [ "$(whoami)" != "root" ]; then
        echo "ERREUR: Ce script doit être exécuté en tant que root" >&2
        exit 1
    fi

    # Crée le répertoire s'il n'existe pas
    mkdir -p "$ZBACKUP" || {
        echo "ERREUR: Impossible de créer $ZBACKUP" >&2
        exit 1
    }

    # Fichier de log principal (toujours nouveau)
    LOG_FILE="${ZBACKUP}/zimbra_zmmailbox_bulk_restore_$(date +%Y%m%d_%H%M%S).log"
    touch "$LOG_FILE" || {
        echo "ERREUR: Impossible de créer $LOG_FILE" >&2
        exit 1
    }

    # Fichiers de suivi (ne pas écraser s'ils existent)
    declare -a track_files=("$SUCCESS_LOG" "$FAILED_LOG" "$PROCESSED_LOG")
    for file in "${track_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            touch "$file" || {
                echo "ERREUR: Impossible de créer $file" >> "$LOG_FILE"
                exit 1
            }
        fi
    done

    # Correction des permissions
    chown zimbra:zimbra "$LOG_FILE" "${track_files[@]}"
    chmod 640 "$LOG_FILE" "${track_files[@]}"
}

### Fonctions utilitaires ###
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

is_processed() {
    grep -qFx "$1" "$PROCESSED_LOG"
}

mark_processed() {
    if ! grep -qFx "$1" "$PROCESSED_LOG"; then
        echo "$1" >> "$PROCESSED_LOG"
    fi
}

### Fonctions principales ###
wait_for_stable_file() {
    local file="$1"
    local previous_size=0
    local start_time=$(date +%s)

    log "Vérification stabilité de: $(basename "$file")"
    
    while true; do
        current_size=$(stat -c%s "$file" 2>/dev/null || echo 0)
        
        if [[ "$current_size" -eq "$previous_size" ]]; then
            log "Fichier stable: $(basename "$file") (Taille: $current_size octets)"
            return 0
        fi

        if [[ $(($(date +%s) - start_time)) -ge "$TIMEOUT" ]]; then
            log "Timeout atteint pour: $(basename "$file")"
            return 1
        fi

        previous_size="$current_size"
        sleep "$SLEEP_INTERVAL"
    done
}

restore_mailbox() {
    local file="$1"
    local user=$(basename "$file" .tgz)
    local attempt=0
    local success=0

    while [[ $attempt -lt $MAX_RETRIES ]] && [[ $success -eq 0 ]]; do
        ((attempt++))
        log "Tentative $attempt/$MAX_RETRIES pour $user"

        if $ZMBOX -z -m "$user" postRestURL "//?fmt=tgz&resolve=skip" "$file" >> "$LOG_FILE" 2>&1; then
            log "Restauration réussie: $user"
            echo "$file" >> "$SUCCESS_LOG"
            success=1
        else
            log "Échec tentative $attempt pour $user"
            [[ $attempt -lt $MAX_RETRIES ]] && sleep "$RETRY_DELAY"
        fi
    done

    if [[ $success -eq 0 ]]; then
        echo "$file" >> "$FAILED_LOG"
        return 1
    fi
    return 0
}

### Point d'entrée ###
main() {

    # Initialisation sécurisée
    init_log_files

    log "=== Début du traitement ==="
    log "Contenu du répertoire $ZBACKUP :"
    ls -l "$ZBACKUP" >> "$LOG_FILE"

    # Traitement des fichiers
    local processed_count=0 failed_count=0 success_count=0

    for file in "$ZBACKUP"/*.tgz; do
        [[ -f "$file" ]] || continue

        local filename=$(basename "$file")
        log "Traitement de: $filename"

        if is_processed "$filename"; then
            log "Déjà traité: $filename"
            continue
        fi

        if wait_for_stable_file "$file"; then
            if restore_mailbox "$file"; then
                mark_processed "$filename"
                ((success_count++))
            else
                ((failed_count++))
            fi
            ((processed_count++))
        else
            log "Fichier instable: $filename"
            echo "$filename" >> "$FAILED_LOG"
            ((failed_count++))
        fi
    done

    log "=== Traitement terminé ==="
    log "Résumé:"
    log "- Fichiers traités: $processed_count"
    log "- Succès: $success_count"
    log "- Échecs: $failed_count"
    log "Consultez les logs:"
    log "- Log complet: $LOG_FILE"
    log "- Succès: $SUCCESS_LOG ($(wc -l < "$SUCCESS_LOG") total)"
    log "- Échecs: $FAILED_LOG ($(wc -l < "$FAILED_LOG") total)"
}

### Variables globales ###
LOG_FILE="${ZBACKUP}/zimbra_zmmailbox_bulk_restore_$(date +%Y%m%d_%H%M%S).log"
SUCCESS_LOG="${ZBACKUP}/zimbra_restore_success.log"
FAILED_LOG="${ZBACKUP}/zimbra_restore_failed.log"
PROCESSED_LOG="${ZBACKUP}/zimbra_restore_processed.log"

### Execution ###
main