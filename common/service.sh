#!/system/bin/sh
# WiFi 5GHz Hotspot Watcher Service
# Disables 5GHz when hotspot is active, restores when inactive
# Uses event-driven approach via Android broadcast intents (zero polling)

MODDIR=${0%/*}
MODDIR=${MODDIR%/*}
VENDOR_CFG="/vendor/etc/wifi/WCNSS_qcom_cfg.ini"
OVERLAY_CFG="$MODDIR/system/vendor/etc/wifi/WCNSS_qcom_cfg.ini"
OVERLAY_BACKUP="/data/adb/modules/wifi5ghzdisabler/.overlay_backup"
LOG_TAG="WiFi5GhzDisabler"
STATE_FILE="/data/adb/modules/wifi5ghzdisabler/.hotspot_state"

# Helper: Log messages with timestamp
log_msg() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $1" >> /data/adb/modules/wifi5ghzdisabler/service.log
}

# Helper: Get SELinux context from vendor file
get_selinux_context() {
  local file="$1"
  local context
  context=$(stat -c "%C" "$file" 2>/dev/null) || context="u:object_r:vendor_wifi_config_file:s0"
  echo "$context"
}

# Helper: Apply overlay (disable 5GHz)
apply_overlay() {
  log_msg "Applying 5GHz overlay..."
  
  mkdir -p "$(dirname "$OVERLAY_CFG")"
  
  if [ -f "$VENDOR_CFG" ]; then
    # Backup vendor original if not already done
    if [ ! -f "$OVERLAY_BACKUP" ]; then
      cp -af "$VENDOR_CFG" "$OVERLAY_BACKUP"
      log_msg "Backed up vendor file to $OVERLAY_BACKUP"
    fi
    
    # Copy vendor file to overlay location
    cp -af "$VENDOR_CFG" "$OVERLAY_CFG"
    
    # Modify BandCapability to disable 5GHz
    sed -i 's/^BandCapability=.*/BandCapability=1/g' "$OVERLAY_CFG" 2>/dev/null || \
      sed -i 's/BandCapability=0/BandCapability=1/g' "$OVERLAY_CFG" 2>/dev/null || true
    
    # Preserve ownership, permissions, and SELinux context from vendor file
    local owner=$(stat -c "%U:%G" "$VENDOR_CFG" 2>/dev/null || echo "0:0")
    local perms=$(stat -c "%a" "$VENDOR_CFG" 2>/dev/null || echo "644")
    local context=$(get_selinux_context "$VENDOR_CFG")
    
    chown $owner "$OVERLAY_CFG"
    chmod $perms "$OVERLAY_CFG"
    chcon "$context" "$OVERLAY_CFG"
    
    log_msg "Overlay applied: BandCapability set to 1 (5GHz disabled)"
    return 0
  else
    log_msg "WARNING: Vendor file not found at $VENDOR_CFG"
    return 1
  fi
}

# Helper: Remove overlay (restore original)
remove_overlay() {
  log_msg "Removing 5GHz overlay..."
  
  if [ -f "$OVERLAY_CFG" ]; then
    rm -f "$OVERLAY_CFG"
    log_msg "Overlay file removed"
    return 0
  fi
  return 0
}

# Helper: Restart WiFi stack to apply changes
restart_wifi_stack() {
  log_msg "Restarting WiFi stack..."
  
  # Stop WiFi services
  cmd wifi set-wifi-enabled 0 2>/dev/null || true
  sleep 2
  
  # Restart wpa_supplicant and hostapd
  pkill -f "wpa_supplicant" || true
  pkill -f "hostapd" || true
  sleep 1
  
  # Re-enable WiFi
  cmd wifi set-wifi-enabled 1 2>/dev/null || true
  sleep 2
  
  log_msg "WiFi stack restarted"
}

# Helper: Handle hotspot state change
handle_hotspot_change() {
  local new_state="$1"
  local old_state=""
  
  # Read previous state
  if [ -f "$STATE_FILE" ]; then
    old_state=$(cat "$STATE_FILE")
  fi
  
  # Only act if state actually changed
  if [ "$new_state" != "$old_state" ]; then
    log_msg "Hotspot state changed: $old_state -> $new_state"
    
    if [ "$new_state" = "on" ]; then
      apply_overlay && restart_wifi_stack
    else
      remove_overlay && restart_wifi_stack
    fi
    
    echo "$new_state" > "$STATE_FILE"
  fi
}

# Initialize state file
log_msg "Hotspot watcher service starting (event-driven mode)..."
echo "off" > "$STATE_FILE"

# Monitor logcat for hotspot state changes via broadcast intents
# Filters:
# - android.net.wifi.WIFI_AP_STATE_CHANGED (when hotspot state changes)
# - com.android.server.wifi (WiFi service logs)
logcat -b main -v brief 2>/dev/null | while read line; do
  # Look for hotspot enabled (mApEnabled=true / WIFI_AP_STATE_ENABLED)
  if echo "$line" | grep -qiE "(mApEnabled|WIFI_AP_STATE_ENABLED|softap.*enabled)"; then
    handle_hotspot_change "on"
  # Look for hotspot disabled (mApEnabled=false / WIFI_AP_STATE_DISABLED)
  elif echo "$line" | grep -qiE "(mApEnabled.*false|WIFI_AP_STATE_DISABLED|softap.*disabled)"; then
    handle_hotspot_change "off"
  fi
done &

# Fallback: Monitor /data/misc/wifi/hostapd_control for active AP
# This catches state if logcat filtering fails
(
  while true; do
    sleep 10
    
    # Check if hostapd is running (softAP active)
    if pgrep -f "hostapd" > /dev/null 2>&1; then
      current_state="on"
    else
      current_state="off"
    fi
    
    # Read stored state
    if [ -f "$STATE_FILE" ]; then
      stored_state=$(cat "$STATE_FILE")
    else
      stored_state="off"
    fi
    
    # If mismatch, handle change (rare fallback)
    if [ "$current_state" != "$stored_state" ]; then
      log_msg "Fallback: Detected hotspot state mismatch (logcat may have missed it)"
      handle_hotspot_change "$current_state"
    fi
  done
) &

wait
