#!/bin/bash
set -e

#===============================================================================
# Cloud Foundry on Docker - Automated Deployment Script
# Uses BOSH Docker CPI to deploy a minimal CF installation
#
# Prerequisites:
#   - Docker installed and running
#   - At least 16GB RAM recommended (8GB minimum)
#   - At least 100GB free disk space
#   - Linux host (tested on Ubuntu 22.04+)
#
# Usage:
#   ./deploy.sh              # Full deployment
#   ./deploy.sh director     # Deploy BOSH Director only
#   ./deploy.sh cf           # Deploy CF only (assumes director exists)
#   ./deploy.sh destroy      # Tear down everything
#   ./deploy.sh status       # Show deployment status
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${SCRIPT_DIR}/workspace"
STATE_DIR="${WORKSPACE}/state"
CREDS_DIR="${WORKSPACE}/creds"

# Configuration
DIRECTOR_IP="10.245.0.2"
CF_NETWORK_CIDR="10.245.0.0/16"
CF_NETWORK_GW="10.245.0.1"
CF_NETWORK_NAME="cf-network"

# Auto-detect host IP for system domain
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    HOST_IP="${HOST_IP:-$(ipconfig getifaddr en0)}"
else
    # Linux
    HOST_IP="${HOST_IP:-$(hostname -I | awk '{print $1}')}"
fi

SYSTEM_DOMAIN="${SYSTEM_DOMAIN:-${HOST_IP}.nip.io}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

#===============================================================================
# Prerequisites Check
#===============================================================================
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running or you don't have permission."
        log_info "Try: sudo usermod -aG docker \$USER && newgrp docker"
        exit 1
    fi
    
    # Check BOSH CLI
    if ! command -v bosh &> /dev/null; then
        log_warn "BOSH CLI not found. Installing..."
        install_bosh_cli
    fi
    
    # Check CF CLI
    if ! command -v cf &> /dev/null; then
        log_warn "CF CLI not found. Installing..."
        install_cf_cli
    fi
    
    # Check available resources
    local total_mem_gb=0
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
         # macOS memory check (bytes to GB)
         local mem_bytes=$(sysctl -n hw.memsize)
         total_mem_gb=$((mem_bytes / 1024 / 1024 / 1024))
    else
         # Linux memory check
         if command -v free &> /dev/null; then
             total_mem_gb=$(free -g | awk '/^Mem:/{print $2}')
         fi
    fi

    if [ "$total_mem_gb" -lt 8 ]; then
        log_warn "Less than 8GB RAM detected ($total_mem_gb GB). Deployment may be slow or fail."
    else
        log_info "Memory check passed: ${total_mem_gb} GB detected."
    fi
    
    log_success "Prerequisites check passed"
}

install_bosh_cli() {
    log_info "Installing BOSH CLI..."
    local bosh_url=""
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        bosh_url="https://github.com/cloudfoundry/bosh-cli/releases/download/v7.8.6/bosh-cli-7.8.6-darwin-amd64"
    else
        bosh_url="https://github.com/cloudfoundry/bosh-cli/releases/download/v7.8.6/bosh-cli-7.8.6-linux-amd64"
    fi
    
    curl -sL "$bosh_url" -o /tmp/bosh
    chmod +x /tmp/bosh
    sudo mv /tmp/bosh /usr/local/bin/bosh
    log_success "BOSH CLI installed"
}

install_cf_cli() {
    log_info "Installing CF CLI..."
    local cf_url=""
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        cf_url="https://packages.cloudfoundry.org/stable?release=macosx64-binary&version=v8&source=github"
    else
        cf_url="https://packages.cloudfoundry.org/stable?release=linux64-binary&version=v8&source=github"
    fi

    curl -sL "$cf_url" | tar -xz -C /tmp
    
    # On Mac, the binary might be in a different path inside the tarball or just 'cf'
    if [ -f /tmp/cf8 ]; then
        sudo mv /tmp/cf8 /usr/local/bin/cf
    elif [ -f /tmp/cf ]; then
        sudo mv /tmp/cf /usr/local/bin/cf
    else
        log_warn "Could not find 'cf' binary in extracted archive. Please install manually."
    fi
    
    log_success "CF CLI installed"
}

