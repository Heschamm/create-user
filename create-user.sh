#!/bin/bash
set -u

LOG_FILE="/tmp/create_temp_ssh_user_$(date +%Y%m%d_%H%M%S).log"
SSH_READONLY_GROUP="sshreadonly"
SSHD_CONFIG="/etc/ssh/sshd_config"

run_cmd() {
  echo
  echo "### COMMAND: $*" | tee -a "$LOG_FILE"
  "$@" 2>&1 | tee -a "$LOG_FILE"
  RC=${PIPESTATUS[0]}
  echo "### EXIT_CODE: $RC" | tee -a "$LOG_FILE"
  return $RC
}

echo "Temporary SSH user creation" | tee "$LOG_FILE"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Run this script as root or with sudo." | tee -a "$LOG_FILE"
  exit 1
fi

read -rp "Username: " USER_NAME
read -rp "Full Name: " FULL_NAME
read -rp "Email Address: " EMAIL

if ! [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
  echo "ERROR: Invalid email address." | tee -a "$LOG_FILE"
  exit 1
fi

read -rsp "Password: " USER_PASSWORD
echo
read -rsp "Confirm Password: " USER_PASSWORD_CONFIRM
echo

if [ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]; then
  echo "ERROR: Passwords do not match." | tee -a "$LOG_FILE"
  exit 1
fi

read -rp "Account validity in days: " VALID_DAYS

if ! [[ "$VALID_DAYS" =~ ^[0-9]+$ ]] || [ "$VALID_DAYS" -lt 1 ]; then
  echo "ERROR: Validity must be a positive number." | tee -a "$LOG_FILE"
  exit 1
fi

echo
echo "Select access profile:"
echo "1) Read-only SSH user, no sudo, no admin groups - recommended"
echo "2) Limited sudo for safe status commands only"
echo "3) Admin sudo access - not recommended"
read -rp "Enter choice [1-3]: " ACCESS_CHOICE

case "$ACCESS_CHOICE" in
  1) ACCESS_PROFILE="READ_ONLY_NO_SUDO" ;;
  2) ACCESS_PROFILE="LIMITED_SUDO_STATUS_ONLY" ;;
  3) ACCESS_PROFILE="ADMIN_SUDO" ;;
  *)
    echo "ERROR: Invalid access choice." | tee -a "$LOG_FILE"
    exit 1
    ;;
esac

EXPIRY_DATE="$(date -d "+${VALID_DAYS} days" +%F)"
CREATED_DATE="$(date +%F)"
SUDOERS_FILE="/etc/sudoers.d/${USER_NAME}_temporary_access"

echo
echo "=== Input Summary ===" | tee -a "$LOG_FILE"
echo "Username: $USER_NAME" | tee -a "$LOG_FILE"
echo "Full Name: $FULL_NAME" | tee -a "$LOG_FILE"
echo "Email: $EMAIL" | tee -a "$LOG_FILE"
echo "Validity: $VALID_DAYS days" | tee -a "$LOG_FILE"
echo "Created date: $CREATED_DATE" | tee -a "$LOG_FILE"
echo "Expiry date: $EXPIRY_DATE" | tee -a "$LOG_FILE"
echo "Access profile: $ACCESS_PROFILE" | tee -a "$LOG_FILE"

echo
echo "=== Creating or updating user ===" | tee -a "$LOG_FILE"

if id "$USER_NAME" >/dev/null 2>&1; then
  echo "User $USER_NAME already exists. Updating expiry and shell." | tee -a "$LOG_FILE"
  run_cmd chage -E "$EXPIRY_DATE" "$USER_NAME"
  run_cmd usermod -s /bin/bash "$USER_NAME"
else
  run_cmd useradd -m -s /bin/bash -e "$EXPIRY_DATE" "$USER_NAME"
fi

if ! id "$USER_NAME" >/dev/null 2>&1; then
  echo "ERROR: User $USER_NAME was not created. Stopping." | tee -a "$LOG_FILE"
  exit 1
fi

echo
echo "=== Setting password ===" | tee -a "$LOG_FILE"
echo "$USER_NAME:$USER_PASSWORD" | chpasswd

if [ $? -eq 0 ]; then
  echo "Password set successfully." | tee -a "$LOG_FILE"
else
  echo "ERROR: Failed to set password." | tee -a "$LOG_FILE"
  exit 1
fi

echo
echo "=== Applying access profile ===" | tee -a "$LOG_FILE"

