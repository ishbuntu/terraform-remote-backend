#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Function to display error messages and exit
error_exit() {
  echo -e "${RED}ERROR: $1${NC}" >&2
  exit 1
}

# Function to display success messages
success_msg() {
  echo -e "${GREEN}$1${NC}"
}

# Function to display warning messages
warning_msg() {
  echo -e "${YELLOW}$1${NC}"
}

# Configuration
REGION="eu-west-1"
WORKSPACES=("dev" "test" "prod")
STATE_DIR="$(pwd)/terraform.tfstate.d"

# Check if backend.tf exists and extract values
if [ -f "$(pwd)/backend.tf" ]; then
  # Extract bucket name
  BASE_BUCKET_NAME=$(grep -o 'bucket[[:space:]]*=[[:space:]]*"[^"]*"' "$(pwd)/backend.tf" | cut -d'"' -f2)

  # Extract DynamoDB table name
  DYNAMODB_TABLE=$(grep -o 'dynamodb_table[[:space:]]*=[[:space:]]*"[^"]*"' "$(pwd)/backend.tf" | cut -d'"' -f2)

  if [ -z "$BASE_BUCKET_NAME" ] || [ -z "$DYNAMODB_TABLE" ]; then
    # Generate new values if extraction failed
    UUID_NAME="$(uuidgen | cut -c1-5)"
    BASE_BUCKET_NAME="terraform-state-${UUID_NAME}"
    DYNAMODB_TABLE="terraform-locks-${UUID_NAME}"
  fi
else
  # Generate new values if backend.tf doesn't exist
  UUID_NAME="$(uuidgen | cut -c1-5)"
  BASE_BUCKET_NAME="terraform-state-${UUID_NAME}"
  DYNAMODB_TABLE="terraform-locks-${UUID_NAME}"
fi

# Check for AWS credentials
check_aws_credentials() {
  echo "Checking AWS credentials..."
  if ! aws sts get-caller-identity &>/dev/null; then
    error_exit "AWS credentials not found or invalid. Please run 'aws configure' to set up your credentials."
  fi
  success_msg "AWS credentials verified."
}

# Create DynamoDB table for state locking
create_dynamodb_table() {
  echo "Setting up DynamoDB table for state locking..."

  if aws dynamodb describe-table --table-name $DYNAMODB_TABLE --region $REGION &>/dev/null; then
    warning_msg "DynamoDB table '$DYNAMODB_TABLE' already exists, skipping creation."
  else
    echo "Creating DynamoDB table '$DYNAMODB_TABLE'..."
    aws dynamodb create-table \
      --table-name $DYNAMODB_TABLE \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --region $REGION || error_exit "Failed to create DynamoDB table"

    echo "Waiting for DynamoDB table to be active..."
    aws dynamodb wait table-exists --table-name $DYNAMODB_TABLE --region $REGION
    success_msg "DynamoDB table created successfully."
  fi
}

# Create S3 bucket for state storage
create_s3_bucket() {
  echo "Setting up S3 bucket for state storage..."

  if aws s3api head-bucket --bucket $BASE_BUCKET_NAME --region $REGION 2>/dev/null; then
    warning_msg "S3 bucket '$BASE_BUCKET_NAME' already exists, skipping creation."
  else
    echo "Creating S3 bucket '$BASE_BUCKET_NAME'..."
    aws s3api create-bucket \
      --bucket $BASE_BUCKET_NAME \
      --region $REGION \
      --create-bucket-configuration LocationConstraint=$REGION || error_exit "Failed to create S3 bucket"
    success_msg "S3 bucket created successfully."
  fi

  echo "Configuring S3 bucket..."

  # Enable versioning
  echo "Enabling versioning..."
  aws s3api put-bucket-versioning \
    --bucket $BASE_BUCKET_NAME \
    --versioning-configuration Status=Enabled || error_exit "Failed to enable versioning"

  # Enable encryption
  echo "Enabling default encryption..."
  aws s3api put-bucket-encryption \
    --bucket $BASE_BUCKET_NAME \
    --server-side-encryption-configuration '{
      "Rules": [
        {
          "ApplyServerSideEncryptionByDefault": {
            "SSEAlgorithm": "AES256"
          }
        }
      ]
    }' || error_exit "Failed to enable encryption"

  success_msg "S3 bucket configured successfully."
}