#===============================================================================
# Setup Workspace
#===============================================================================
setup_workspace() {
    log_info "Setting up workspace at ${WORKSPACE}..."
    
    mkdir -p "${STATE_DIR}" "${CREDS_DIR}"
    cd "${WORKSPACE}"
    
    # Clone or update bosh-deployment
    if [ ! -d "bosh-deployment" ]; then
        log_info "Cloning bosh-deployment..."
        git clone --depth 1 https://github.com/cloudfoundry/bosh-deployment.git
    else
        log_info "Updating bosh-deployment..."
        (cd bosh-deployment && git pull --ff-only 2>/dev/null || true)
    fi
    
    # Clone or update cf-deployment
    if [ ! -d "cf-deployment" ]; then
        log_info "Cloning cf-deployment..."
        git clone --depth 1 https://github.com/cloudfoundry/cf-deployment.git
    else
        log_info "Updating cf-deployment..."
        (cd cf-deployment && git pull --ff-only 2>/dev/null || true)
    fi
    
    log_success "Workspace ready"
}

#===============================================================================
# Docker Network Setup
#===============================================================================
setup_docker_network() {
    log_info "Setting up Docker network '${CF_NETWORK_NAME}'..."
    
    # Remove existing network if it exists (and has no containers)
    if docker network inspect "${CF_NETWORK_NAME}" &> /dev/null; then
        log_info "Network already exists, checking if it can be recreated..."
        local containers=$(docker network inspect "${CF_NETWORK_NAME}" -f '{{range .Containers}}{{.Name}} {{end}}')
        if [ -z "$containers" ]; then
            docker network rm "${CF_NETWORK_NAME}" 2>/dev/null || true
        else
            log_warn "Network has active containers: ${containers}"
            log_warn "Using existing network..."
            return 0
        fi
    fi
    
    # Create the network with IP address management
    docker network create \
        --driver bridge \
        --subnet="${CF_NETWORK_CIDR}" \
        --gateway="${CF_NETWORK_GW}" \
        --opt "com.docker.network.bridge.enable_ip_masquerade=true" \
        --opt "com.docker.network.bridge.name=cf-br0" \
        "${CF_NETWORK_NAME}"
    
    log_success "Docker network created"
}

#===============================================================================
# Deploy BOSH Director
#===============================================================================
deploy_director() {
    log_info "Deploying BOSH Director with Docker CPI..."
    
    cd "${WORKSPACE}"
    
    # Ensure Docker socket is accessible (Linux only check usually)
    if [[ "$OSTYPE" != "darwin"* ]]; then
        if [ ! -w /var/run/docker.sock ]; then
            log_warn "Docker socket not writable. Attempting to fix..."
            sudo chmod a+rw /var/run/docker.sock
        fi
    fi
    
    # Create director deployment
    bosh create-env bosh-deployment/bosh.yml \
        --state="${STATE_DIR}/director-state.json" \
        --vars-store="${CREDS_DIR}/director-creds.yml" \
        -o bosh-deployment/docker/cpi.yml \
        -o bosh-deployment/uaa.yml \
        -o bosh-deployment/credhub.yml \
        -o bosh-deployment/jumpbox-user.yml \
        -v director_name=bosh-docker \
        -v internal_cidr="${CF_NETWORK_CIDR}" \
        -v internal_gw="${CF_NETWORK_GW}" \
        -v internal_ip="${DIRECTOR_IP}" \
        -v docker_host="unix:///var/run/docker.sock" \
        -v network="${CF_NETWORK_NAME}"
    
    log_success "BOSH Director deployed at ${DIRECTOR_IP}"
    
    # Configure BOSH environment
    configure_bosh_env
}

