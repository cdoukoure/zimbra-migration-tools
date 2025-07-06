#!/bin/bash
# Zimbra Import Script Generator with Store Recovery, Resume, and Progress
# Run as: sudo -u zimbra ./zimbra_generate_import_scripts.sh

# Configuration
BACKUP_BASE="/opt/zimbra/backups/accounts-data"
IMPORT_SCRIPTS_DIR="${BACKUP_BASE}/import_scripts"
INCLUDE_GLOBAL_CONFIG=false
STORE_BASE="/opt/zimbra/store/0"
BACKUP_MAILBOX_DIR="${BACKUP_BASE}/accounts"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${BACKUP_BASE}/import_generator_${TIMESTAMP}.log"

# Initialize
mkdir -p "$IMPORT_SCRIPTS_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================="
echo "Zimbra Import Script Generator - Start: $(date)"
echo "Generating for NEW server store: $STORE_BASE"
echo "============================================="

# Generate store recovery script (for NEW server)
generate_store_recovery() {
    local script="${IMPORT_SCRIPTS_DIR}/0_recover_store.sh"
    
    cat > "$script" <<'EOF'
#!/bin/bash
# Zimbra Store Preparation for NEW Server
# Run as root on NEW server: ./0_recover_store.sh

start_time=$(date +%s)
echo "============================================="
echo "Preparing Zimbra Store on NEW Server"
echo "Started: $(date)"
echo "============================================="

# 1. Stop Zimbra services
su - zimbra -c "zmcontrol stop"

# 2. Validate store structure
echo "Verifying store location: /opt/zimbra/store/0"
if [[ ! -d "/opt/zimbra/store/0" ]]; then
    echo "ERROR: Store directory not found at /opt/zimbra/store/0"
    exit 1
fi

# 3. Set permissions
echo "Setting store permissions..."
chown -R zimbra:zimbra /opt/zimbra/store
chown -R zimbra:zimbra /opt/zimbra/index

# 4. Create index directory if missing
if [[ ! -d "/opt/zimbra/index" ]]; then
    echo "Creating index directory..."
    mkdir -p /opt/zimbra/index
    chown zimbra:zimbra /opt/zimbra/index
fi

# 5. Start Zimbra
su - zimbra -c "zmcontrol start"

end_time=$(date +%s)
elapsed=$((end_time - start_time))
echo "================================================================"
echo "Store preparation completed in $((elapsed/60))m $((elapsed%60))s"
echo "Proceed with import scripts"
echo "================================================================"
EOF
    chmod +x "$script"
    echo "Generated store recovery script for NEW server: $script"
}

