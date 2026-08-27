#!/bin/bash
set -e

# Interactive Bastion Host Deployment Script
# This script guides users through deploying a bastion host on Crusoe Cloud

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform"
TFVARS_FILE="$TERRAFORM_DIR/terraform.tfvars"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Print functions
print_header() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}                  ${BLUE}CRUSOE BASTION HOST DEPLOYMENT${NC}                        ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "${CYAN}ℹ${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    print_section "Checking Prerequisites"
    
    local all_good=true
    
    # Check Terraform
    if command -v terraform &> /dev/null; then
        TERRAFORM_VERSION=$(terraform version -json | grep -o '"terraform_version":"[^"]*' | cut -d'"' -f4)
        print_success "Terraform installed (version $TERRAFORM_VERSION)"
    else
        print_error "Terraform is not installed"
        print_info "Install from: https://www.terraform.io/downloads"
        all_good=false
    fi
    
    # Check Crusoe CLI
    if command -v crusoe &> /dev/null; then
        print_success "Crusoe CLI installed"
    else
        print_warning "Crusoe CLI not found (optional but recommended)"
        print_info "Install from: https://docs.crusoecloud.com/quickstart/installing-the-cli/"
    fi
    
    # Check jq
    if command -v jq &> /dev/null; then
        print_success "jq installed"
    else
        print_warning "jq not found (optional, used for JSON parsing)"
    fi
    
    # Check SSH
    if command -v ssh &> /dev/null; then
        print_success "SSH client available"
    else
        print_error "SSH client not found"
        all_good=false
    fi
    
    if [ "$all_good" = false ]; then
        echo ""
        print_error "Please install missing prerequisites before continuing"
        exit 1
    fi
    
    echo ""
}

# Prompt for input with validation
prompt_input() {
    local prompt="$1"
    local var_name="$2"
    local default="$3"
    local validation="$4"
    
    while true; do
        if [ -n "$default" ]; then
            printf "\033[0;36m%s\033[0m [%s]: " "$prompt" "$default"
            read input
            input="${input:-$default}"
        else
            printf "\033[0;36m%s\033[0m: " "$prompt"
            read input
        fi
        
        # Validate input if validation function provided
        if [ -n "$validation" ]; then
            if $validation "$input"; then
                eval "$var_name='$input'"
                break
            fi
        else
            if [ -n "$input" ]; then
                eval "$var_name='$input'"
                break
            else
                print_error "This field is required"
            fi
        fi
    done
}