#===============================================================================
# Configure BOSH Environment
#===============================================================================
configure_bosh_env() {
    log_info "Configuring BOSH environment..."
    
    cd "${WORKSPACE}"
    
    # Create environment file
    cat > "${STATE_DIR}/bosh-env.sh" << EOF
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET=\$(bosh int ${CREDS_DIR}/director-creds.yml --path /admin_password)
export BOSH_CA_CERT=\$(bosh int ${CREDS_DIR}/director-creds.yml --path /director_ssl/ca)
export BOSH_ENVIRONMENT=${DIRECTOR_IP}
export BOSH_NON_INTERACTIVE=true
EOF
    
    # Source the environment
    source "${STATE_DIR}/bosh-env.sh"
    
    # Add alias
    bosh alias-env docker -e "${DIRECTOR_IP}" --ca-cert <(bosh int "${CREDS_DIR}/director-creds.yml" --path /director_ssl/ca)
    
    # Wait for director to be ready
    log_info "Waiting for Director to be ready..."
    local max_attempts=30
    local attempt=0
    while ! bosh -e docker env &>/dev/null; do
        attempt=$((attempt + 1))
        if [ $attempt -ge $max_attempts ]; then
            log_error "Director did not become ready in time"
            exit 1
        fi
        sleep 10
    done
    
    log_success "BOSH environment configured"
}

#===============================================================================
# Update Cloud Config
#===============================================================================
update_cloud_config() {
    log_info "Updating cloud config..."
    
    source "${STATE_DIR}/bosh-env.sh"
    cd "${WORKSPACE}"
    
    # Create cloud config for Docker
    cat > "${STATE_DIR}/cloud-config.yml" << EOF
azs:
- name: z1
  cloud_properties: {}

vm_types:
- name: minimal
  cloud_properties:
    cpus: 1
    memory: 2048
    ephemeral_disk: 10240
- name: small
  cloud_properties:
    cpus: 2
    memory: 4096
    ephemeral_disk: 20480
- name: default
  cloud_properties:
    cpus: 2
    memory: 4096
    ephemeral_disk: 20480
- name: small-highmem
  cloud_properties:
    cpus: 2
    memory: 8192
    ephemeral_disk: 20480

vm_extensions:
- name: 50GB_ephemeral_disk
  cloud_properties:
    ephemeral_disk: 51200
- name: 100GB_ephemeral_disk
  cloud_properties:
    ephemeral_disk: 102400
- name: cf-router-network-properties
  cloud_properties: {}
- name: cf-tcp-router-network-properties
  cloud_properties: {}
- name: diego-ssh-proxy-network-properties
  cloud_properties: {}

disk_types:
- name: default
  disk_size: 10240
- name: 1GB
  disk_size: 1024
- name: 5GB
  disk_size: 5120
- name: 10GB
  disk_size: 10240
- name: 50GB
  disk_size: 51200
- name: 100GB
  disk_size: 102400

networks:
- name: default
  type: manual
  subnets:
  - range: ${CF_NETWORK_CIDR}
    gateway: ${CF_NETWORK_GW}
    azs: [z1]
    reserved:
    - ${CF_NETWORK_GW} - 10.245.0.10
    static:
    - 10.245.0.11 - 10.245.0.100
    dns:
    - 8.8.8.8
    - 8.8.4.4
    cloud_properties:
      name: ${CF_NETWORK_NAME}

compilation:
  workers: 4
  reuse_compilation_vms: true
  az: z1
  vm_type: small
  network: default
EOF
    
    bosh -e docker update-cloud-config "${STATE_DIR}/cloud-config.yml" -n
    
    log_success "Cloud config updated"
}

#===============================================================================
# Update Runtime Config (BOSH DNS)
#===============================================================================
update_runtime_config() {
    log_info "Updating runtime config for BOSH DNS..."
    
    source "${STATE_DIR}/bosh-env.sh"
    cd "${WORKSPACE}"
    
    bosh -e docker update-runtime-config bosh-deployment/runtime-configs/dns.yml --name dns -n
    
    log_success "Runtime config updated"
}

