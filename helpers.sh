#!/bin/bash
#===============================================================================
# CF Docker Deployment - Helper Commands
# Source this file to get useful functions for managing your CF deployment
#
# Usage: source helpers.sh
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/workspace/state"
CREDS_DIR="${SCRIPT_DIR}/workspace/creds"

# Load BOSH environment
load_bosh_env() {
    if [ -f "${STATE_DIR}/bosh-env.sh" ]; then
        source "${STATE_DIR}/bosh-env.sh"
        echo "BOSH environment loaded. Target: ${BOSH_ENVIRONMENT}"
    else
        echo "Error: BOSH environment not found. Run ./deploy.sh first."
        return 1
    fi
}

# Login to CF as admin
cf_login() {
    local system_domain=$(grep "API Endpoint" "${STATE_DIR}/cf-info.txt" 2>/dev/null | sed 's/.*api\.//' || echo "")
    local password=$(bosh int "${CREDS_DIR}/cf-creds.yml" --path /cf_admin_password 2>/dev/null)
    
    if [ -z "$system_domain" ] || [ -z "$password" ]; then
        echo "Error: CF credentials not found. Is CF deployed?"
        return 1
    fi
    
    cf login -a "https://api.${system_domain}" -u admin -p "${password}" --skip-ssl-validation
}

# Quick setup: create org, space, and target
cf_setup() {
    local org="${1:-dev-org}"
    local space="${2:-dev}"
    
    cf_login || return 1
    
    echo "Creating org: ${org}"
    cf create-org "${org}" 2>/dev/null || true
    cf target -o "${org}"
    
    echo "Creating space: ${space}"
    cf create-space "${space}" 2>/dev/null || true
    cf target -s "${space}"
    
    echo "Ready to push apps!"
}

# List all BOSH VMs with status
bosh_vms() {
    load_bosh_env || return 1
    bosh -e docker vms --vitals
}

# SSH into a CF VM
bosh_ssh() {
    local instance="${1}"
    if [ -z "$instance" ]; then
        echo "Usage: bosh_ssh <instance>"
        echo "Example: bosh_ssh router/0"
        load_bosh_env && bosh -e docker -d cf vms
        return 1
    fi
    
    load_bosh_env || return 1
    bosh -e docker -d cf ssh "${instance}"
}

# Tail logs from a CF VM
bosh_logs() {
    local instance="${1}"
    if [ -z "$instance" ]; then
        echo "Usage: bosh_logs <instance>"
        echo "Example: bosh_logs router/0"
        load_bosh_env && bosh -e docker -d cf vms
        return 1
    fi
    
    load_bosh_env || return 1
    bosh -e docker -d cf logs "${instance}" --follow
}

# Show recent BOSH tasks
bosh_tasks() {
    load_bosh_env || return 1
    bosh -e docker tasks --recent=10
}

# Cancel a running BOSH task
bosh_cancel() {
    local task_id="${1}"
    if [ -z "$task_id" ]; then
        echo "Usage: bosh_cancel <task_id>"
        bosh_tasks
        return 1
    fi
    
    load_bosh_env || return 1
    bosh -e docker cancel-task "${task_id}"
}

# Restart all CF VMs (recreate)
cf_restart_all() {
    echo "This will recreate all CF VMs. Continue? (yes/no)"
    read -r confirm
    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        return 0
    fi
    
    load_bosh_env || return 1
    bosh -e docker -d cf recreate
}

# Show Docker containers for CF
docker_cf_containers() {
    echo "CF-related Docker containers:"
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' --filter "network=cf-network"
}

# Clean up stopped containers
docker_cleanup() {
    echo "Removing stopped containers..."
    docker container prune -f
    echo "Removing unused images..."
    docker image prune -f
    echo "Removing unused volumes..."
    docker volume prune -f
}

# Get CF admin password
cf_password() {
    bosh int "${CREDS_DIR}/cf-creds.yml" --path /cf_admin_password 2>/dev/null || echo "Not found"
}

# Get BOSH admin password
bosh_password() {
    bosh int "${CREDS_DIR}/director-creds.yml" --path /admin_password 2>/dev/null || echo "Not found"
}

# Export CredHub credentials for CF
cf_credhub_login() {
    load_bosh_env || return 1
    
    export CREDHUB_SERVER="https://${BOSH_ENVIRONMENT}:8844"
    export CREDHUB_CLIENT="credhub-admin"
    export CREDHUB_SECRET=$(bosh int "${CREDS_DIR}/director-creds.yml" --path /credhub_admin_client_secret)
    export CREDHUB_CA_CERT=$(bosh int "${CREDS_DIR}/director-creds.yml" --path /credhub_tls/ca)
    
    echo "CredHub environment configured. Run: credhub login"
}

# Print all available helper functions
cf_help() {
    cat << 'EOF'
Available helper functions:

  load_bosh_env         - Load BOSH environment variables
  cf_login              - Login to CF as admin
  cf_setup [org] [space] - Create org/space and target (defaults: dev-org/dev)
  cf_password           - Show CF admin password
  cf_credhub_login      - Configure CredHub environment
  
  bosh_vms              - List all BOSH VMs with vitals
  bosh_ssh <instance>   - SSH into a VM (e.g., bosh_ssh router/0)
  bosh_logs <instance>  - Tail logs from a VM
  bosh_tasks            - Show recent BOSH tasks
  bosh_cancel <task_id> - Cancel a running task
  bosh_password         - Show BOSH admin password
  
  cf_restart_all        - Recreate all CF VMs
  
  docker_cf_containers  - List CF Docker containers
  docker_cleanup        - Clean up Docker resources

Usage:
  source helpers.sh
  cf_setup              # Quick setup with default org/space
  cf push myapp         # Push your app
EOF
}

# Auto-load BOSH env if available
if [ -f "${STATE_DIR}/bosh-env.sh" ]; then
    source "${STATE_DIR}/bosh-env.sh" 2>/dev/null
fi

echo "CF Docker helpers loaded. Run 'cf_help' for available commands."
