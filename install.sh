#!/usr/bin/env bash
set -euo pipefail

##############################################
# CONFIGURATION VARIABLES
##############################################
CLUSTER_DIR="${CLUSTER_DIR:-./config}"
CLUSTER_NAME="${CLUSTER_NAME:-zenek}"
BASE_DOMAIN="${BASE_DOMAIN:-example.com}"
PULL_SECRET_FILE="${PULL_SECRET_FILE:-./pull-secret.txt}"
SSH_KEY_FILE="${SSH_KEY_FILE:-./ssh/id_rsa.pub}"

GCP_PROJECT_ID="${GCP_PROJECT_ID:-}"
GCP_REGION="${GCP_REGION:-us-central1}"

MASTER_FILE="./instances/master"
WORKER_FILE="./instances/worker"

##############################################
# COLORS & ICONS
##############################################
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
MAGENTA="\033[1;35m"
RESET="\033[0m"

INFO="💡"
SUCCESS="✅"
WARN="⚠️"
ERROR="❌"

log_info() { echo -e "${CYAN}${INFO} $1${RESET}"; }
log_success() { echo -e "${GREEN}${SUCCESS} $1${RESET}"; }
log_warn() { echo -e "${YELLOW}${WARN} $1${RESET}"; }
log_error() { echo -e "${RED}${ERROR} $1${RESET}" >&2; }

##############################################
# PRE-FLIGHT CHECKS (GCP)
##############################################
preflight_checks() {
  log_info "Checking required commands and files..."

  command -v ./openshift-install >/dev/null || { log_error "openshift-install not found"; exit 1; }
  command -v gcloud >/dev/null || { log_error "gcloud CLI not found"; exit 1; }
  command -v jq >/dev/null || { log_error "jq not found"; exit 1; }

  [[ -f "$PULL_SECRET_FILE" ]] || { log_error "Pull secret not found"; exit 1; }
  [[ -f "$SSH_KEY_FILE" ]] || { log_error "SSH key not found"; exit 1; }
  [[ -f "$MASTER_FILE" ]] || { log_error "Master instance list not found"; exit 1; }
  [[ -f "$WORKER_FILE" ]] || { log_error "Worker instance list not found"; exit 1; }

  gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q . || {
    log_error "Not authenticated to GCP. Run: gcloud init"
    exit 1
  }

  GCP_PROJECT_ID="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
  [[ -z "$GCP_PROJECT_ID" ]] && { log_error "GCP project not set"; exit 1; }

  log_success "Using GCP project: $GCP_PROJECT_ID"
  log_success "Pre-flight checks passed!"
}

##############################################
# AUTO-DETECT GCP PROJECT ID
##############################################
detect_gcp_project() {
  log_info "Detecting GCP project..."

  GCP_PROJECT_ID="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"

  [[ -z "$GCP_PROJECT_ID" ]] && {
    log_error "GCP project not set. Run 'gcloud init' or export GCP_PROJECT_ID"
    exit 1
  }

  log_success "Using GCP project: $GCP_PROJECT_ID"
}

##############################################
# AUTO-DETECT BASE DOMAIN (Cloud DNS)
##############################################
detect_base_domain() {
  log_info "Detecting base domain from Cloud DNS..."

  BASE_DOMAIN=$(gcloud dns managed-zones list \
    --project "$GCP_PROJECT_ID" \
    --filter="visibility=public" \
    --format="value(dnsName)" \
    | head -n1 | sed 's/\.$//')

  [[ -z "$BASE_DOMAIN" ]] && {
    log_error "No public Cloud DNS zones found"
    exit 1
  }

  log_success "Using base domain: $BASE_DOMAIN"
}

##############################################
# AUTO-DETECT GCP REGION
##############################################
detect_gcp_region() {
  log_info "Detecting GCP region..."

  if [[ -n "$GCP_REGION" ]]; then
    :
  else
    GCP_REGION=$(gcloud compute regions list \
      --project "$GCP_PROJECT_ID" \
      --format="value(name)" \
      | head -n1)
  fi

  [[ -z "$GCP_REGION" ]] && {
    log_error "Unable to detect GCP region"
    exit 1
  }

  log_success "Using GCP region: $GCP_REGION"
}

##############################################
# INSTANCE SELECTION (UNCHANGED)
##############################################
select_instance_type() {
  local file="$1"
  local role="$2"

  echo >&2
  echo -e "${MAGENTA}${INFO} Available ${role} machine types:${RESET}" >&2
  echo "----------------------------------------" >&2

  local i=1
  while IFS= read -r line || [[ -n "$line" ]]; do
    echo "  [$i] $line" >&2
    ((i++))
  done < "$file"

  read -rp "Choose ${role} type (default=1): " choice >&2
  [[ -z "$choice" ]] && choice=1

  local total
  total=$(grep -c '' "$file")

  [[ "$choice" =~ ^[0-9]+$ ]] || exit 1
  (( choice >=1 && choice <= total )) || exit 1

  local selected
  selected=$(sed -n "${choice}p" "$file" | cut -d'|' -f1)

  echo -e "${GREEN}${SUCCESS} Selected ${role}: $selected${RESET}" >&2
  echo "$selected"
}

##############################################
# GENERATE install-config.yaml (GCP)
##############################################
generate_install_config() {
  mkdir -p "$CLUSTER_DIR"
  rm -f "$CLUSTER_DIR/install-config.yaml"

  log_info "Generating install-config.yaml..."

  cat > "$CLUSTER_DIR/install-config.yaml" <<EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
compute:
- name: worker
  replicas: 3
  platform:
    gcp:
      type: ${WORKER_INSTANCE_TYPE}
controlPlane:
  name: master
  replicas: 3
  platform:
    gcp:
      type: ${MASTER_INSTANCE_TYPE}
networking:
  networkType: OVNKubernetes
platform:
  gcp:
    projectID: ${GCP_PROJECT_ID}
    region: ${GCP_REGION}
publish: External
pullSecret: '$(tr -d '\n' < "$PULL_SECRET_FILE")'
sshKey: '$(cat "$SSH_KEY_FILE")'
EOF

  log_success "install-config.yaml generated successfully!"
}

##############################################
# MAIN
##############################################
main() {
  preflight_checks
  detect_gcp_project
  detect_base_domain
  detect_gcp_region

  MASTER_INSTANCE_TYPE=$(select_instance_type "$MASTER_FILE" "master")
  WORKER_INSTANCE_TYPE=$(select_instance_type "$WORKER_FILE" "worker")

  generate_install_config

  log_info "Starting OpenShift installation on GCP..."
  ./openshift-install create cluster --dir "$CLUSTER_DIR"

  log_success "Installation completed"
  log_info "Kubeconfig: $CLUSTER_DIR/auth/kubeconfig"
}

main "$@"