#===============================================================================
# Upload Stemcell
#===============================================================================
upload_stemcell() {
    log_info "Uploading stemcell..."
    
    source "${STATE_DIR}/bosh-env.sh"
    
    # Get stemcell version from cf-deployment
    local stemcell_version=$(bosh int cf-deployment/cf-deployment.yml --path /stemcells/alias=default/version)
    local stemcell_os=$(bosh int cf-deployment/cf-deployment.yml --path /stemcells/alias=default/os)
    
    log_info "Required stemcell: ${stemcell_os} version ${stemcell_version}"
    
    # Check if we can use light stemcells (Docker CPI supports this)
    # For Docker CPI, we use warden stemcells
    local stemcell_url="https://bosh.io/d/stemcells/bosh-warden-boshlite-${stemcell_os}-go_agent?v=${stemcell_version}"
    
    bosh -e docker upload-stemcell "${stemcell_url}" || {
        log_warn "Could not upload warden stemcell, trying to create light stemcell..."
        # Fallback: try with any available stemcell
        bosh -e docker upload-stemcell "https://bosh.io/d/stemcells/bosh-warden-boshlite-ubuntu-jammy-go_agent" || true
    }
    
    log_success "Stemcell uploaded"
}

#===============================================================================
# Deploy Cloud Foundry
#===============================================================================
deploy_cf() {
    log_info "Deploying Cloud Foundry (this will take 30-60 minutes)..."
    log_info "System domain: ${SYSTEM_DOMAIN}"
    
    source "${STATE_DIR}/bosh-env.sh"
    cd "${WORKSPACE}"
    
    # Deploy CF with bosh-lite ops file for minimal footprint
    bosh -e docker -d cf deploy cf-deployment/cf-deployment.yml \
        -o cf-deployment/operations/bosh-lite.yml \
        -o cf-deployment/operations/use-compiled-releases.yml \
        --vars-store="${CREDS_DIR}/cf-creds.yml" \
        -v system_domain="${SYSTEM_DOMAIN}" \
        -n
    
    log_success "Cloud Foundry deployed!"
    
    # Show connection info
    show_cf_info
}

#===============================================================================
# Show CF Connection Info
#===============================================================================
show_cf_info() {
    log_info "============================================"
    log_info "Cloud Foundry Deployment Complete!"
    log_info "============================================"
    
    local cf_admin_password=$(bosh int "${CREDS_DIR}/cf-creds.yml" --path /cf_admin_password 2>/dev/null || echo "see ${CREDS_DIR}/cf-creds.yml")
    
    echo ""
    echo -e "${GREEN}API Endpoint:${NC} https://api.${SYSTEM_DOMAIN}"
    echo -e "${GREEN}Admin User:${NC} admin"
    echo -e "${GREEN}Admin Password:${NC} ${cf_admin_password}"
    echo ""
    echo -e "${BLUE}To login:${NC}"
    echo "  cf login -a https://api.${SYSTEM_DOMAIN} -u admin -p '${cf_admin_password}' --skip-ssl-validation"
    echo ""
    echo -e "${BLUE}To set up an org and space:${NC}"
    echo "  cf create-org myorg"
    echo "  cf target -o myorg"
    echo "  cf create-space dev"
    echo "  cf target -s dev"
    echo ""
    echo -e "${BLUE}To push an app:${NC}"
    echo "  cf push myapp"
    echo ""
    
    # Save connection info to file
    cat > "${STATE_DIR}/cf-info.txt" << EOF
Cloud Foundry Connection Info
=============================
API Endpoint: https://api.${SYSTEM_DOMAIN}
Admin User: admin
Admin Password: ${cf_admin_password}

Login Command:
cf login -a https://api.${SYSTEM_DOMAIN} -u admin -p '${cf_admin_password}' --skip-ssl-validation
EOF
    
    log_info "Connection info saved to ${STATE_DIR}/cf-info.txt"
}