# Generate domains import script
generate_domains_import() {
    local script="${IMPORT_SCRIPTS_DIR}/1_import_domains.sh"
    
    cat > "$script" <<'EOF'
#!/bin/bash
# Zimbra Domain Import Script
# Run as zimbra user: su - zimbra -c "./1_import_domains.sh"

start_time=$(date +%s)
BASE_DIR="/opt/zimbra/backups/accounts-data"
DOMAIN_DIR="$BASE_DIR/domains"
LOG_FILE="${BASE_DIR}/import_logs/domain_import_$(date +%Y%m%d_%H%M%S).log"
STATE_FILE="${BASE_DIR}/import_logs/domain_import_state.txt"

# Initialize
mkdir -p "${BASE_DIR}/import_logs"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================="
echo "Domain Import Started: $(date)"
echo "============================================="

# Resume functionality
declare -A processed_domains_map  # Use associative array for O(1) lookups
if [[ -f "$STATE_FILE" ]]; then
    echo "Resuming from previous state"
    while IFS= read -r domain_safe; do
        processed_domains_map["$domain_safe"]=1
    done < "$STATE_FILE"
fi

for domain_file in "$DOMAIN_DIR"/*.txt; do
    [[ -f "$domain_file" ]] || continue
    
    domain_safe=$(basename "$domain_file" .txt)
    domain_name="${domain_safe//_dot_/.}"  # More efficient replacement

    # Skip if already processed in this run
    if [[ ${processed_domains_map["$domain_safe"]+_} ]]; then
        echo "[SKIPPED] Domain already processed: $domain_name"
        continue
    fi
    
    # Skip if domain already exists in Zimbra
    if zmprov gd "$domain_name" >/dev/null 2>&1; then
        echo "[SKIPPED] Domain already exists: $domain_name"
        # Record in state file without processing
        echo "$domain_safe" >> "$STATE_FILE"
        processed_domains_map["$domain_safe"]=1
        continue
    fi
    
    # Extract domain attributes
    zimbraDomainStatus=$(awk '/^zimbraDomainStatus:/ {print $2}' "$domain_file")
    zimbraAuthMech=$(awk '/^zimbraAuthMech:/ {print $2}' "$domain_file")
    zimbraDomainType=$(awk '/^zimbraDomainType:/ {print $2}' "$domain_file")
    
    # Default values if not specified
    : "${zimbraDomainStatus:=active}"
    : "${zimbraAuthMech:=ldap}"
    : "${zimbraDomainType:=local}"
    
    echo "Creating domain: $domain_name"
    zmprov cd "$domain_name" zimbraDomainStatus "$zimbraDomainStatus" \
        zimbraAuthMech "$zimbraAuthMech" zimbraDomainType "$zimbraDomainType"
    
    # Apply additional attributes
    grep -vE '^(zimbraDomainStatus|zimbraAuthMech|zimbraDomainType|#|$)' "$domain_file" | \
    while IFS= read -r attr; do
        [[ -z "$attr" ]] && continue
        attr_name=$(echo "$attr" | cut -d: -f1)
        attr_value=$(echo "$attr" | cut -d: -f2- | sed 's/^[[:space:]]*//')
        echo "Applying attribute: $attr_name"
        zmprov md "$domain_name" "$attr_name" "$attr_value"
    done
    
    # Record processed domain
    echo "$domain_safe" >> "$STATE_FILE"
    processed_domains_map["$domain_safe"]=1
done

# Archive state file after successful run instead of deleting
if [[ -f "$STATE_FILE" ]]; then
    archive_file="${STATE_FILE}.completed_$(date +%Y%m%d_%H%M%S)"
    mv "$STATE_FILE" "$archive_file"
    echo "State file archived: $archive_file"
fi

end_time=$(date +%s)
elapsed=$((end_time - start_time))
echo "============================================="
echo "Domain Import Completed: $(date)"
echo "Total time: $((elapsed/60))m $((elapsed%60))s"
echo "Log file: $LOG_FILE"
echo "============================================="
EOF
    chmod +x "$script"
    echo "Generated domains import script: $script"
}