# Validation functions
validate_project_id() {
    if [[ "$1" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
        return 0
    else
        print_error "Invalid project ID format (expected UUID format)"
        return 1
    fi
}

validate_location() {
    if [ -n "$1" ]; then
        return 0
    else
        print_error "Location is required"
        return 1
    fi
}

validate_ssh_key() {
    if [ -f "$1" ]; then
        if [[ $(cat "$1") =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp) ]]; then
            return 0
        else
            print_error "File does not contain a valid SSH public key"
            return 1
        fi
    else
        print_error "SSH key file not found: $1"
        return 1
    fi
}

validate_cidr() {
    if [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        return 0
    elif [ "$1" = "done" ]; then
        return 0
    else
        print_error "Invalid CIDR format (e.g., 203.0.113.0/24)"
        return 1
    fi
}

# Fetch available VPC networks
fetch_vpc_networks() {
    print_info "Fetching available VPC networks..."
    
    if ! command -v crusoe &> /dev/null; then
        print_warning "Crusoe CLI not installed. Using default VPC network name."
        VPC_NETWORK="default"
        return
    fi
    
    # Fetch VPC networks using Crusoe CLI
    local vpc_json
    vpc_json=$(crusoe networking vpc-networks list --project-id "$PROJECT_ID" --json 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$vpc_json" ]; then
        print_warning "Could not fetch VPC networks. Using default."
        VPC_NETWORK="default"
        return
    fi
    
    # Parse VPC names using jq if available
    if command -v jq &> /dev/null; then
        local vpc_names
        vpc_names=$(echo "$vpc_json" | jq -r '.[].name' 2>/dev/null)
        
        if [ -z "$vpc_names" ]; then
            print_warning "No VPC networks found. Using default."
            VPC_NETWORK="default"
            return
        fi
        
        # Display available VPCs
        echo ""
        print_info "Available VPC Networks:"
        local idx=1
        local vpc_array=()
        while IFS= read -r vpc; do
            echo "  $idx) $vpc"
            vpc_array+=("$vpc")
            ((idx++))
        done <<< "$vpc_names"
        
        echo ""
        printf "\033[0;36mSelect VPC network\033[0m [1]: "
        read vpc_choice
        vpc_choice="${vpc_choice:-1}"
        
        # Validate selection
        if [[ "$vpc_choice" =~ ^[0-9]+$ ]] && [ "$vpc_choice" -ge 1 ] && [ "$vpc_choice" -le "${#vpc_array[@]}" ]; then
            VPC_NETWORK="${vpc_array[$((vpc_choice-1))]}"
            print_success "Selected VPC: $VPC_NETWORK"
        else
            print_warning "Invalid selection. Using first VPC: ${vpc_array[0]}"
            VPC_NETWORK="${vpc_array[0]}"
        fi
    else
        print_warning "jq not installed. Using default VPC network name."
        VPC_NETWORK="default"
    fi
}

# Collect configuration
collect_configuration() {
    print_section "Configuration"
    
    echo "Let's configure your bastion host deployment."
    echo ""
    
    # Project ID - try to auto-detect from CLI
    print_info "Detecting your Crusoe project..."
    local detected_project=""
    local detected_project_id=""
    local detected_project_name=""
    
    if command -v crusoe &> /dev/null; then
        # Get the default project from CLI config (could be name or ID)
        detected_project=$(crusoe config get default_project 2>/dev/null || echo "")
        
        if [ -n "$detected_project" ]; then
            # Check if it's already a UUID
            if [[ "$detected_project" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
                detected_project_id="$detected_project"
            else
                # It's a project name, try to get the ID
                detected_project_name="$detected_project"
                detected_project_id=$(crusoe projects list --json 2>/dev/null | jq -r --arg name "$detected_project" '.[] | select(.name == $name) | .id' 2>/dev/null || echo "")
            fi
        fi
    fi
    
    if [ -n "$detected_project_id" ] && [[ "$detected_project_id" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
        if [ -n "$detected_project_name" ]; then
            print_success "Detected project: $detected_project_name ($detected_project_id)"
        else
            print_success "Detected project: $detected_project_id"
        fi
        echo ""
        echo "  1) Use detected project"
        echo "  2) Enter a different project ID"
        echo ""
        printf "\033[0;36mSelect option\033[0m [1]: "
        read project_choice
        project_choice="${project_choice:-1}"
        
        if [ "$project_choice" = "1" ]; then
            PROJECT_ID="$detected_project_id"
        else
            prompt_input "Project ID" PROJECT_ID "" validate_project_id
        fi
    else
        print_warning "Could not auto-detect project ID"
        prompt_input "Project ID" PROJECT_ID "" validate_project_id
    fi
    
    # Fetch and select VPC network
    fetch_vpc_networks
    
    # Location
    print_info "Available locations: us-east1-a, us-central1-a, etc."
    prompt_input "Location" LOCATION "us-east1-a" validate_location
    
    # Bastion name
    prompt_input "Bastion host name" BASTION_NAME "bastion-host"
    
    # Instance type
    print_info "Recommended: c1a.2x (2 vCPU, 4GB RAM) for bastion hosts"
    prompt_input "Instance type" INSTANCE_TYPE "c1a.2x"
    
    # SSH key
    echo ""
    print_info "Path to your SSH public key file"
    print_info "Common locations: ~/.ssh/id_rsa.pub, ~/.ssh/id_ed25519.pub"
    
    # Try to find SSH keys
    if [ -f ~/.ssh/id_ed25519.pub ]; then
        DEFAULT_KEY=~/.ssh/id_ed25519.pub
    elif [ -f ~/.ssh/id_rsa.pub ]; then
        DEFAULT_KEY=~/.ssh/id_rsa.pub
    else
        DEFAULT_KEY=""
    fi
    
    prompt_input "SSH public key path" SSH_KEY_PATH "$DEFAULT_KEY" validate_ssh_key
    SSH_PUBLIC_KEY=$(cat "$SSH_KEY_PATH")
    
    # Allowed SSH CIDRs
    echo ""
    print_info "Restrict SSH access to specific IP ranges (CIDR notation)"
    print_warning "Using 0.0.0.0/0 allows access from anywhere (not recommended for production)"
    
    read -p $'\033[0;36mRestrict SSH access to specific IPs?\033[0m (y/n) [n]: ' RESTRICT_SSH
    RESTRICT_SSH="${RESTRICT_SSH:-n}"
    
    if [[ "$RESTRICT_SSH" =~ ^[Yy] ]]; then
        ALLOWED_CIDRS=""
        while true; do
            prompt_input "Enter CIDR (or 'done' to finish)" CIDR "" validate_cidr
            if [ "$CIDR" = "done" ]; then
                break
            fi
            if [ -z "$ALLOWED_CIDRS" ]; then
                ALLOWED_CIDRS="\"$CIDR\""
            else
                ALLOWED_CIDRS="$ALLOWED_CIDRS, \"$CIDR\""
            fi
            print_success "Added: $CIDR"
        done
    else
        ALLOWED_CIDRS="\"0.0.0.0/0\""
    fi
    
    # High Availability
    echo ""
    read -p $'\033[0;36mEnable High Availability mode (multiple bastions)?\033[0m (y/n) [n]: ' ENABLE_HA
    ENABLE_HA="${ENABLE_HA:-n}"
    
    if [[ "$ENABLE_HA" =~ ^[Yy] ]]; then
        HA_ENABLED="true"
        prompt_input "Number of bastion hosts" HA_COUNT "2"
    else
        HA_ENABLED="false"
        HA_COUNT="2"
    fi
}

# Generate terraform.tfvars
generate_tfvars() {
    print_section "Generating Configuration"
    
    cat > "$TFVARS_FILE" <<EOF
# Crusoe Bastion Host Configuration
# Generated by deploy.sh on $(date)

# Required Variables
project_id      = "$PROJECT_ID"
location        = "$LOCATION"
ssh_public_key  = "$SSH_PUBLIC_KEY"

# Instance Configuration
bastion_name    = "$BASTION_NAME"
instance_type   = "$INSTANCE_TYPE"

# Network Configuration
vpc_network       = "$VPC_NETWORK"
allowed_ssh_cidrs = [$ALLOWED_CIDRS]

# High Availability
ha_enabled = $HA_ENABLED
ha_count   = $HA_COUNT
EOF
    
    print_success "Configuration file created: $TFVARS_FILE"
}

# Display configuration summary
display_summary() {
    print_section "Configuration Summary"
    
    echo -e "${CYAN}Project:${NC}           $PROJECT_ID"
    echo -e "${CYAN}Location:${NC}          $LOCATION"
    echo -e "${CYAN}VPC Network:${NC}       $VPC_NETWORK"
    echo -e "${CYAN}Bastion Name:${NC}      $BASTION_NAME"
    echo -e "${CYAN}Instance Type:${NC}     $INSTANCE_TYPE"
    echo -e "${CYAN}SSH Key:${NC}           $SSH_KEY_PATH"
    echo -e "${CYAN}Allowed CIDRs:${NC}     $ALLOWED_CIDRS"
    echo ""
    echo -e "${CYAN}Security Features:${NC}  All enabled by default (session logging, auto-updates, fail2ban)"
    echo ""
    echo -e "${CYAN}High Availability:${NC}  $HA_ENABLED"
    if [ "$HA_ENABLED" = "true" ]; then
        echo -e "  Bastion Count:      $HA_COUNT"
    fi
    echo ""
}

# Deploy with Terraform
deploy_terraform() {
    print_section "Deploying Bastion Host"
    
    cd "$TERRAFORM_DIR"
    
    local TF_LOG_FILE="/tmp/terraform-deploy-$$.log"
    
    # Initialize Terraform (quiet)
    print_info "Initializing Terraform..."
    if terraform init -no-color > "$TF_LOG_FILE" 2>&1; then
        print_success "Terraform initialized"
    else
        print_error "Terraform initialization failed"
        echo ""
        echo -e "${RED}Error details:${NC}"
        cat "$TF_LOG_FILE"
        rm -f "$TF_LOG_FILE"
        exit 1
    fi
    
    # Validate configuration (quiet)
    print_info "Validating configuration..."
    if terraform validate -no-color >> "$TF_LOG_FILE" 2>&1; then
        print_success "Configuration valid"
    else
        print_error "Configuration validation failed"
        echo ""
        echo -e "${RED}Error details:${NC}"
        cat "$TF_LOG_FILE"
        rm -f "$TF_LOG_FILE"
        exit 1
    fi
    
    # Apply directly with auto-approve (user already confirmed config)
    print_info "Deploying bastion host (this may take 1-2 minutes)..."
    echo ""
    
    if terraform apply -auto-approve -no-color >> "$TF_LOG_FILE" 2>&1; then
        print_success "Deployment completed successfully!"
        rm -f "$TF_LOG_FILE"
    else
        print_error "Deployment failed"
        echo ""
        echo -e "${RED}Error details:${NC}"
        cat "$TF_LOG_FILE"
        rm -f "$TF_LOG_FILE"
        exit 1
    fi
}

# Display next steps
display_next_steps() {
    print_section "Deployment Complete!"
    
    cd "$TERRAFORM_DIR"
    
    # Get outputs
    BASTION_IPS=$(terraform output -json bastion_public_ips 2>/dev/null | jq -r '.[]' 2>/dev/null || echo "")
    
    if [ -n "$BASTION_IPS" ]; then
        echo ""
        print_success "Your bastion host is ready!"
        echo ""
        echo -e "${CYAN}Public IP(s):${NC}"
        echo "$BASTION_IPS" | while read ip; do
            echo "  • $ip"
        done
        echo ""
        
        FIRST_IP=$(echo "$BASTION_IPS" | head -n 1)
        
        echo -e "${CYAN}Connect to your bastion:${NC}"
        echo "  ssh $ADMIN_USERNAME@$FIRST_IP"
        echo ""
        
        echo -e "${CYAN}Connect to private instances via bastion:${NC}"
        echo "  ssh -J $ADMIN_USERNAME@$FIRST_IP user@<private-ip>"
        echo ""
        
        echo -e "${CYAN}Management scripts:${NC}"
        echo "  Add user:      $SCRIPT_DIR/scripts/add-user.sh <username> <key-file> $FIRST_IP"
        echo "  Remove user:   $SCRIPT_DIR/scripts/remove-user.sh <username> $FIRST_IP"
        echo "  View logs:     $SCRIPT_DIR/scripts/audit-logs.sh $FIRST_IP"
        echo "  Health check:  $SCRIPT_DIR/scripts/health-check.sh $FIRST_IP"
        echo ""
        
        print_info "Full deployment details:"
        echo "  terraform output -json | jq"
        echo ""
        
        print_info "For detailed documentation, see:"
        echo "  $SCRIPT_DIR/README.md"
        echo "  $SCRIPT_DIR/SECURITY.md"
    fi
    
    echo ""
    print_success "Thank you for using Crusoe Cloud!"
    echo ""
}

# Main execution
main() {
    print_header
    
    check_prerequisites
    collect_configuration
    display_summary
    
    read -p $'\033[0;36mContinue with this configuration?\033[0m (y/n) [y]: ' CONTINUE
    CONTINUE="${CONTINUE:-y}"
    
    if [[ ! "$CONTINUE" =~ ^[Yy] ]]; then
        print_warning "Deployment cancelled"
        exit 0
    fi
    
    generate_tfvars
    deploy_terraform
    display_next_steps
}

# Run main function
main
