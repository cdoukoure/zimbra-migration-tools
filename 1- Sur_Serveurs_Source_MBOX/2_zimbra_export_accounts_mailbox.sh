#!/bin/bash
# Script d'export massif des boîtes mail Zimbra avec suivi des succès/échecs
# Version: 2.1
# Auteur: Jean Charles DOUKOURE <charles.doukoure@aldizexperttech.com>
# Améliorations: 
# - Gestion paramétrable des dates de début/fin
# - Validation des formats de date
# - Valeurs par défaut J-15/demain
# Usage: 
# chmod +x ./zimbra_export_accounts_mailbox.sh
# sudo su -
## Afficher l'aide
# sudo ./zimbra_export_accounts_mailbox.sh -h
## Definir la periode des mails
# sudo ./zimbra_export_accounts_mailbox.sh -s 01/04/2025 -e 15/04/2025
# nohup ./zimbra_export_accounts_mailbox.sh > zimbra_export_accounts_mailbox_$(date +%Y%m%d_%H%M%S).log 2>&1 &

# /opt/zimbra/backups/zmmailbox-all/export_20250405_202628.log


### Configuration ###
ZIMBRA_FOLDER="/opt/zimbra"
ZIMBRA_BIN="${ZIMBRA_FOLDER}/bin"
ZMBOX="${ZIMBRA_BIN}/zmmailbox"

# Paramètres d'export
FORMAT="tgz"
MAX_RETRIES=3
WAIT_TIME=60
TIMEOUT=900

# Valeurs par défaut pour la fin
END_DEFAULT=$(date -d "tomorrow" +"%d/%m/%Y")      # Demain par défaut

# Chemins des fichiers
# ZBACKUP="${ZIMBRA_FOLDER}/backups/zmmailbox-all"
EXPORT_USER_FOLDER="${ZIMBRA_FOLDER}/backups/accounts-data"
#USERS_LIST="${EXPORT_USER_FOLDER}/email.txt"
LOCK_FILE="/tmp/zimbra_export.lock"
SUCCESS_LIST="${ZBACKUP}/success_list_$(date +%Y%m%d_%H%M%S).txt"
FAILED_LIST="${ZBACKUP}/failed_list_$(date +%Y%m%d_%H%M%S).txt"
LOG_FILE="${ZBACKUP}/export_$(date +%Y%m%d_%H%M%S).log"

ZBACKUP="${ZIMBRA_FOLDER}/backups/zmmailbox"
USERS_LIST="/home/ubuntu/users.txt"

### Fonction d'aide ###
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -s DATE  Date de début au format JJ/MM/AAAA (optionnel, export depuis le début si non spécifié)"
    echo "  -e DATE  Date de fin au format JJ/MM/AAAA (défaut: $END_DEFAULT)"
    echo "  -f       Forcer l'exécution (supprime le lock file)"
    echo "  -h       Affiche cette aide"
    echo ""
    echo "Exemples:"
    echo "  $0 -e 15/04/2025"
    echo "  $0 -s 01/04/2025 -e 15/04/2025"
    echo "  $0 -f  # Force l'exécution avec les dates par défaut"
    exit 0
}

### Traitement des arguments ###
while getopts ":s:e:fh" opt; do
    case $opt in
        s) START="$OPTARG" ;;
        e) END="$OPTARG" ;;
        f) FORCE=1 ;;
        h) usage ;;
        \?) echo "Option invalide: -$OPTARG" >&2; usage ;;
        :) echo "L'option -$OPTARG nécessite un argument." >&2; usage ;;
    esac
done

# Appliquer les valeurs par défaut si non spécifiées
START="${START:-}"
END="${END:-$END_DEFAULT}"

### Validation des dates ###
validate_date() {
    local date_input="$1"
    if ! [[ "$date_input" =~ ^[0-9]{2}/[0-9]{2}/[0-9]{4}$ ]]; then
        echo "ERREUR: Format de date invalide pour '$date_input'. Utilisez JJ/MM/AAAA"
        exit 1
    fi
    
    # Vérification que la date existe (basique)
    local day=${date_input:0:2}
    local month=${date_input:3:2}
    local year=${date_input:6:4}
    
    if ! date -d "${year}-${month}-${day}" >/dev/null 2>&1; then
        echo "ERREUR: Date '$date_input' invalide ou inexistante"
        exit 1
    fi
}