# Create workspace folders and empty state files
setup_workspaces() {
  echo "Setting up workspace folders in S3 bucket..."

  for workspace in "${WORKSPACES[@]}"; do
    echo "Setting up folder for workspace: $workspace"

    # Create an empty file
    touch empty_state

    # Upload empty state file
    aws s3api put-object \
      --bucket $BASE_BUCKET_NAME \
      --key "env/$workspace/terraform.tfstate" \
      --body empty_state \
      --region $REGION || error_exit "Failed to create workspace folder for $workspace"

    rm empty_state
  done

  success_msg "Workspace folders created successfully."
}

# Migrate state for a specific workspace
migrate_state() {
  local workspace=$1

  echo "Migrating state for workspace: $workspace"

  # Check if state directory exists
  if [ ! -d "$STATE_DIR" ]; then
    error_exit "State directory '$STATE_DIR' not found. Make sure you're running this script from the root of your Terraform project."
  fi

  # Check if workspace directory exists
  if [ ! -d "$STATE_DIR/$workspace" ]; then
    warning_msg "Workspace directory '$workspace' not found in '$STATE_DIR'. Skipping migration."
    return
  fi

  # Check if local state exists
  if [ ! -f "$STATE_DIR/$workspace/terraform.tfstate" ]; then
    warning_msg "Local state file for workspace '$workspace' not found. Skipping migration."
    return
  fi

  # Backup local state
  echo "Creating backup of local state..."
  cp "$STATE_DIR/$workspace/terraform.tfstate" "${workspace}-state-backup.tfstate" || error_exit "Failed to backup state file"

  # Upload state to S3
  echo "Uploading state to S3..."
  aws s3 cp "${workspace}-state-backup.tfstate" "s3://$BASE_BUCKET_NAME/env/$workspace/terraform.tfstate" || error_exit "Failed to upload state file"

  # Verify upload
  if aws s3 ls "s3://$BASE_BUCKET_NAME/env/$workspace/terraform.tfstate" &>/dev/null; then
    success_msg "State file for workspace '$workspace' successfully migrated to S3."
  else
    error_exit "Failed to verify state file upload for workspace '$workspace'."
  fi
}

# Display backend configuration
show_backend_config() {
  echo ""
  success_msg "Terraform backend infrastructure setup complete!"
  echo ""
  echo "Your backend.tf configuration should look like this:"
  echo "----------------"
  echo 'terraform {'
  echo '  backend "s3" {'
  echo '    bucket               = "'$BASE_BUCKET_NAME'"'
  echo '    key                  = "terraform.tfstate"'
  echo '    region               = "'$REGION'"'
  echo '    dynamodb_table       = "'$DYNAMODB_TABLE'"'
  echo '    encrypt              = true'
  echo '    workspace_key_prefix = "env"'
  echo '  }'
  echo '}'
  echo "----------------"
  echo ""
  echo "To use a specific workspace:"
  echo "terraform workspace select dev|stg|prod"
  echo ""
  echo "This will store state at: s3://$BASE_BUCKET_NAME/env/WORKSPACE_NAME/terraform.tfstate"
}

# Update backend.tf file with the generated configuration
update_backend_file() {
  local backend_file="$(pwd)/backend.tf"

  echo "Updating backend.tf file..."

  cat > "$backend_file" << EOF
terraform {
  backend "s3" {
    bucket               = "$BASE_BUCKET_NAME"
    key                  = "terraform.tfstate"
    region               = "$REGION"
    dynamodb_table       = "$DYNAMODB_TABLE"
    encrypt              = true
    workspace_key_prefix = "env"
  }
}
EOF

  if [ -f "$backend_file" ]; then
    success_msg "Backend configuration written to backend.tf"
  else
    error_exit "Failed to create backend.tf file"
  fi
}

# Destroy backend infrastructure
destroy_backend() {
  local bucket_name=$1
  local table_name=$2

  echo "Destroying backend infrastructure..."

  # Check if bucket exists
  if aws s3api head-bucket --bucket $bucket_name --region $REGION 2>/dev/null; then
    echo "Emptying S3 bucket '$bucket_name'..."
    aws s3 rm s3://$bucket_name --recursive --region $REGION

    echo "Deleting S3 bucket '$bucket_name'..."
    aws s3api delete-bucket --bucket $bucket_name --region $REGION
    success_msg "S3 bucket '$bucket_name' deleted."
  else
    warning_msg "S3 bucket '$bucket_name' does not exist."
  fi

  # Check if DynamoDB table exists
  if aws dynamodb describe-table --table-name $table_name --region $REGION &>/dev/null; then
    echo "Deleting DynamoDB table '$table_name'..."
    aws dynamodb delete-table --table-name $table_name --region $REGION
    success_msg "DynamoDB table '$table_name' deleted."
  else
    warning_msg "DynamoDB table '$table_name' does not exist."
  fi

  # Remove backend.tf file if it exists
  local backend_file="$(pwd)/backend.tf"
  if [ -f "$backend_file" ]; then
    echo "Removing backend.tf file..."
    rm "$backend_file"
    success_msg "Backend.tf file removed."
  fi

  success_msg "Backend infrastructure destroyed successfully."
}