# Generate accounts import script (for NEW server)
generate_accounts_import() {
    local script="${IMPORT_SCRIPTS_DIR}/2_import_accounts.sh"
    
    cat > "$script" <<'EOF'
#!/bin/bash
# Zimbra Account Import for NEW Server (Improved)
# Run as zimbra on NEW server: ./2_import_accounts.sh

start_time=$(date +%s)
# Configuration for NEW server
BASE_DIR="/opt/zimbra/backups/accounts-data"
USER_DIR="$BASE_DIR/userdata"
PASS_DIR="$BASE_DIR/userpass"
STORE_BASE="/opt/zimbra/store/0"  # NEW server location
BACKUP_MAILBOX_DIR="$BASE_DIR/accounts"
LOG_FILE="${BASE_DIR}/import_logs/account_import_$(date +%Y%m%d_%H%M%S).log"
STATE_FILE="${BASE_DIR}/import_logs/account_import_state.txt"
RECOVERY_REPORT="${BASE_DIR}/import_logs/store_recovery_report.csv"

# Initialize
mkdir -p "${BASE_DIR}/import_logs"
exec >>(tee -a "$LOG_FILE") 2>&1

echo "============================================="
echo "Account Import on NEW Server - Start: $(date)"
echo "Store Location: $STORE_BASE"
echo "============================================="

# Create recovery report
echo "Email,Store_Status,Action_Taken,Timestamp" > "$RECOVERY_REPORT"

# Get all user files
user_files=("$USER_DIR"/*.txt)
total_files=${#user_files[@]}
counter=0

# Resume functionality using associative array
declare -A processed_accounts_map
if [[ -f "$STATE_FILE" ]]; then
    echo "Resuming from previous state"
    while IFS= read -r user_safe; do
        processed_accounts_map["$user_safe"]=1
    done < "$STATE_FILE"
fi

# Progress bar function with ETA
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percent=$((current * 100 / total))
    local progress=$((current * width / total))
    local current_time=$(date +%s)
    local elapsed=$((current_time - start_time))
    
    # Calculate ETA
    local eta=""
    if [[ $current -gt 10 ]]; then
        local avg_time=$((elapsed / current))
        local remaining=$(( (total - current) * avg_time ))
        eta=$(printf "ETA: %02d:%02d" $((remaining/60)) $((remaining%60)))
    fi
    
    # Build progress bar
    local bar=""
    for ((i=0; i<progress; i++)); do bar+="#"; done
    for ((i=progress; i<width; i++)); do bar+=" "; done
    
    # Format elapsed time
    local elapsed_str=$(printf "Elapsed: %02d:%02d" $((elapsed/60)) $((elapsed%60)))
    
    printf "\rProgress: [%s] %d%% (%d/%d) | %s | %s" \
        "$bar" "$percent" "$current" "$total" "$elapsed_str" "$eta"
}

# Account processing function
process_account() {
    local user_file=$1
    local user_safe=$(basename "$user_file" .txt)
    local timestamp=$(date +"%Y-%m-%d %T")
    local store_status="N/A"
    local action="SKIPPED"
    local new_store_path=""
    
    # Skip if already processed
    if [[ -n "${processed_accounts_map[$user_safe]}" ]]; then
        echo "Skipping already processed account: $user_safe"
        return
    fi
    
    # Reconstruct email address
    local user="${user_safe//_at_/@}"
    user="${user//_dot_/.}"

    # Special handling for emploijeunes.ci pattern
    if [[ "$user" == *"_emploijeunes_ci" ]]; then
        user="${user//_emploijeunes_ci/@emploijeunes.ci}"
        user="${user//_/.}"
    else
        user="${user//__/_}"
        user="${user//_/.}"
    fi

    # Validate email format
    if [[ ! "$user" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo "[ERROR] Invalid email format: $user (from $user_safe)"
        action="INVALID_EMAIL"
        echo "$user_safe" >> "$STATE_FILE"
        echo "$user,$store_status,$action,$timestamp" >> "$RECOVERY_REPORT"
        processed_accounts_map["$user_safe"]=1
        return
    fi
    
    # Skip if account exists
    if zmprov ga "$user" >/dev/null 2>&1; then
        echo "[SKIPPED] Account already exists: $user"
        action="EXISTING_ACCOUNT_SKIPPED"
        echo "$user_safe" >> "$STATE_FILE"
        echo "$user,$store_status,$action,$timestamp" >> "$RECOVERY_REPORT"
        processed_accounts_map["$user_safe"]=1
        return
    fi
    
    # Create account
    pass_file="$PASS_DIR/${user_safe}.shadow"
    if [[ -f "$pass_file" ]]; then
        password_hash=$(cat "$pass_file")
        echo "Using original password for $user"
        zmprov ca "$user" CHANGEME
        zmprov ma "$user" userPassword "$password_hash"
    else
        temp_pass=$(openssl rand -base64 16 | tr -d '=+/')
        echo "Using temporary password for $user"
        zmprov ca "$user" "$temp_pass"
    fi
    
    if [[ $? -ne 0 ]]; then
        echo "[ERROR] Failed to create account: $user"
        action="ACCOUNT_CREATION_FAILED"
        # Record in state and report
        echo "$user_safe" >> "$STATE_FILE"
        echo "$user,$store_status,$action,$timestamp" >> "$RECOVERY_REPORT"
        processed_accounts_map["$user_safe"]=1
        return
    fi
    action="ACCOUNT_CREATED"
    
    # Apply attributes
    echo "Applying attributes for $user"
    grep -vE '^(userPassword|zimbraAuthTokenAlgorithm|zimbraPassword|#|$)' "$user_file" | \
    while IFS= read -r attr; do
        [[ -z "$attr" ]] && continue
        attr_name=$(echo "$attr" | cut -d: -f1)
        attr_value=$(echo "$attr" | cut -d: -f2- | sed 's/^[[:space:]]*//')
        
        # Skip problematic attributes
        case "$attr_name" in
            zimbraMailStatus|zimbraAccountStatus|zimbraIsAdminAccount|zimbraId| \
            zimbraMailHost|zimbraMailboxHost|zimbraMailTransport|zimbraSmtpHostname| \
            zimbraSmtpSourceHostname|zimbraSmtpRelayHost)
                continue
                ;;
        esac
        
        zmprov ma "$user" "$attr_name" "$attr_value" >/dev/null 2>&1 || 
            echo "[WARNING] Failed to set attribute $attr_name for $user"
    done
    
    # Mailbox recovery logic
    store_path=$(find "$STORE_BASE" -maxdepth 2 -type d -name "$user_safe" -print -quit)
    backup_file="$BACKUP_MAILBOX_DIR/${user_safe}.tgz"
    
    if [[ -n "$store_path" ]]; then
        store_status="FOUND"
        # Get new mailbox ID
        new_mailbox_id=$(zmprov ga "$user" | grep zimbraMailboxId | awk -F: '{print $2}' | tr -d ' ')
        mailbox_id=$(basename "$(dirname "$store_path")")
        new_store_path="$STORE_BASE/$new_mailbox_id"
        
        # Move store to match new ID if needed
        if [[ "$mailbox_id" != "$new_mailbox_id" ]]; then            
            if [[ ! -d "$new_store_path" ]]; then
                mkdir -p "$new_store_path"
                mv "$store_path" "$new_store_path/"
                chown -R zimbra:zimbra "$new_store_path"
                store_status="MOVED"
                action="STORE_LINKED"
            else
                store_status="CONFLICT"
                action="STORE_CONFLICT"
                echo "[WARNING] Store path $new_store_path already exists for $user"
            fi
        else
            new_store_path="$STORE_BASE/$mailbox_id"
            store_status="MATCHED"
            action="STORE_LINKED"
        fi
        
        # Verify store integrity
        if [[ -d "$new_store_path/$user_safe/msg" && -n "$(ls -A "$new_store_path/$user_safe/msg")" ]]; then
            store_status="$store_status:INTACT"
        else
            store_status="$store_status:DAMAGED"
            # Import from backup if available
            if [[ -f "$backup_file" ]]; then
                echo "Importing mailbox from backup (damaged store)"
                zmmailbox -z -m "$user" postRestURL "/?fmt=tgz" "$backup_file"
                action="BACKUP_IMPORTED"
            else
                echo "[WARNING] Store damaged and no backup available"
                action="SKIPPED_MBOX_RESTORE"
            fi
        fi
    else
        store_status="NOT_FOUND"
        # Import from backup if available
        if [[ -f "$backup_file" ]]; then
            echo "Importing mailbox from backup"
            zmmailbox -z -m "$user" postRestURL "/?fmt=tgz" "$backup_file"
            action="BACKUP_IMPORTED"
        else
            echo "[INFO] No store data or backup available"
            action="SKIPPED_MBOX_RESTORE"
        fi
    fi
    
    # Record processed domain
    echo "$user_safe" >> "$STATE_FILE"
    echo "$user,$store_status,$action,$timestamp" >> "$RECOVERY_REPORT"
    processed_accounts_map["$user_safe"]=1
}