case "$ACCESS_PROFILE" in
  READ_ONLY_NO_SUDO)
    rm -f "$SUDOERS_FILE"

    for GROUP in wheel sudo adm root; do
      if getent group "$GROUP" >/dev/null 2>&1; then
        if id -nG "$USER_NAME" | grep -qw "$GROUP"; then
          run_cmd gpasswd -d "$USER_NAME" "$GROUP"
        fi
      fi
    done

    if ! getent group "$SSH_READONLY_GROUP" >/dev/null 2>&1; then
      run_cmd groupadd "$SSH_READONLY_GROUP"
    fi

    run_cmd usermod -aG "$SSH_READONLY_GROUP" "$USER_NAME"

    if grep -Eq '^[[:space:]]*AllowGroups[[:space:]]+' "$SSHD_CONFIG"; then
      CURRENT_ALLOWGROUPS="$(grep -E '^[[:space:]]*AllowGroups[[:space:]]+' "$SSHD_CONFIG" | tail -1)"

      if ! echo "$CURRENT_ALLOWGROUPS" | grep -qw "$SSH_READONLY_GROUP"; then
        BACKUP_FILE="${SSHD_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
        run_cmd cp "$SSHD_CONFIG" "$BACKUP_FILE"
        EXISTING_GROUPS="$(echo "$CURRENT_ALLOWGROUPS" | awk '{$1=""; sub(/^ /,""); print}')"
        run_cmd sed -i "s/^[[:space:]]*AllowGroups[[:space:]].*/AllowGroups ${EXISTING_GROUPS} ${SSH_READONLY_GROUP}/" "$SSHD_CONFIG"
      fi
    else
      BACKUP_FILE="${SSHD_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
      run_cmd cp "$SSHD_CONFIG" "$BACKUP_FILE"
      echo "AllowGroups $SSH_READONLY_GROUP" >> "$SSHD_CONFIG"
    fi

    if sshd -t; then
      run_cmd systemctl restart sshd
    else
      echo "ERROR: sshd config validation failed." | tee -a "$LOG_FILE"
      exit 1
    fi
    ;;

  LIMITED_SUDO_STATUS_ONLY)
    for GROUP in wheel sudo adm root; do
      if getent group "$GROUP" >/dev/null 2>&1; then
        if id -nG "$USER_NAME" | grep -qw "$GROUP"; then
          run_cmd gpasswd -d "$USER_NAME" "$GROUP"
        fi
      fi
    done

    cat > "$SUDOERS_FILE" <<EOF
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/systemctl status *, /usr/bin/journalctl, /usr/bin/df, /usr/bin/free, /usr/bin/ss, /usr/bin/ip, /usr/bin/hostnamectl, /usr/bin/timedatectl
EOF

    chmod 440 "$SUDOERS_FILE"

    if ! visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
      echo "ERROR: sudoers validation failed. Removing file." | tee -a "$LOG_FILE"
      rm -f "$SUDOERS_FILE"
      exit 1
    fi
    ;;

  ADMIN_SUDO)
    if getent group wheel >/dev/null 2>&1; then
      run_cmd usermod -aG wheel "$USER_NAME"
    elif getent group sudo >/dev/null 2>&1; then
      run_cmd usermod -aG sudo "$USER_NAME"
    else
      echo "ERROR: No wheel or sudo group found." | tee -a "$LOG_FILE"
      exit 1
    fi
    ;;
esac

echo
echo "=== Verification ===" | tee -a "$LOG_FILE"

run_cmd id "$USER_NAME"
run_cmd groups "$USER_NAME"
run_cmd chage -l "$USER_NAME"
run_cmd getent passwd "$USER_NAME"
run_cmd ls -ld "/home/$USER_NAME"
run_cmd passwd -S "$USER_NAME"

if command -v sudo >/dev/null 2>&1; then
  run_cmd sudo -l -U "$USER_NAME"
fi

echo
echo "==================================================" | tee -a "$LOG_FILE"
echo "TEMPORARY SSH ACCOUNT CREATED / UPDATED" | tee -a "$LOG_FILE"
echo "==================================================" | tee -a "$LOG_FILE"
echo "Username       : $USER_NAME" | tee -a "$LOG_FILE"
echo "Full Name      : $FULL_NAME" | tee -a "$LOG_FILE"
echo "Email          : $EMAIL" | tee -a "$LOG_FILE"
echo "Password       : $USER_PASSWORD" | tee -a "$LOG_FILE"
echo "Created        : $CREATED_DATE" | tee -a "$LOG_FILE"
echo "Expires        : $EXPIRY_DATE" | tee -a "$LOG_FILE"
echo "Valid Days     : $VALID_DAYS" | tee -a "$LOG_FILE"
echo "Access Profile : $ACCESS_PROFILE" | tee -a "$LOG_FILE"
echo "Log File       : $LOG_FILE" | tee -a "$LOG_FILE"
echo "==================================================" | tee -a "$LOG_FILE"

echo
echo "COMPLIANCE NOTICE" | tee -a "$LOG_FILE"
echo "For compliance reasons: created user(s) should use the command passwd to change their password after first successful login." | tee -a "$LOG_FILE"

echo
echo "TROUBLESHOOTING COMMAND" | tee -a "$LOG_FILE"
echo "passwd -S <username> ; getent passwd <username> ; grep -Ei 'AllowUsers|AllowGroups|DenyUsers|DenyGroups|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication' /etc/ssh/sshd_config ; ls -ld /home/<username> ; stat -c \"%U %G %a\" /home/<username> ; journalctl -u sshd -n 50 --no-pager" | tee -a "$LOG_FILE"
