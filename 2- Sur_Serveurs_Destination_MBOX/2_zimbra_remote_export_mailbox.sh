#!/bin/bash

# === Config par défaut ===
ADMIN_USER="admin@domain.com"
ADMIN_PASS=""
FORMAT="tgz"
WAIT_TIME=60
MAX_RETRIES=3
EXPORT_DIR="/opt/zimbra/backups/zmmailbox-all"
USERS_LIST="/home/ubuntu/users.txt"
PARALLEL_JOBS=10
LOCK_FILE="/tmp/zimbra_export.lock"

# === Aide ===
usage() {
    echo "Usage: $0 -z IP/FQDN [-a USER] [-p PASSWORD] [-s DEBUT] [-e FIN] [-o DIR] [-u FILE] [-j N] [-h]"
    echo ""
    echo "Options :"
    echo "  -z IP/FQDN     IP ou nom DNS du serveur Zimbra (obligatoire)"
    echo "  -a USER        Admin Zimbra (défaut : $ADMIN_USER)"
    echo "  -p PASSWORD    Mot de passe admin (obligatoire)"
    echo "  -s DATE        Date début JJ/MM/AAAA"
    echo "  -e DATE        Date fin JJ/MM/AAAA (défaut : demain)"
    echo "  -o DIR         Répertoire export (défaut : $EXPORT_DIR)"
    echo "  -u FILE        Fichier utilisateurs (défaut : $USERS_LIST)"
    echo "  -j N           Jobs parallèles (défaut : $PARALLEL_JOBS)"
    echo "  -h             Aide"
    echo ""
    echo "Exemple : nohup $0 -z 192.168.1.10 -a admin@domain.com -p pass -e 10/07/2025 -j 20 > export_$(date +%F_%H%M).log 2>&1 &"
    exit 0
}

# === Parse args ===
while [[ $# -gt 0 ]]; do
    case "$1" in
        -z) ZIMBRA_IP="$2"; shift 2 ;;
        -a) ADMIN_USER="$2"; shift 2 ;;
        -p) ADMIN_PASS="$2"; shift 2 ;;
        -s) START="$2"; shift 2 ;;
        -e) END="$2"; shift 2 ;;
        -o) EXPORT_DIR="$2"; shift 2 ;;
        -u) USERS_LIST="$2"; shift 2 ;;
        -j) PARALLEL_JOBS="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Option inconnue : $1"; usage ;;
    esac
done

# === Vérifications ===
[[ -z "$ZIMBRA_IP" ]] && { echo "❌ -z (IP/FQDN) obligatoire"; usage; }
[[ -z "$ADMIN_PASS" ]] && { echo "❌ -p (admin password) obligatoire"; usage; }
[[ ! -f "$USERS_LIST" ]] && { echo "❌ Fichier utilisateurs introuvable: $USERS_LIST"; exit 1; }
[[ -z "$END" ]] && END=$(date -d tomorrow +%d/%m/%Y)

ZIMBRA_URL="https://${ZIMBRA_IP}:7071"

mkdir -p "$EXPORT_DIR"

LOG_FILE="$EXPORT_DIR/export_$(date +%Y%m%d_%H%M%S).log"
SUCCESS_LIST="$EXPORT_DIR/success_list.txt"
FAILED_LIST="$EXPORT_DIR/failed_list.txt"

# === Lock ===
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            echo "❌ Script déjà en cours (PID $pid). Quitte."
            exit 1
        else
            echo "⚠️ Suppression lock orphelin (PID $pid)"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"; exit' INT TERM EXIT
    echo "🔒 Lock acquis (PID $$)"
}

release_lock() {
    rm -f "$LOCK_FILE"
    echo "🔓 Lock libéré"
}

# === Logger (main log + log par utilisateur) ===
log() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" | tee -a "$LOG_FILE"
}

log_user() {
    local user="$1" msg="$2"
    local logfile="$EXPORT_DIR/logs/${user//@/_}.log"
    mkdir -p "$(dirname "$logfile")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$logfile"
}

# === Date to timestamp ms ===
date_to_timestamp_ms() {
    local date="$1"
    [[ -z "$date" ]] && echo "" && return
    if ! [[ "$date" =~ ^[0-9]{2}/[0-9]{2}/[0-9]{4}$ ]]; then
        echo "❌ Format date invalide : $date" >&2
        exit 1
    fi
    local d=${date:0:2} m=${date:3:2} y=${date:6:4}
    date -d "$y-$m-$d 00:00:00" +%s | awk '{print $1 * 1000}'
}

# === Authentification admin ===
get_auth_token() {
    local auth_xml="<?xml version='1.0' encoding='UTF-8'?>
<soap:Envelope xmlns:soap='http://www.w3.org/2003/05/soap-envelope'>
  <soap:Body>
    <AuthRequest xmlns='urn:zimbraAdmin'>
      <name>$ADMIN_USER</name>
      <password>$ADMIN_PASS</password>
    </AuthRequest>
  </soap:Body>
</soap:Envelope>"
    local resp=$(curl -sk -H "Content-Type: application/soap+xml" -d "$auth_xml" "$ZIMBRA_URL/service/admin/soap")
    echo "$resp" | grep -oPm1 "(?<=<authToken>)[^<]+"
}

