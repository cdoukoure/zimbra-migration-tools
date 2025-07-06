#!/bin/bash
# Script ultra-optimisé pour l'import des utilisateurs Zimbra
# Version: 4.0
# Usage: sudo ./zimbra_import_accounts.sh [--force|--help]
# Usage en arrière-plan: nohup sudo ./zimbra_import_accounts.sh > zimbra_import_accounts.log 2>&1 &

### Configuration initiale ###
declare -r ZIMBRA_FOLDER="/opt/zimbra"
declare -r ZIMBRA_BIN="${ZIMBRA_FOLDER}/bin"
declare -r EXPORT_USER_FOLDER="${ZIMBRA_FOLDER}/backups/accounts-data"
declare -r TEMP_PASS="CHANGEme123!"
declare -ri MAX_RETRIES=3
declare -ri RETRY_DELAY=10

### Chemins des fichiers ###
declare -Ar IMPORT_PATHS=(
    [DOMAINS]="${EXPORT_USER_FOLDER}/domains.txt"
    [USERS]="${EXPORT_USER_FOLDER}/emails.txt"
    [DISTRIBUTION_LISTS]="${EXPORT_USER_FOLDER}/distributionlist.txt"
    [USERPASS]="${EXPORT_USER_FOLDER}/userpass"
    [USERDATA]="${EXPORT_USER_FOLDER}/userdata"
    [DL_MEMBERS]="${EXPORT_USER_FOLDER}/distributionlist_members"
    [FORWARDING]="${EXPORT_USER_FOLDER}/forwarding"
    [ALIAS]="${EXPORT_USER_FOLDER}/alias"
    [SIGNATURES]="${EXPORT_USER_FOLDER}/signatures"
    [FILTERS]="${EXPORT_USER_FOLDER}/filter"
)

declare -r LOG_FILE="${EXPORT_USER_FOLDER}/zimbra_import_$(date +%Y%m%d_%H%M%S).log"
declare -r LOCK_FILE="/tmp/zimbra_import.lock"
declare -r TIMESTAMP_FORMAT='%Y-%m-%d %H:%M:%S'

### Fonctions utilitaires optimisées ###
log() {
    printf "[$(date +"${TIMESTAMP_FORMAT}")] %s\n" "$1" | tee -a "${LOG_FILE}"
}

die() {
    log "ERREUR CRITIQUE: $1"
    exit 1
}

show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]
Options:
  -f, --force    Forcer l'exécution même si un autre processus est en cours
  -h, --help     Afficher cette aide et quitter
EOF
    exit 0
}

validate_environment() {
    (( EUID == 0 )) || die "Ce script doit être exécuté en tant que root"
    [[ -x "${ZIMBRA_BIN}/zmprov" ]] || die "Zimbra n'est pas correctement installé"
    [[ -d "${EXPORT_USER_FOLDER}" ]] || die "Répertoire d'import introuvable: ${EXPORT_USER_FOLDER}"
}