# Valider uniquement si date spécifiée
[ -n "$START" ] && validate_date "$START"
validate_date "$END"

### Initialisation ###
init_environment() {
    # Vérification des droits
    if [ "$(whoami)" != "root" ]; then
        echo "ERREUR: Ce script doit être exécuté en tant que root" >&2
        exit 1
    fi

    # Création des répertoires
    mkdir -p "$ZBACKUP" "$EXPORT_USER_FOLDER" || {
        echo "ERREUR: Impossible de créer les répertoires de backup" >&2
        exit 1
    }
    chown zimbra:zimbra "$ZBACKUP" "$EXPORT_USER_FOLDER"

    # Vérification du fichier users
    if [ ! -f "$USERS_LIST" ]; then
        echo "ERREUR: Fichier $USERS_LIST manquant" >&2
        exit 1
    fi

    # Initialisation des fichiers de suivi
    touch "$SUCCESS_LIST" "$FAILED_LIST"
    chown zimbra:zimbra "$SUCCESS_LIST" "$FAILED_LIST"
    
    # Initialisation du fichier de log
    
    touch "$LOG_FILE" && chown zimbra:zimbra "$LOG_FILE" || {
        echo "ERREUR: Impossible de créer le fichier de log" >&2
        exit 1
    }
}

### Fonctions Utilitaires ###
log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message" | tee -a "$LOG_FILE"
}

acquire_lock() {
    local max_attempts=3
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if [ -f "$LOCK_FILE" ]; then
            local pid=$(cat "$LOCK_FILE" 2>/dev/null)
            if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
                log "ERREUR: Script déjà en cours (PID $pid)"
                return 1
            else
                log "Nettoyage du lock orphelin (PID $pid)"
                rm -f "$LOCK_FILE"
            fi
        fi
        
        if (set -o noclobber; echo $$ > "$LOCK_FILE") 2>/dev/null; then
            trap 'release_lock' EXIT INT TERM
            log "Verrou acquis (PID $$)"
            return 0
        fi
        
        ((attempt++))
        sleep 10
    done
    
    log "ERREUR: Impossible d'acquérir le verrou après $max_attempts tentatives"
    return 1
}

release_lock() {
    if [ -f "$LOCK_FILE" ] && [ $$ -eq $(cat "$LOCK_FILE" 2>/dev/null) ]; then
        rm -f "$LOCK_FILE"
        log "Verrou libéré (PID $$)"
    fi
}

check_prerequisites() {
    [ -x "$ZMBOX" ] || { log "ERREUR: $ZMBOX introuvable ou non exécutable"; exit 1; }
    command -v date >/dev/null || { log "ERREUR: Commande 'date' manquante"; exit 1; }
    
    # Vérification espace disque (minimum 10GB)
    local min_space=10
    local available=$(df -BG "$ZBACKUP" | awk 'NR==2 {print $4}' | tr -d 'G')
    [ "$available" -ge "$min_space" ] || { log "ERREUR: Espace disque insuffisant"; exit 1; }
}

rotate_logs() {
    find "$ZBACKUP" -name "export_*.log" -mtime +30 -exec gzip {} \;
    find "$ZBACKUP" -name "export_*.log.gz" -mtime +180 -delete
}

### Fonctions Métier ###
date_to_timestamp_ms() {
    local date_input="$1"
    [ -z "$date_input" ] && echo "" && return 0

    if ! [[ "$date_input" =~ ^[0-9]{2}/[0-9]{2}/[0-9]{4}$ ]]; then
        echo "ERREUR: Format de date invalide pour '$date_input'. Utilisez JJ/MM/AAAA"
        exit 1
    fi
    
    local day=${date_input:0:2}
    local month=${date_input:3:2}
    local year=${date_input:6:4}
    local timestamp_s

    if ! timestamp_s=$(date -d "${year}-${month}-${day} 00:00:00 UTC" +%s 2>/dev/null); then
        echo "ERREUR: Date '$date_input' invalide ou inexistante"
        exit 1
    fi

    echo $((timestamp_s * 1000))
}