# Main processing loop
for user_file in "${user_files[@]}"; do
    # Skip non-files
    [[ -f "$user_file" ]] || continue
    
    # Process account
    process_account "$user_file"
    
    # Update progress
    ((counter++))
    show_progress $counter $total_files
done

# Final progress update
show_progress $total_files $total_files
printf "\n"

# Archive state file after successful run instead of deleting
if [[ -f "$STATE_FILE" ]]; then
    archive_file="${STATE_FILE}.completed_$(date +%Y%m%d_%H%M%S)"
    mv "$STATE_FILE" "$archive_file"
    echo "State file archived: $archive_file"
fi

end_time=$(date +%s)
elapsed=$((end_time - start_time))
echo "============================================="
echo "Account Import Summary:"
echo "Total accounts processed: $counter/$total_files"
echo "Total time: $((elapsed/60))m $((elapsed%60))s"
echo "Recovery report: $RECOVERY_REPORT"
echo "Log file: $LOG_FILE"
echo "============================================="
EOF
    chmod +x "$script"
    echo "Generated accounts import script for NEW server: $script"
}


# Generate distribution lists import script
generate_dls_import() {
    local script="${IMPORT_SCRIPTS_DIR}/3_import_dls.sh"
    
    cat > "$script" <<'EOF'
#!/bin/bash
# Distribution List Import Script
# Run as zimbra user: su - zimbra -c "./3_import_dls.sh"

start_time=$(date +%s)
BASE_DIR="/opt/zimbra/backups/accounts-data"
DL_DIR="$BASE_DIR/dl_attributes"
MEMBERS_DIR="$BASE_DIR/dl_members"
LOG_FILE="${BASE_DIR}/import_logs/dl_import_$(date +%Y%m%d_%H%M%S).log"
STATE_FILE="${BASE_DIR}/import_logs/dl_import_state.txt"

# Initialize
mkdir -p "${BASE_DIR}/import_logs"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================="
echo "Distribution List Import Started: $(date)"
echo "============================================="

# Resume functionality
processed_dls=()
if [[ -f "$STATE_FILE" ]]; then
    echo "Resuming from previous state"
    mapfile -t processed_dls < "$STATE_FILE"
fi

for dl_file in "$DL_DIR"/*.txt; do
    [[ -f "$dl_file" ]] || continue
    dl_safe=$(basename "$dl_file" .txt)
    dl=$(echo "$dl_safe" | sed 's/_at_/@/g; s/_dot_/./g; s/__/_/g')
    
    # Skip if already processed
    if printf '%s\n' "${processed_dls[@]}" | grep -q "^${dl_safe}$"; then
        echo "[SKIPPED] DL already processed: $dl"
        continue
    fi
    
    # Skip if DL already exists
    if zmprov gdl "$dl" >/dev/null 2>&1; then
        echo "[SKIPPED] DL already exists: $dl"
        echo "$dl_safe" >> "$STATE_FILE"
        continue
    fi
    
    # Create distribution list
    echo "Creating DL: $dl"
    zmprov cdl "$dl"
    
    if [[ $? -ne 0 ]]; then
        echo "[ERROR] Failed to create DL: $dl"
        continue
    fi
    
    # Add members
    members_file="$MEMBERS_DIR/${dl_safe}_members.txt"
    if [[ -f "$members_file" ]]; then
        echo "Adding members to $dl"
        while IFS= read -r member; do
            [[ -z "$member" ]] && continue
            member_email=$(echo "$member" | sed 's/_at_/@/g; s/_dot_/./g; s/__/_/g')
            
            # Validate member format
            if [[ "$member_email" =~ .+@.+\..+ ]]; then
                echo "Adding member: $member_email"
                zmprov adlm "$dl" "$member_email"
            else
                echo "[WARNING] Invalid member format: $member"
            fi
        done < "$members_file"
    else
        echo "No members file found for $dl"
    fi
    
    # Apply attributes
    echo "Applying attributes"
    grep -vE '^(#|$|zimbraId|zimbraMailHost|zimbraCreateTimestamp)' "$dl_file" | \
    while IFS= read -r attr; do
        [[ -z "$attr" ]] && continue
        attr_name=$(echo "$attr" | cut -d: -f1)
        attr_value=$(echo "$attr" | cut -d: -f2- | sed 's/^[[:space:]]*//')
        
        echo "Setting $attr_name"
        zmprov mdl "$dl" "$attr_name" "$attr_value"
    done
    
    # Record processed DL
    echo "$dl_safe" >> "$STATE_FILE"
done

end_time=$(date +%s)
elapsed=$((end_time - start_time))
echo "============================================="
echo "DL Import Completed: $(date)"
echo "Total time: $((elapsed/60))m $((elapsed%60))s"
echo "Log file: $LOG_FILE"
echo "============================================="
EOF
    chmod +x "$script"
    echo "Generated DLs import script: $script"
}