check_required_files() {
    local missing_files=()
    local file

    for file in "${IMPORT_PATHS[@]}"; do
        [[ -e "${file}" ]] || missing_files+=("${file}")
    done

    (( ${#missing_files[@]} > 0 )) && {
        log "Fichiers manquants:"
        printf "  - %s\n" "${missing_files[@]}" | tee -a "${LOG_FILE}"
        die "${#missing_files[@]} fichiers requis manquants"
    }
}

acquire_lock() {
    if [[ -f "${LOCK_FILE}" ]]; then
        local pid
        pid=$(cat "${LOCK_FILE}" 2>/dev/null)
        if [[ -n "${pid}" ]] && ps -p "${pid}" >/dev/null 2>&1; then
            log "Processus déjà en cours (PID: ${pid})"
            return 1
        else
            log "Nettoyage verrou orphelin (PID: ${pid})"
            rm -f "${LOCK_FILE}"
        fi
    fi

    if (set -o noclobber; echo $$ > "${LOCK_FILE}") 2>/dev/null; then
        trap 'release_lock' EXIT INT TERM
        return 0
    fi
    return 1
}

release_lock() {
    [[ -f "${LOCK_FILE}" && $$ -eq $(< "${LOCK_FILE}") ]] && rm -f "${LOCK_FILE}"
}

run_with_retry() {
    local -r cmd="$1"
    local attempt=0 output=""

    while (( attempt++ < MAX_RETRIES )); do
        output=$(eval "${cmd}" 2>&1)
        if (( $? == 0 )); then
            return 0
        fi
        sleep "${RETRY_DELAY}"
    done

    log "Échec après ${MAX_RETRIES} tentatives: ${cmd}"
    log "Dernière sortie: ${output}"
    return 1
}

### Fonctions principales optimisées ###
process_items() {
    local -r operation="$1" file="$2" action="$3" item_name="$4"
    local count=0 success=0 item

    log "Début ${operation}"
    while IFS= read -r item; do
        [[ -z "${item}" || "${item}" =~ ^# ]] && continue
        ((count++))
        
        if eval "${action}"; then
            ((success++))
        else
            log "Échec ${operation}: ${item}"
        fi
    done < "${file}"

    log "${operation} terminé: ${success}/${count} ${item_name} traités avec succès"
    (( count > 0 ))
}

process_domains() {
    process_items "création des domaines" "${IMPORT_PATHS[DOMAINS]}" \
        "${ZIMBRA_BIN}/zmprov gd '${item}' >/dev/null 2>&1 || 
         ${ZIMBRA_BIN}/zmprov cd '${item}' zimbraAuthMech zimbra" "domaines"
}

process_distribution_lists() {
    process_items "création des listes" "${IMPORT_PATHS[DISTRIBUTION_LISTS]}" \
        "${ZIMBRA_BIN}/zmprov gdl '${item}' >/dev/null 2>&1 || 
         ${ZIMBRA_BIN}/zmprov cdl '${item}'" "listes"
}

process_users() {
    local user count=0 success=0 shadowpass givenName displayName

    log "Début création des utilisateurs"
    while IFS= read -r user; do
        [[ -z "${user}" ]] && continue
        ((count++))
        
        shadowpass=$(< "${IMPORT_PATHS[USERPASS]}/${user}.shadow")
        [[ -z "${shadowpass}" ]] && {
            log "Mot de passe manquant: ${user}"
            continue
        }

        givenName=$(awk -F': ' '/^givenName:/ {print $2}' "${IMPORT_PATHS[USERDATA]}/${user}.txt")
        displayName=$(awk -F': ' '/^displayName:/ {print $2}' "${IMPORT_PATHS[USERDATA]}/${user}.txt")

        if ${ZIMBRA_BIN}/zmprov ga "${user}" >/dev/null 2>&1; then
            run_with_retry "${ZIMBRA_BIN}/zmprov ma '${user}' userPassword '${shadowpass}'" && ((success++))
        else
            run_with_retry "${ZIMBRA_BIN}/zmprov ca '${user}' '${TEMP_PASS}' cn '${givenName}' displayName '${displayName}' givenName '${givenName}'" &&
            run_with_retry "${ZIMBRA_BIN}/zmprov ma '${user}' userPassword '${shadowpass}'" && ((success++))
        fi
    done < "${IMPORT_PATHS[USERS]}"

    log "Utilisateurs traités: ${success}/${count} créés/mis à jour avec succès"
    (( count > 0 ))
}

process_list_members() {
    local list count=0 success=0

    log "Début ajout des membres aux listes"
    while IFS= read -r list; do
        [[ -z "${list}" || "${list}" =~ ^# ]] && continue
        local list_file="${IMPORT_PATHS[DL_MEMBERS]}/${list}.txt"
        
        [[ -f "${list_file}" ]] || continue
        
        while IFS= read -r member; do
            [[ -z "${member}" || "${member}" =~ ^# ]] && continue
            run_with_retry "${ZIMBRA_BIN}/zmprov adlm '${list}' '${member}'" && ((success++))
            ((count++))
        done < "${list_file}"
    done < "${IMPORT_PATHS[DISTRIBUTION_LISTS]}"

    log "Membres ajoutés: ${success}/${count} avec succès"
    (( count > 0 ))
}

process_aliases() {
    local user count=0 success=0

    log "Début restauration des alias"
    while IFS= read -r user; do
        [[ -z "${user}" ]] && continue
        local alias_file="${IMPORT_PATHS[ALIAS]}/${user}.txt"
        
        [[ -f "${alias_file}" ]] || continue
        
        while IFS= read -r alias; do
            [[ -z "${alias}" ]] && continue
            run_with_retry "${ZIMBRA_BIN}/zmprov aaa '${user}' '${alias}'" && ((success++))
            ((count++))
        done < "${alias_file}"
    done < "${IMPORT_PATHS[USERS]}"

    log "Alias traités: ${success}/${count} ajoutés avec succès"
    (( count > 0 ))
}

process_signatures() {
    local user count=0 success=0

    log "Début restauration des signatures"
    while IFS= read -r user; do
        [[ -z "${user}" ]] && continue
        local sig_file="${IMPORT_PATHS[SIGNATURES]}/${user}.signature"
        local name_file="${IMPORT_PATHS[SIGNATURES]}/${user}.name"
        
        [[ -f "${sig_file}" && -f "${name_file}" ]] || continue
        
        local sig_name=$(< "${name_file}")
        local sig_content=$(< "${sig_file}")
        local cmd1="${ZIMBRA_BIN}/zmprov ma '${user}' zimbraSignatureName '${sig_name}' zimbraPrefMailSignatureHTML '${sig_content}'"
        local cmd2=""
        
        if run_with_retry "${cmd1}"; then
            local sig_id=$(${ZIMBRA_BIN}/zmprov ga "${user}" zimbraSignatureId | grep -o '[0-9a-f-]*' | head -1)
            [[ -n "${sig_id}" ]] && {
                cmd2="${ZIMBRA_BIN}/zmprov ma '${user}' zimbraPrefDefaultSignatureId '${sig_id}' zimbraPrefForwardReplySignatureId '${sig_id}'"
                run_with_retry "${cmd2}" && ((success++))
            }
        fi
        ((count++))
    done < "${IMPORT_PATHS[USERS]}"

    log "Signatures traitées: ${success}/${count} restaurées avec succès"
    (( count > 0 ))
}

process_filters() {
    process_items "restauration des filtres" "${IMPORT_PATHS[USERS]}" \
        "[[ -f \"${IMPORT_PATHS[FILTERS]}/\${item}.filter\" ]] && \
         ${ZIMBRA_BIN}/zmprov ma '\${item}' zimbraMailSieveScript \"\$(< \"${IMPORT_PATHS[FILTERS]}/\${item}.filter\")\"" "filtres"
}

process_forwarding() {
    process_items "restauration des redirections" "${IMPORT_PATHS[USERS]}" \
        "[[ -f \"${IMPORT_PATHS[FORWARDING]}/\${item}.forward\" ]] && \
         ${ZIMBRA_BIN}/zmprov ma '\${item}' zimbraPrefMailForwardingAddress \"\$(< \"${IMPORT_PATHS[FORWARDING]}/\${item}.forward\")\"" "redirections"
}

### Fonction principale ###
main() {
    # Gestion des arguments
    local force=0
    while (( $# > 0 )); do
        case "$1" in
            -f|--force) force=1 ;;
            -h|--help)  show_usage ;;
            *)          die "Option invalide: $1" ;;
        esac
        shift
    done

    # Initialisation
    validate_environment
    ((force)) && { log "Mode forcé activé"; rm -f "${LOCK_FILE}"; }
    acquire_lock || die "Impossible d'acquérir le verrou"
    check_required_files

    log "Début du processus d'import"

    # Pipeline d'import
    local -a steps=(
        process_domains
        process_distribution_lists
        process_users
        process_list_members
        process_aliases
        process_signatures
        process_filters
        process_forwarding
    )
    
    local success=1
    for step in "${steps[@]}"; do
        ${step} || success=0
    done

    # Résultat final
    if ((success)); then
        log "Import terminé avec succès"
    else
        die "Échec partiel de l'import"
    fi

    # Nettoyage final
    chown -R zimbra:zimbra "${EXPORT_USER_FOLDER}"
}

### Point d'entrée ###
main "$@"