is_processed() {
    local user="$1"
    grep -q "^${user}$" "$SUCCESS_LIST" && return 0
    grep -q "^${user}$" "$FAILED_LIST" && return 0
    return 1
}

mark_success() {
    local user="$1"
    if ! grep -q "^${user}$" "$SUCCESS_LIST"; then
        echo "$user" >> "$SUCCESS_LIST"
    fi
    sed -i "/^${user}$/d" "$FAILED_LIST"
}

mark_failed() {
    local user="$1"
    if ! grep -q "^${user}$" "$FAILED_LIST"; then
        echo "$user" >> "$FAILED_LIST"
    fi
}

export_mailbox() {
    local user="$1"
    local output_file="${ZBACKUP}/${user}.${FORMAT}"
    local attempt=0
    local success=0
    local params="?fmt=${FORMAT}"
    
    [ -n "$2" ] && params+="&start=$2"
    [ -n "$3" ] && params+="&end=$3"

    if [ -f "$output_file" ] && [ -s "$output_file" ]; then
        log "Boîte déjà exportée: $user"
        mark_success "$user"
        return 0
    fi

    while [ $attempt -lt $MAX_RETRIES ] && [ $success -eq 0 ]; do
        ((attempt++))
        log "Tentative $attempt/$MAX_RETRIES pour $user"

        if timeout $TIMEOUT $ZMBOX -z -m "$user" getRestURL -t 0 "//${params}" >"${output_file}.tmp" 2>>"$LOG_FILE"; then
            if [ -s "${output_file}.tmp" ]; then
                mv "${output_file}.tmp" "$output_file"
                chown zimbra:zimbra "$output_file"
                log "Succès: $user"
                mark_success "$user"
                success=1
            else
                rm -f "${output_file}.tmp"
                log "Échec: Fichier vide pour $user"
            fi
        else
            rm -f "${output_file}.tmp"
            log "Échec: Commande a échoué pour $user"
        fi

        [ $success -eq 0 ] && sleep $WAIT_TIME
    done

    [ $success -eq 0 ] && mark_failed "$user"
    return $((1 - success))
}

### Fonction Principale ###
main() {
    [ -n "$FORCE" ] && { log "Option -f détectée, suppression du lock file"; rm -f "$LOCK_FILE"; }
    
    if ! acquire_lock; then
        log "ERREUR: Impossible d'acquérir le verrou. Utilisez -f pour forcer le démarrage."
        exit 1
    fi

    init_environment
    check_prerequisites
    rotate_logs

    log "=== Début du processus d'export ==="
    log "Paramètres:"
    if [ -n "$START" ]; then
        log "- Période: du $START au $END"
    else
        log "- Période: jusqu'au $END"
    fi
    log "- Format: $FORMAT"
    log "- Utilisateurs: $(grep -vc '^#\|^$' "$USERS_LIST")"

    local start end
    start=$(date_to_timestamp_ms "$START")
    end=$(date_to_timestamp_ms "$END")
    log "Timestamps: start=${start:-Aucun} end=$end"

    local total=0 success=0 failed=0
    while read -r user; do
        ((total++))
        if export_mailbox "$user" "$start" "$end"; then
            ((success++))
        else
            ((failed++))
        fi
    done < <(grep -v '^#\|^$' "$USERS_LIST")

    log "=== Rapport final ==="
    log "Total: $total | Succès: $success | Échecs: $failed"
    log "Consultez les logs: $LOG_FILE"
    log "Liste succès: $SUCCESS_LIST ($(wc -l <"$SUCCESS_LIST") lignes)"
    log "Liste échecs: $FAILED_LIST ($(wc -l <"$FAILED_LIST") lignes)"
}

### Point d'Entrée ###
main "$@"