# Generate resources import script
generate_resources_import() {
    local script="${IMPORT_SCRIPTS_DIR}/4_import_resources.sh"
    
    cat > "$script" <<'EOF'
#!/bin/bash
# Resource Import Script
# Run as zimbra user: su - zimbra -c "./4_import_resources.sh"

start_time=$(date +%s)
BASE_DIR="/opt/zimbra/backups/accounts-data"
RESOURCE_DIR="$BASE_DIR/resources"
LOG_FILE="${BASE_DIR}/import_logs/resource_import_$(date +%Y%m%d_%H%M%S).log"
STATE_FILE="${BASE_DIR}/import_logs/resource_import_state.txt"

# Initialize
mkdir -p "${BASE_DIR}/import_logs"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================="
echo "Resource Import Started: $(date)"
echo "============================================="

# Resume functionality
processed_resources=()
if [[ -f "$STATE_FILE" ]]; then
    echo "Resuming from previous state"
    mapfile -t processed_resources < "$STATE_FILE"
fi

for resource_file in "$RESOURCE_DIR"/*.txt; do
    [[ -f "$resource_file" ]] || continue
    resource_safe=$(basename "$resource_file" .txt)
    resource=$(echo "$resource_safe" | sed 's/_at_/@/g; s/_dot_/./g; s/__/_/g')
    
    # Skip if already processed
    if printf '%s\n' "${processed_resources[@]}" | grep -q "^${resource_safe}$"; then
        echo "[SKIPPED] Resource already processed: $resource"
        continue
    fi
    
    # Skip if resource already exists
    if zmprov gr "$resource" >/dev/null 2>&1; then
        echo "[SKIPPED] Resource already exists: $resource"
        echo "$resource_safe" >> "$STATE_FILE"
        continue
    fi
    
    # Create resource with safer defaults
    echo "Creating resource: $resource"
    zmprov createResource "$resource" "Room" "Location" "Equipment" "no" "no" ""
    
    if [[ $? -ne 0 ]]; then
        echo "[ERROR] Failed to create resource: $resource"
        continue
    fi
    
    # Apply attributes
    echo "Applying attributes"
    grep -vE '^(#|$|zimbraId|zimbraCreateTimestamp)' "$resource_file" | \
    while IFS= read -r attr; do
        [[ -z "$attr" ]] && continue
        attr_name=$(echo "$attr" | cut -d: -f1)
        attr_value=$(echo "$attr" | cut -d: -f2- | sed 's/^[[:space:]]*//')
        
        # Skip location attributes that might cause issues
        case "$attr_name" in
            zimbraCalResLocation|zimbraCalResContactName)
                echo "Skipping location attribute: $attr_name"
                continue
                ;;
        esac
        
        echo "Setting $attr_name"
        zmprov modifyResource "$resource" "$attr_name" "$attr_value"
    done
    
    # Record processed resource
    echo "$resource_safe" >> "$STATE_FILE"
