#!/bin/bash

# === Valeurs par défaut ===
ADMIN_USER="admin@domain.com"
ADMIN_PASS=""
FORMAT="tgz"
WAIT_TIME=60
MAX_RETRIES=3
EXPORT_DIR="/opt/zimbra/backups/remote"
USERS_LIST="/home/ubuntu/users.txt"

# === Aide ===
usage() {
    echo "Usage: $0 -z IP/FQDN [-a USER] [-p PASSWORD] [-s DEBUT] [-e FIN] [-o DIR] [-u FILE] [-h]"
    echo ""
    echo "Export distant des boîtes mail Zimbra en .tgz via API REST (auth token)."
    echo ""
    echo "Options :"
    echo "  -z IP/FQDN     IP ou nom DNS du serveur Zimbra (Proxy/MTA) [OBLIGATOIRE]"
    echo "  -a USER        Compte administrateur Zimbra (défaut : $ADMIN_USER)"
    echo "  -p PASSWORD    Mot de passe du compte admin"
    echo "  -s DATE        Date de début (JJ/MM/AAAA)"
    echo "  -e DATE        Date de fin   (JJ/MM/AAAA, défaut : demain)"
    echo "  -o DIR         Répertoire de sortie (défaut : $EXPORT_DIR)"
    echo "  -u FILE        Fichier des utilisateurs (défaut : $USERS_LIST)"
    echo "  -h             Affiche cette aide"
    echo ""
    echo "Exemple :"
    echo "  $0 -z 192.168.1.10 -a admin@domain.com -p motdepasse -e 10/07/2025"
    echo ""
    echo "Exécution en arrière-plan :"
    echo "  nohup $0 -z 192.168.1.10 -a admin@domain.com -p pass -e 10/07/2025 > export_\$(date +%F_%H%M).log 2>&1 &"
    echo "  nohup $0 -z 192.168.1.10 -a admin@domain.com -p pass -u /home/ubuntu/users_list.txt > export_\$(date +%F_%H%M).log 2>&1 &"
    exit 0
}

# === Traitement des arguments ===
while [[ $# -gt 0 ]]; do
    case "$1" in
        -z) ZIMBRA_IP="$2"; shift 2 ;;
        -a) ADMIN_USER="$2"; shift 2 ;;
        -p) ADMIN_PASS="$2"; shift 2 ;;
        -s) START="$2"; shift 2 ;;
        -e) END="$2"; shift 2 ;;
        -o) EXPORT_DIR="$2"; shift 2 ;;
        -u) USERS_LIST="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "❌ Option inconnue : $1"; usage ;;
    esac
done

# === Vérifications ===
[[ -z "$ZIMBRA_IP" ]] && { echo "❌ L’option -z est obligatoire."; usage; }
[[ -z "$ADMIN_PASS" ]] && { echo "❌ Le mot de passe admin est requis via -p."; usage; }

ZIMBRA_URL="https://${ZIMBRA_IP}:7071"
[[ -z "$END" ]] && END=$(date -d tomorrow +%d/%m/%Y)
[[ ! -f "$USERS_LIST" ]] && { echo "❌ Fichier utilisateur introuvable : $USERS_LIST"; exit 1; }

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

    local response=$(curl -sk -H "Content-Type: application/soap+xml" \
        -d "$auth_xml" "$ZIMBRA_URL/service/admin/soap")

    echo "$response" | grep -oPm1 "(?<=<authToken>)[^<]+"
}

# === Conversion JJ/MM/AAAA => timestamp ms ===
date_to_timestamp_ms() {
    local date="$1"
    [[ -z "$date" ]] && echo "" && return

    if ! [[ "$date" =~ ^[0-9]{2}/[0-9]{2}/[0-9]{4}$ ]]; then
        echo "❌ Format date invalide : $date (attendu JJ/MM/AAAA)"; exit 1
    fi

    local d=${date:0:2} m=${date:3:2} y=${date:6:4}
    date -d "$y-$m-$d 00:00:00" +%s | awk '{print $1 * 1000}'
}

# === Export d’un compte ===
export_user_mailbox() {
    local user="$1" token="$2" start_ts="$3" end_ts="$4"
    local params="?fmt=$FORMAT"
    [[ -n "$start_ts" ]] && params+="&start=$start_ts"
    [[ -n "$end_ts" ]] && params+="&end=$end_ts"
    local url="$ZIMBRA_URL/home/$user/$params"
    local out="$EXPORT_DIR/${user//@/_}.tgz"

    for ((i=1; i<=MAX_RETRIES; i++)); do
        echo "[Tentative $i] Export de $user"
        curl -sk --connect-timeout 10 --progress-bar \
            -H "Cookie: ZM_ADMIN_AUTH_TOKEN=$token" "$url" -o "$out"

        if [[ -s "$out" ]]; then
            echo "$user" >> "$SUCCESS_LIST"
            echo "✅ $user" >> "$LOG_FILE"
            return
        fi

        echo "⛔ Tentative $i échouée pour $user" >> "$LOG_FILE"
        sleep $WAIT_TIME
    done

    echo "$user" >> "$FAILED_LIST"
    echo "❌ Échec total pour $user" >> "$LOG_FILE"
}

# === Fonction principale ===
main() {
    mkdir -p "$EXPORT_DIR"
    LOG_FILE="$EXPORT_DIR/export_$(date +%Y%m%d_%H%M%S).log"
    SUCCESS_LIST="$EXPORT_DIR/success_$(date +%Y%m%d_%H%M%S).txt"
    FAILED_LIST="$EXPORT_DIR/failed_$(date +%Y%m%d_%H%M%S).txt"

    echo "🔐 Authentification à $ZIMBRA_URL avec $ADMIN_USER"
    token=$(get_auth_token)
    [[ -z "$token" ]] && { echo "❌ Authentification échouée."; exit 1; }

    echo "📅 Export : ${START:-TOUT} → $END"
    echo "📁 Export vers : $EXPORT_DIR"
    echo "📄 Utilisateurs depuis : $USERS_LIST"

    start_ts=$(date_to_timestamp_ms "$START")
    end_ts=$(date_to_timestamp_ms "$END")

    while IFS= read -r user; do
        [[ -z "$user" || "$user" =~ ^# ]] && continue
        export_user_mailbox "$user" "$token" "$start_ts" "$end_ts"
    done < "$USERS_LIST"

    echo "✅ Export terminé. Voir :"
    echo "📝 Log      : $LOG_FILE"
    echo "📄 Succès   : $SUCCESS_LIST"
    echo "📄 Échecs   : $FAILED_LIST"
}

main
