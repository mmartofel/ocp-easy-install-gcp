#!/usr/bin/env bash
set -euo pipefail

##############################################
# CONFIGURATION VARIABLES
##############################################
CLUSTER_DIR="${CLUSTER_DIR:-./config}"
CLUSTER_NAME="${CLUSTER_NAME:-zenek}"
CHANNEL="${CHANNEL:-stable-4.21}"
BASE_DOMAIN="${BASE_DOMAIN:-example.com}"
PULL_SECRET_FILE="${PULL_SECRET_FILE:-./pull-secret.txt}"
SSH_KEY_FILE="${SSH_KEY_FILE:-./ssh/id_rsa.pub}"

OFFER_TYPE=${OFFER_TYPE:-"bring-your-own-subscription"}

GCP_PROJECT_ID="${GCP_PROJECT_ID:-}"
GCP_REGION="${GCP_REGION:-us-central1}"

MASTER_FILE="./instances/master"
WORKER_FILE="./instances/worker"
OCP_SKU_FILE="./instances/marketplace"

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
log_question() { echo -e "${MAGENTA}${INFO} $1${RESET}"; }
log_success() { echo -e "${GREEN}${SUCCESS} $1${RESET}"; }
log_warn() { echo -e "${YELLOW}${WARN} $1${RESET}"; }
log_error() { echo -e "${RED}${ERROR} $1${RESET}" >&2; }

##############################################
# OFFER TYPE SELECTION
##############################################
prompt_offer_type() {  

  echo >&2
  log_question "Choose your preferred subscription mode:"

  echo -e "  [1] Bring Your Own Subscription (default)"
  echo -e "  [2] Marketplace"
  read -rp "Enter your choice [1-2]: " choice

  case "$choice" in
    2)
      OFFER_TYPE="marketplace"
      ;;
    *)
      OFFER_TYPE="bring-your-own-subscription"
      ;;
  esac

  log_success "Selected subscription model: $OFFER_TYPE"
}

###############################################
# OPENSHIFT SKU SELECTION (FOR MARKETPACE ONLY)
###############################################
select_ocp_sku_type() {
  local file="$1"
  local role="$2"

  echo >&2
  echo -e "${MAGENTA}${INFO} Available ${role} editions:${RESET}" >&2
  echo "----------------------------------------" >&2

  local i=1
  while IFS= read -r line || [[ -n "$line" ]]; do
    echo "  [$i] $line" >&2
    ((i++))
  done < "$file"

  read -rp "Choose ${role} edition (default=1): " choice >&2
  [[ -z "$choice" ]] && choice=1

  local total
  total=$(grep -c '' "$file")

  [[ "$choice" =~ ^[0-9]+$ ]] || exit 1
  (( choice >=1 && choice <= total )) || exit 1

  local selected
  selected=$(sed -n "${choice}p" "$file" | cut -d'|' -f1)

  echo -e "${GREEN}${SUCCESS} Selected ${role} marketplace image: $selected${RESET}" >&2
  echo "$selected"
}

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

  if [[ "$OFFER_TYPE" == "marketplace" ]]; then
    [[ -d "./instances/marketplace" ]] || { log_error "Marketplace images directory not found"; exit 1; }
  else
    [[ -f "$MASTER_FILE" ]] || { log_error "Master instance list not found"; exit 1; }
    [[ -f "$WORKER_FILE" ]] || { log_error "Worker instance list not found"; exit 1; }
  fi

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
# INSTANCE SELECTION (FOR MASTERS AND WORKERS)
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