done

end_time=$(date +%s)
elapsed=$((end_time - start_time))
echo "============================================="
echo "Resource Import Completed: $(date)"
echo "Total time: $((elapsed/60))m $((elapsed%60))s"
echo "Log file: $LOG_FILE"
echo "============================================="
EOF
    chmod +x "$script"
    echo "Generated resources import script: $script"
}

# Generate global settings import script
generate_settings_import() {
    local script="${IMPORT_SCRIPTS_DIR}/5_import_settings.sh"
    
    if $INCLUDE_GLOBAL_CONFIG; then
        cat > "$script" <<'EOF'
#!/bin/bash
# SAFE Global Settings Import Script
# Run as zimbra user: su - zimbra -c "./5_import_settings.sh"

start_time=$(date +%s)
BASE_DIR="/opt/zimbra/backups/accounts-data"
GLOBAL_FILE="$BASE_DIR/global_config/global_settings.txt"
LOG_FILE="${BASE_DIR}/import_logs/settings_import_$(date +%Y%m%d_%H%M%S).log"
SAFE_SETTINGS_FILE="${BASE_DIR}/global_config/safe_to_import.txt"
STATE_FILE="${BASE_DIR}/import_logs/settings_import_state.txt"

# Initialize
mkdir -p "${BASE_DIR}/import_logs"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================="
echo "Global Settings Import Started: $(date)"
echo "============================================="

# Check if already completed
if [[ -f "$STATE_FILE" && "$(cat "$STATE_FILE")" == "COMPLETED" ]]; then
    echo "Settings already imported - skipping"
    exit 0
fi

# Create safe settings list
cat > "$SAFE_SETTINGS_FILE" <<SAFE_EOF
zimbraVersionCheckInterval
zimbraWebClientLoginURL
zimbraWebClientLogoutURL
zimbraCalendarDefaultApptVisibility
zimbraContactMaxNumEntries
zimbraGalLdapFilter
zimbraZimletAvailableZimlets
zimbraFileUploadMaxSize
zimbraMailQuota
zimbraPasswordLockoutDuration
zimbraSkinBackgroundColor
zimbraWebClientOfflineBrowserKey
zimbraWebClientOfflineCacheEnabled
zimbraWebClientOfflineCacheMaxSizeMB
zimbraWebClientOfflineCacheTTLDays
zimbraWebClientOfflineMailEnabled
zimbraWebClientOfflineMailMaxSizeMB
zimbraWebClientOfflineMailTTLDays
zimbraWebClientOfflineCalendarEnabled
zimbraWebClientOfflineCalendarMaxSizeMB
zimbraWebClientOfflineCalendarTTLDays
zimbraWebClientOfflineContactsEnabled
zimbraWebClientOfflineContactsMaxSizeMB
zimbraWebClientOfflineContactsTTLDays
zimbraLogStreamingEnabled
zimbraLogStreamingPort
zimbraLogStreamingServer
zimbraLogStreamingAdminEnabled
zimbraLogStreamingAdminPort
zimbraLogStreamingAdminServer
zimbraLogStreamingMailboxdEnabled
zimbraLogStreamingMailboxdPort
zimbraLogStreamingMailboxdServer
zimbraLogStreamingMemcachedEnabled
zimbraLogStreamingMemcachedPort
zimbraLogStreamingMemcachedServer
zimbraLogStreamingZmmailboxdEnabled
zimbraLogStreamingZmmailboxdPort
zimbraLogStreamingZmmailboxdServer
zimbraMemcachedClientEnabled
zimbraMemcachedClientServers
zimbraMemcachedClientPort
zimbraMemcachedClientTimeout
zimbraMailKeepOutgoingSpam
zimbraMailTrustedIP
zimbraMtaSmtpdTlsCiphers
zimbraMtaSmtpdTlsProtocols
zimbraMtaSmtpdTlsExcludeCiphers
zimbraMtaSmtpdTlsMandatoryCiphers
zimbraMtaSmtpdTlsMandatoryProtocols
zimbraMtaSmtpdTlsSecurityLevel
zimbraMtaSmtpdSaslSecurityOptions
zimbraMtaSmtpdSaslTlsSecurityOptions
zimbraMtaSmtpdSaslAuthenticatedHeader
zimbraMtaSmtpdSaslLocalDomain
zimbraMtaSmtpdSaslPath
SAFE_EOF

# Apply approved settings
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    
    setting_name=$(echo "$line" | awk '{print $1}')
    setting_value=$(echo "$line" | cut -d' ' -f2-)
    
    # Check if setting is in safe list
    if grep -q "^${setting_name}$" "$SAFE_SETTINGS_FILE"; then
        echo "Applying SAFE setting: $setting_name"
        zmprov mcf "$setting_name" "$setting_value"
    else
        echo "SKIPPED (unsafe): $setting_name"
    fi
done < "$GLOBAL_FILE"

# Mark as completed
echo "COMPLETED" > "$STATE_FILE"

end_time=$(date +%s)
elapsed=$((end_time - start_time))
echo "============================================="
echo "Global Settings Import Completed: $(date)"
echo "Total time: $((elapsed/60))m $((elapsed%60))s"
echo "NOTE: Skipped settings may require manual configuration"
echo "Log file: $LOG_FILE"
echo "============================================="
EOF
        chmod +x "$script"
        echo "Generated settings import script: $script"
    else
        # Create placeholder script
        cat > "$script" <<'EOF'
#!/bin/bash
echo "============================================="
echo "Global Settings Import"
echo "============================================="
echo "No global settings to import"
echo "This export was created without the -g/--include-global-config option"
echo "To include global settings, rerun export with:"
echo "    ./zimbra_export_accounts_v12.sh -g"
echo "============================================="
EOF
        chmod +x "$script"
        echo "Generated placeholder settings script: $script"
    fi
}