# Read backend configuration from backend.tf file
read_backend_config() {
  local backend_file="$(pwd)/backend.tf"
  local bucket_name=""
  local table_name=""

  if [ ! -f "$backend_file" ]; then
    error_exit "Backend.tf file not found. Cannot determine backend configuration."
  fi

  # Extract bucket name
  bucket_name=$(grep -o 'bucket[[:space:]]*=[[:space:]]*"[^"]*"' "$backend_file" | cut -d'"' -f2)

  # Extract DynamoDB table name
  table_name=$(grep -o 'dynamodb_table[[:space:]]*=[[:space:]]*"[^"]*"' "$backend_file" | cut -d'"' -f2)

  if [ -z "$bucket_name" ] || [ -z "$table_name" ]; then
    error_exit "Could not extract bucket name or DynamoDB table name from backend.tf"
  fi

  echo "Found backend configuration:"
  echo "  Bucket: $bucket_name"
  echo "  DynamoDB table: $table_name"

  BACKEND_BUCKET_NAME=$bucket_name
  BACKEND_TABLE_NAME=$table_name
}

# List available workspaces from the state directory
list_workspaces() {
  local workspaces=()

  # Check if state directory exists
  if [ ! -d "$STATE_DIR" ]; then
    warning_msg "State directory '$STATE_DIR' not found."
    warning_msg "Make sure you're running this script from the root of your Terraform project."
    return 1
  fi

  # Find workspaces with state files
  for dir in "$STATE_DIR"/*/; do
    if [ -d "$dir" ]; then
      workspace=$(basename "$dir")
      if [ -f "$dir/terraform.tfstate" ]; then
        workspaces+=("$workspace")
      fi
    fi
  done

  if [ ${#workspaces[@]} -eq 0 ]; then
    warning_msg "No workspaces with state files found in $STATE_DIR"
    return 1
  fi

  echo "Found workspaces: ${workspaces[*]}"
  FOUND_WORKSPACES=("${workspaces[@]}")
  return 0
}

# Main function
main() {
  local command=${1:-"setup"}
  local workspace=${2:-"dev"}

  # Display current state directory
  echo "Using state directory: $STATE_DIR"

  case $command in
    setup)
      check_aws_credentials
      create_dynamodb_table
      create_s3_bucket
      setup_workspaces
      show_backend_config
      update_backend_file
      ;;
    migrate)
      check_aws_credentials
      migrate_state "$workspace"
      ;;
    migrate-all)
      check_aws_credentials
      if list_workspaces; then
        for ws in "${FOUND_WORKSPACES[@]}"; do
          migrate_state "$ws"
        done
      else
        error_exit "No workspace state files found to migrate"
      fi
      ;;
    list)
      list_workspaces
      ;;
    destroy)
      check_aws_credentials
      read_backend_config
      echo "WARNING: This will delete all Terraform state data in the S3 bucket and DynamoDB table."
      echo "Are you sure you want to destroy the backend infrastructure? (y/N)"
      read -r confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        destroy_backend "$BACKEND_BUCKET_NAME" "$BACKEND_TABLE_NAME"
      else
        echo "Destroy operation cancelled."
      fi
      ;;
    *)
      echo "Usage: $0 [setup|migrate|migrate-all|list|destroy] [workspace]"
      echo ""
      echo "Commands:"
      echo "  setup       - Set up S3 bucket and DynamoDB table for Terraform backend"
      echo "  migrate     - Migrate state for a specific workspace"
      echo "  migrate-all - Migrate state for all detected workspaces"
      echo "  list        - List available workspaces with state files"
      echo "  destroy     - Destroy backend infrastructure (S3 bucket and DynamoDB table)"
      echo ""
      echo "Examples:"
      echo "  $0 setup          - Set up backend infrastructure"
      echo "  $0 migrate dev    - Migrate state for dev workspace"
      echo "  $0 migrate-all    - Migrate state for all detected workspaces"
      echo "  $0 list           - List available workspaces with state files"
      echo "  $0 destroy        - Destroy backend infrastructure"
      exit 1
      ;;
  esac
}

# Run main function with all arguments
main "$@"