###############################################
# FETCH AVAILABLE OCP VERSIONS FOR GIVEN MINOR
###############################################
get_ocp_versions() {
    local channel=${CHANNEL}

    # strip the “stable-” prefix – every track begins with it
    local minor=${channel#stable-}

    echo "💡 Fetching OpenShift versions from channel: $channel ..." >&2

    ALL_VERSIONS=$(curl -s "https://api.openshift.com/api/upgrades_info/v1/graph?channel=${channel}" \
        | jq -r '.nodes[].version')

    # use the computed minor in the grep
    VERSIONS=$(echo "$ALL_VERSIONS" | grep "^${minor}\." | sort -V)

    if [[ -z "$VERSIONS" ]]; then
        echo "❌ No OpenShift versions found in $channel" >&2
        exit 1
    fi

    # IMPORTANT: print ONLY versions here, NOTHING ELSE
    echo "$VERSIONS"
}

###############################################
# SELECT OCP VERSION
###############################################
select_ocp_version() {
    # Read get_ocp_versions line by line into array
    versions=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && versions+=("$line")
    done < <(get_ocp_versions)

    if [[ ${#versions[@]} -eq 0 ]]; then
        echo "❌ No OpenShift versions found!" >&2
        exit 1
    fi

    echo "💡 Available OpenShift ${versions[0]%.*}.x versions:"
    echo "----------------------------------------"

    for i in "${!versions[@]}"; do
        printf "  [%d] %s\n" $((i+1)) "${versions[$i]}"
    done

    # default is last element
    default_choice=${#versions[@]}
    read -p "Choose OpenShift version (default=${versions[$((default_choice-1))]}): " choice

    if [[ -z "$choice" ]]; then
        SELECTED_VERSION="${versions[$((default_choice-1))]}"
    else
        # validate choice
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#versions[@]} )); then
            echo "❌ Invalid choice. Must be 1..${#versions[@]}" >&2
            exit 1
        fi
        SELECTED_VERSION="${versions[$((choice-1))]}"
    fi

    echo "✅ Selected OpenShift version: $SELECTED_VERSION"
}

##############################################
# SET RELEASE IMAGE
##############################################
set_release_image() {
    RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release:${SELECTED_VERSION}-x86_64"

    echo "💡 Using release image:"
    echo "   $RELEASE_IMAGE"

    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$RELEASE_IMAGE"

    echo "✅ Release override set successfully."
}

##############################################
# GENERATE install-config.yaml (GCP)
##############################################
generate_install_config() {
  mkdir -p "$CLUSTER_DIR"
  rm -f "$CLUSTER_DIR/install-config.yaml"

  log_info "Generating install-config.yaml..."

if [[ "$OFFER_TYPE" == "marketplace" ]]; then

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
      osImage:
        project: redhat-marketplace-public
        name: ${OCP_SKU_TYPE}
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

else

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

fi

  log_success "install-config.yaml generated successfully!"
}

##############################################
# CLEANUP OLD CLUSTER INSTALL FILES
##############################################
cleanup_old_cluster_files() {
  if [[ -d "$CLUSTER_DIR" ]]; then
    log_warn "Old cluster installation files detected in $CLUSTER_DIR. Cleaning up..."
    rm -rf "$CLUSTER_DIR"/* "$CLUSTER_DIR"/.* 2>/dev/null || true
    log_success "Old cluster installation files cleaned up."
  fi
}

##############################################
# MAIN
##############################################
main() {
  cleanup_old_cluster_files
  preflight_checks
  detect_gcp_project
  detect_base_domain
  detect_gcp_region
  prompt_offer_type

  if [[ "$OFFER_TYPE" == "marketplace" ]]; then
    OCP_SKU_TYPE=$(select_ocp_sku_type "$OCP_SKU_FILE" "openshift")
  fi

  MASTER_INSTANCE_TYPE=$(select_instance_type "$MASTER_FILE" "master")
  WORKER_INSTANCE_TYPE=$(select_instance_type "$WORKER_FILE" "worker")

  generate_install_config
  select_ocp_version
  set_release_image

  log_info "Release image set to:"
  log_info "  $RELEASE_IMAGE"
  log_info "Starting OpenShift installation on GCP..."
  ./openshift-install create cluster --dir "$CLUSTER_DIR"
  log_success "Installation completed"
  log_info "Kubeconfig: $CLUSTER_DIR/auth/kubeconfig"
}

main "$@"