# === Vérifier si utilisateur déjà exporté ===
is_processed() {
    local user="$1"
    grep -qFx "$user" "$SUCCESS_LIST" 2>/dev/null || grep -qFx "$user" "$FAILED_LIST" 2>/dev/null
}

mark_success() {
    local user="$1"
    if ! grep -qFx "$user" "$SUCCESS_LIST" 2>/dev/null; then
        echo "$user" >> "$SUCCESS_LIST"
    fi
    # Nettoyer des échecs s’il y en a
    sed -i "/^$user$/d" "$FAILED_LIST" 2>/dev/null || true
}

mark_failed() {
    local user="$1"
    if ! grep -qFx "$user" "$FAILED_LIST" 2>/dev/null; then
        echo "$user" >> "$FAILED_LIST"
    fi
}

# === Export utilisateur ===
export_user_mailbox() {
    local user="$1" token="$2" start_ts="$3" end_ts="$4"
    local params="?fmt=$FORMAT"
    [[ -n "$start_ts" ]] && params+="&start=$start_ts"
    [[ -n "$end_ts" ]] && params+="&end=$end_ts"
    local url="$ZIMBRA_URL/home/$user/$params"
    local out="$EXPORT_DIR/${user//@/_}.tgz"
    local logfile="$EXPORT_DIR/logs/${user//@/_}.log"
    mkdir -p "$(dirname "$logfile")"

    if is_processed "$user"; then
        log "🔹 $user déjà traité, passage au suivant."
        return 0
    fi

    for ((i=1; i<=MAX_RETRIES; i++)); do
        log_user "$user" "[Tentative $i/$MAX_RETRIES]"
        log "[$user] Tentative $i/$MAX_RETRIES"

        curl -sk --connect-timeout 30 --progress-bar -H "Cookie: ZM_ADMIN_AUTH_TOKEN=$token" "$url" -o "$out" >>"$logfile" 2>&1

        if [[ -s "$out" ]]; then
            mark_success "$user"
            log "✅ $user exporté avec succès."
            log_user "$user" "Succès export"
            return 0
        fi

        log "⛔ Échec tentative $i pour $user"
        log_user "$user" "Échec tentative $i"
        sleep "$WAIT_TIME"
    done

    mark_failed "$user"
    log "❌ Échec total pour $user après $MAX_RETRIES tentatives."
    log_user "$user" "Échec total"
    return 1
}

# === Wrapper pour parallélisation ===
export_wrapper() {
    local user="$1"
    export_user_mailbox "$user" "$AUTH_TOKEN" "$START_TS" "$END_TS"
}

export_parallel() {
    log "🚀 Lancement export parallèle ($PARALLEL_JOBS jobs)..."

    export -f export_user_mailbox export_wrapper is_processed mark_success mark_failed log log_user
    export AUTH_TOKEN="$AUTH_TOKEN"
    export START_TS="$START_TS"
    export END_TS="$END_TS"
    export EXPORT_DIR="$EXPORT_DIR"
    export MAX_RETRIES="$MAX_RETRIES"
    export WAIT_TIME="$WAIT_TIME"
    export LOG_FILE="$LOG_FILE"
    export SUCCESS_LIST="$SUCCESS_LIST"
    export FAILED_LIST="$FAILED_LIST"
    export FORMAT="$FORMAT"
    export ZIMBRA_URL="$ZIMBRA_URL"

    mkdir -p "$EXPORT_DIR/logs"

    grep -vE '^#|^$' "$USERS_LIST" | xargs -P "$PARALLEL_JOBS" -I{} bash -c 'export_wrapper "{}"'
}

# === Rapport final ===
report() {
    local total=$(wc -l < "$USERS_LIST" | tr -d ' ')
    local success=$(wc -l < "$SUCCESS_LIST" 2>/dev/null || echo 0)
    local failed=$(wc -l < "$FAILED_LIST" 2>/dev/null || echo 0)

    log "=== Rapport final ==="
    log "Total comptes : $total"
    log "Succès        : $success"
    log "Échecs       : $failed"

    if [ "$failed" -gt 0 ]; then
        log "📄 Liste des échecs dans : $FAILED_LIST"
    fi
    log "📄 Logs utilisateur dans : $EXPORT_DIR/logs/"
    log "📄 Log global dans : $LOG_FILE"
}

# === Main ===
main() {
    acquire_lock

    log "🔐 Authentification admin..."
    AUTH_TOKEN=$(get_auth_token)
    if [[ -z "$AUTH_TOKEN" ]]; then
        log "❌ Échec d’authentification"
        release_lock
        exit 1
    fi

    log "📅 Export des mails du ${START:-'début'} au $END"
    START_TS=$(date_to_timestamp_ms "$START")
    END_TS=$(date_to_timestamp_ms "$END")

    export_parallel

    report

    release_lock
}

main "$@"