# Generate README file
generate_readme() {
    local readme="${IMPORT_SCRIPTS_DIR}/README.txt"
    
    cat > "$readme" <<EOF
Zimbra Import Scripts with Store Preservation
============================================
Generated on: $(date)
Store Location: $STORE_BASE

Execution Order:
0. 0_recover_store.sh     - Prepare existing store (run as root)
1. 1_import_domains.sh    - Creates domains
2. 2_import_accounts.sh   - Creates accounts and links to store
3. 3_import_dls.sh        - Creates distribution lists
4. 4_import_resources.sh  - Creates resources
5. 5_import_settings.sh   - Applies global settings (if exported)

Critical Instructions:
1. Run 0_recover_store.sh FIRST as root:
   sudo ./0_recover_store.sh

2. Run remaining scripts as zimbra user:
   su - zimbra
   cd /opt/zimbra/backups/accounts-data/import_scripts
   ./1_import_domains.sh
   ./2_import_accounts.sh
   ./3_import_dls.sh
   ./4_import_resources.sh
   ./5_import_settings.sh

3. Monitor logs in:
   /opt/zimbra/backups/accounts-data/import_logs

Key Features:
- Resume support for all scripts (restarts where it left off)
- Progress bar with ETA for account import
- Preserves existing mailboxes in /opt/zimbra/store/0
- Automatically links accounts to existing store data
- Uses TGZ backups only when store is damaged/missing
- Skips mailbox restore if no store or backup available
- Detailed timing metrics for each import step

Resume Instructions:
- If interrupted, simply rerun the same script
- Scripts will skip already processed items
- To restart from beginning, delete state files:
      rm /opt/zimbra/backups/accounts-data/import_logs/*_state.txt

Cleanup Recommendations:
1. After successful import:
   - Backup state files for audit purposes
   - Archive or delete TGZ files to save space
   - Rotate logs in import_logs directory
   - Remove temporary passwords from logs

2. Verify completion:
   - Check all import logs for errors
   - Validate mailbox access for test accounts
   - Confirm distribution list membership

Store Status:
- Store path exists: $(if [[ -d "$STORE_BASE" ]]; then echo "YES"; else echo "NO"; fi)
- Estimated accounts: $(find "$STORE_BASE" -maxdepth 2 -type d -name '*_at_*' 2>/dev/null | wc -l)

Import Flags:
- INCLUDE_GLOBAL_CONFIG: ${INCLUDE_GLOBAL_CONFIG}
EOF

    echo "Generated README: $readme"
}

# Generate all scripts
generate_store_recovery
generate_domains_import
generate_accounts_import
generate_dls_import
generate_resources_import
generate_settings_import
generate_readme

echo "============================================="
echo "Generation completed: $(date)"
echo "Import scripts directory: $IMPORT_SCRIPTS_DIR"
echo "============================================="
echo "Next steps:"
echo "1. Transfer backup directory to NEW server:"
echo "   nohup rsync -avz --progress $BACKUP_BASE/ ubuntu@new-server:$BACKUP_BASE > rsync-export.log 2>&1 &" >>"$LOG_FILE"
echo "2. On NEW server:"
echo "   sudo $IMPORT_SCRIPTS_DIR/0_recover_store.sh"
echo "   sudo -u zimbra $IMPORT_SCRIPTS_DIR/1_import_domains.sh"
echo "   sudo -u zimbra $IMPORT_SCRIPTS_DIR/2_import_accounts.sh"
echo "   sudo -u zimbra $IMPORT_SCRIPTS_DIR/3_import_dls.sh"
echo "   sudo -u zimbra $IMPORT_SCRIPTS_DIR/4_import_resources.sh"
echo "   sudo -u zimbra $IMPORT_SCRIPTS_DIR/5_import_settings.sh"
echo "=================================================="
echo "Note: All scripts support resume functionality"
echo "      If interrupted, simply rerun the same script"
echo "=================================================="