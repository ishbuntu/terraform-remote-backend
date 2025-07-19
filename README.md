# Terraform Remote Backend Automation

This script automates the setup and management of Terraform remote backends using AWS S3 for state storage and DynamoDB for state locking.

## Features

- Automatically creates S3 buckets for Terraform state storage
- Sets up DynamoDB tables for state locking
- Configures S3 bucket with versioning and encryption
- Creates workspace folders in S3 (dev, test, prod)
- Migrates existing local state files to S3
- Generates and updates backend.tf configuration
- Provides options to destroy backend infrastructure when needed

## Prerequisites

- AWS CLI installed and configured with appropriate permissions
- Bash shell environment
- Terraform project structure

## Usage

```bash
./remote-backend-auto.sh [command] [workspace]
```

### Commands

- `setup` - Set up S3 bucket and DynamoDB table for Terraform backend
- `migrate` - Migrate state for a specific workspace
- `migrate-all` - Migrate state for all detected workspaces
- `list` - List available workspaces with state files
- `destroy` - Destroy backend infrastructure (S3 bucket and DynamoDB table)

### Examples

```bash
# Set up backend infrastructure
./remote-backend-auto.sh setup

# Migrate state for dev workspace
./remote-backend-auto.sh migrate dev

# Migrate state for all detected workspaces
./remote-backend-auto.sh migrate-all

# List available workspaces with state files
./remote-backend-auto.sh list

# Destroy backend infrastructure
./remote-backend-auto.sh destroy
```

## How It Works

1. The script checks for existing backend.tf configuration or generates new unique names
2. Creates and configures the S3 bucket with versioning and encryption
3. Creates the DynamoDB table for state locking
4. Sets up workspace folders in the S3 bucket
5. Generates or updates the backend.tf file with the correct configuration
6. Provides options to migrate existing state files to the remote backend

## Security Features

- Enables default encryption on S3 bucket (AES-256)
- Configures versioning on S3 bucket to prevent state loss
- Validates AWS credentials before performing operations

## License

MIT