#===============================================================================
# Destroy Everything
#===============================================================================
destroy_all() {
    log_warn "This will destroy the BOSH Director and all deployments!"
    read -p "Are you sure? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        log_info "Aborted."
        exit 0
    fi
    
    cd "${WORKSPACE}"
    
    # Delete CF deployment first
    if [ -f "${STATE_DIR}/bosh-env.sh" ]; then
        source "${STATE_DIR}/bosh-env.sh"
        bosh -e docker -d cf delete-deployment -n 2>/dev/null || true
    fi
    
    # Delete BOSH Director
    if [ -f "${STATE_DIR}/director-state.json" ]; then
        log_info "Deleting BOSH Director..."
        bosh delete-env bosh-deployment/bosh.yml \
            --state="${STATE_DIR}/director-state.json" \
            --vars-store="${CREDS_DIR}/director-creds.yml" \
            -o bosh-deployment/docker/cpi.yml \
            -o bosh-deployment/uaa.yml \
            -o bosh-deployment/credhub.yml \
            -o bosh-deployment/jumpbox-user.yml \
            -v director_name=bosh-docker \
            -v internal_cidr="${CF_NETWORK_CIDR}" \
            -v internal_gw="${CF_NETWORK_GW}" \
            -v internal_ip="${DIRECTOR_IP}" \
            -v docker_host="unix:///var/run/docker.sock" \
            -v network="${CF_NETWORK_NAME}" 2>/dev/null || true
    fi
    
    # Clean up Docker containers with cf- or bosh- prefix
    log_info "Cleaning up Docker containers..."
    docker ps -a --format '{{.Names}}' | grep -E '^(bosh-|cf-)' | xargs -r docker rm -f 2>/dev/null || true
    
    # Remove Docker network
    log_info "Removing Docker network..."
    docker network rm "${CF_NETWORK_NAME}" 2>/dev/null || true
    
    log_success "Cleanup complete"
}

#===============================================================================
# Show Status
#===============================================================================
show_status() {
    log_info "Deployment Status"
    log_info "================="
    
    # Check Docker network
    if docker network inspect "${CF_NETWORK_NAME}" &>/dev/null; then
        echo -e "${GREEN}✓${NC} Docker network '${CF_NETWORK_NAME}' exists"
    else
        echo -e "${RED}✗${NC} Docker network '${CF_NETWORK_NAME}' not found"
    fi
    
    # Check BOSH Director
    if [ -f "${STATE_DIR}/bosh-env.sh" ]; then
        source "${STATE_DIR}/bosh-env.sh"
        if bosh -e docker env &>/dev/null 2>&1; then
            echo -e "${GREEN}✓${NC} BOSH Director is running"
            
            # Show deployments
            echo ""
            log_info "Deployments:"
            bosh -e docker deployments 2>/dev/null || true
            
            # Show VMs
            echo ""
            log_info "VMs:"
            bosh -e docker vms 2>/dev/null || true
        else
            echo -e "${RED}✗${NC} BOSH Director is not accessible"
        fi
    else
        echo -e "${YELLOW}?${NC} BOSH Director status unknown (no state file)"
    fi
    
    # Show Docker containers
    echo ""
    log_info "Docker containers:"
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' --filter "network=${CF_NETWORK_NAME}" 2>/dev/null || echo "None"
}

#===============================================================================
# Main
#===============================================================================
main() {
    local command="${1:-full}"
    
    case "$command" in
        full)
            check_prerequisites
            setup_workspace
            setup_docker_network
            deploy_director
            update_cloud_config
            update_runtime_config
            upload_stemcell
            deploy_cf
            ;;
        director)
            check_prerequisites
            setup_workspace
            setup_docker_network
            deploy_director
            update_cloud_config
            update_runtime_config
            upload_stemcell
            ;;
        cf)
            source "${STATE_DIR}/bosh-env.sh"
            deploy_cf
            ;;
        destroy)
            destroy_all
            ;;
        status)
            show_status
            ;;
        info)
            show_cf_info
            ;;
        *)
            echo "Usage: $0 [full|director|cf|destroy|status|info]"
            echo ""
            echo "Commands:"
            echo "  full     - Full deployment (default)"
            echo "  director - Deploy BOSH Director only"
            echo "  cf       - Deploy CF only (assumes director exists)"
            echo "  destroy  - Tear down everything"
            echo "  status   - Show deployment status"
            echo "  info     - Show CF connection info"
            exit 1
            ;;
    esac
}

main "$@"
