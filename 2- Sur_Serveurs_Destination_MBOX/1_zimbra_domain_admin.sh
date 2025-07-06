#!/bin/bash
# Script d'administration Zimbra - Version 2.4 corrigée

### Configuration ###
declare -r LOG_FILE="/opt/zimbra/log/admin_delegation_$(date +%Y%m%d_%H%M%S).log"
declare -r LOCK_FILE="/tmp/zimbra_admin_delegation.lock"
EMAIL_LIST_FILE_DEFAULT="/opt/zimbra/backups/accounts-data/admins.txt"

### Variables ###
DOMAIN=""
EMAIL_LIST_FILE=""
CREATE_MISSING=false
SUCCESS_COUNT=0
FAIL_COUNT=0
SKIPPED_COUNT=0
CREATED_COUNT=0

### Fonctions ###

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -d, --domain DOMAIN    Domaine Zimbra (requis)
  -a, --admin FILE       Fichier des admins (défaut: $EMAIL_LIST_FILE_DEFAULT)
  -c, --create           Créer les comptes manquants
  -h, --help             Afficher cette aide

Exemples:
  $0 -d example.com -a /chemin/admins.txt
  $0 -d example.com --create
EOF
    exit 0
}

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR" "$1"
    [ -f "$LOCK_FILE" ] && rm -f "$LOCK_FILE"
    exit 1
}

validate_environment() {
    # Vérifier l'utilisateur zimbra
    if [ "$(whoami)" != "zimbra" ]; then
        error_exit "Ce script doit être exécuté en tant qu'utilisateur zimbra"
    fi

    # Vérifier le domaine
    [ -z "$DOMAIN" ] && error_exit "Le paramètre --domain est obligatoire"
    
    # Vérifier le fichier
    [ -f "$EMAIL_LIST_FILE" ] || error_exit "Fichier $EMAIL_LIST_FILE introuvable"

    # Vérifier le lock file
    if [ -f "$LOCK_FILE" ]; then
        error_exit "Le script est déjà en cours d'exécution"
    fi
    touch "$LOCK_FILE"
}

cleanup() {
    [ -f "$LOCK_FILE" ] && rm -f "$LOCK_FILE"
    log "INFO" "Nettoyage effectué"
}

create_account() {
    local email="$1"
    local temp_password=$(openssl rand -base64 12 | tr -d '\n')
    
    log "INFO" "Création du compte $email"
    zmprov ca "$email" "$temp_password" displayName "$(echo $email | cut -d@ -f1)" || {
        log "ERROR" "Échec de la création du compte $email"
        return 1
    }
    
    log "INFO" "Compte créé avec mot de passe temporaire"
    ((CREATED_COUNT++))
    return 0
}

validate_email() {
    local email="$1"
    # Expression régulière plus permissive pour les emails Zimbra
    [[ "$email" =~ ^[a-zA-Z0-9._+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || {
        log "ERROR" "Format d'email potentiellement invalide: $email (vérification manuelle recommandée)"
        return 1
    }
    return 0
}

apply_admin_rights() {
    local email="$1"
    email=$(echo "$email" | tr '[:upper:]' '[:lower:]' | xargs)
    
    # Validation moins restrictive
    # validate_email "$email" || {
    #     ((FAIL_COUNT++))
    #     return 1
    # }
    
    log "INFO" "Traitement de $email..."
    
    if ! zmprov ga "$email" &> /dev/null; then
        if $CREATE_MISSING; then
            create_account "$email" || return 1
        else
            log "ERROR" "Compte $email inexistant (utilisez --create)"
            ((FAIL_COUNT++))
            return 1
        fi
    fi

    if zmprov ga "$email" zimbraIsDelegatedAdminAccount | grep -q "TRUE"; then
        log "INFO" "Compte $email est déjà admin - mise à jour"
        ((SKIPPED_COUNT++))
    fi
    
    # Configuration admin
    zmprov ma "$email" zimbraIsDelegatedAdminAccount TRUE || {
        log "ERROR" "Échec activation admin pour $email"
        ((FAIL_COUNT++))
        return 1
    }

    zmprov ma "$email" zimbraAdminConsoleUIComponents cartBlancheUI domainListView accountListView DLListView
    zmprov ma "$email" zimbraDomainAdminMaxMailQuota 0

    # Droits sur le domaine
    local domain_rights=(
        "+createAccount" "+createAlias" "+createCalendarResource"
        "+createDistributionList" "+deleteAlias" "+listDomain"
        "+domainAdminRights" "+configureQuota" "set.account.zimbraAccountStatus"
        "set.account.sn" "set.account.displayName" "set.account.zimbraPasswordMustChange"
    )

    for right in "${domain_rights[@]}"; do
        zmprov grantRight domain "$DOMAIN" usr "$email" "$right" || log "WARN" "Échec droit $right"
    done

    # Droits sur le compte
    local account_rights=(
        "+deleteAccount" "+getAccountInfo" "+getAccountMembership"
        "+getMailboxInfo" "+listAccount" "+removeAccountAlias"
        "+renameAccount" "+setAccountPassword" "+viewAccountAdminUI"
        "+configureQuota"
    )

    for right in "${account_rights[@]}"; do
        zmprov grantRight account "$email" usr "$email" "$right" || log "WARN" "Échec droit $right"
    done
    
    ((SUCCESS_COUNT++))
    return 0
}

### Main ###
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -d|--domain) DOMAIN="$2"; shift ;;
        -a|--admin) EMAIL_LIST_FILE="$2"; shift ;;
        -c|--create) CREATE_MISSING=true ;;
        -h|--help) show_help ;;
        *) echo "Option invalide: $1" >&2; show_help; exit 1 ;;
    esac
    shift
done

[ -z "$EMAIL_LIST_FILE" ] && EMAIL_LIST_FILE="$EMAIL_LIST_FILE_DEFAULT"

main() {
    trap cleanup EXIT INT TERM
    
    log "INFO" "=== Début du traitement ==="
    log "INFO" "Domaine: $DOMAIN"
    log "INFO" "Fichier: $EMAIL_LIST_FILE"
    log "INFO" "Création: $([ "$CREATE_MISSING" = true ] && echo "true" || echo "false")"
    
    validate_environment
    
    TEMP_FILE=$(mktemp)
    # Nettoyage du fichier d'entrée en conservant les caractères spéciaux
    grep -v '^[[:space:]]*$' "$EMAIL_LIST_FILE" | grep -v '^#' | sort -u > "$TEMP_FILE"
    
    while IFS= read -r email; do
        [ -z "$email" ] && continue
        apply_admin_rights "$email" || true
        sleep 0.5
    done < "$TEMP_FILE"
    rm -f "$TEMP_FILE"
    
    log "INFO" "=== Rapport ==="
    log "INFO" "Comptes créés: $CREATED_COUNT"
    log "INFO" "Succès: $SUCCESS_COUNT"
    log "INFO" "Déjà admin: $SKIPPED_COUNT"
    log "INFO" "Échecs: $FAIL_COUNT"
    log "INFO" "=== Fin ==="
}

main