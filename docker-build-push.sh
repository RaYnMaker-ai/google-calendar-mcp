#!/bin/bash

# Docker build and push script for Google Calendar MCP Server to ECR
# Builds for both AMD64 (x86_64) and ARM64 architectures
#
# Usage: ./docker-build-push.sh [VERSION]
# Example: ./docker-build-push.sh v1.0.0
#
# Environment variables:
#   AWS_REGION - AWS region for ECR (default: us-west-2)
#   AWS_ACCOUNT_ID - AWS account ID (auto-detected if not provided)
#   PLATFORMS - Target platforms (default: linux/amd64,linux/arm64)
#   ECR_REPOSITORY - ECR repository name (default: google-calendar-mcp)
#
# Examples:
#   ./docker-build-push.sh v1.0.0
#   PLATFORMS="linux/amd64" ./docker-build-push.sh v1.0.0  # AMD64 only
#   PLATFORMS="linux/arm64" ./docker-build-push.sh v1.0.0  # ARM64 only
#   ECR_REPOSITORY="my-org/calendar-mcp" ./docker-build-push.sh v1.0.0

set -e  # Exit on error

# Configuration - can be overridden with environment variables
AWS_REGION=${AWS_REGION:-us-west-2}
AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID:-""}
ECR_REPOSITORY=${ECR_REPOSITORY:-"google-calendar-mcp"}
IMAGE_NAME="google-calendar-mcp"
PLATFORMS=${PLATFORMS:-"linux/amd64,linux/arm64"}  # Multi-architecture support

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Print banner
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║   Google Calendar MCP Server - Docker Build & Push        ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check prerequisites
log_step "Checking prerequisites..."

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    log_error "AWS CLI is not installed. Please install it first."
    log_info "Install: https://aws.amazon.com/cli/"
    exit 1
fi
log_info "✓ AWS CLI found"

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed. Please install it first."
    log_info "Install: https://docs.docker.com/get-docker/"
    exit 1
fi
log_info "✓ Docker found"

# Check if Docker daemon is running
if ! docker info &> /dev/null; then
    log_error "Docker daemon is not running. Please start Docker."
    exit 1
fi
log_info "✓ Docker daemon running"

# Check if Dockerfile exists
if [ ! -f "Dockerfile" ]; then
    log_error "Dockerfile not found in current directory"
    exit 1
fi
log_info "✓ Dockerfile found"

# Check if package.json exists (to get version)
if [ ! -f "package.json" ]; then
    log_error "package.json not found. Are you in the project root?"
    exit 1
fi
log_info "✓ package.json found"

echo ""

# Get AWS Account ID if not provided
log_step "Configuring AWS..."
if [ -z "$AWS_ACCOUNT_ID" ]; then
    log_info "Getting AWS Account ID..."
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    if [ -z "$AWS_ACCOUNT_ID" ]; then
        log_error "Failed to get AWS Account ID."
        log_info "Please set AWS_ACCOUNT_ID environment variable or configure AWS CLI."
        log_info "Run: aws configure"
        exit 1
    fi
    log_info "✓ AWS Account ID: $AWS_ACCOUNT_ID"
else
    log_info "✓ Using provided AWS Account ID: $AWS_ACCOUNT_ID"
fi

log_info "✓ AWS Region: $AWS_REGION"
echo ""

# Construct full ECR repository URL
ECR_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}"

# Get version tag
if [ -n "$1" ]; then
    VERSION="$1"
    log_info "Using provided version: $VERSION"
else
    # Try to get version from package.json
    PACKAGE_VERSION=$(node -p "require('./package.json').version" 2>/dev/null || echo "")
    if [ -n "$PACKAGE_VERSION" ]; then
        VERSION="v${PACKAGE_VERSION}"
        log_info "Using version from package.json: $VERSION"
    else
        # Fallback to git commit hash
        VERSION=$(git rev-parse --short HEAD 2>/dev/null || echo "latest")
        log_info "Using git commit hash: $VERSION"
    fi
fi

# Also tag with git commit for traceability
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

echo ""
log_step "Build Configuration"
log_info "Repository: $ECR_URL"
log_info "Version Tag: $VERSION"
log_info "Git Commit: $GIT_COMMIT"
log_info "Platforms: $PLATFORMS"
echo ""

# Confirm before proceeding
read -p "Continue with build and push? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_warning "Build cancelled by user"
    exit 0
fi

echo ""

# Login to ECR
log_step "Authenticating with ECR..."
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

if [ $? -ne 0 ]; then
    log_error "Failed to login to ECR"
    log_info "Check your AWS credentials and permissions"
    exit 1
fi

log_info "✓ Successfully logged in to ECR"
echo ""

# Create ECR repository if it doesn't exist
log_step "Setting up ECR repository..."
if ! aws ecr describe-repositories --repository-names $ECR_REPOSITORY --region $AWS_REGION &> /dev/null; then
    log_warning "Repository doesn't exist. Creating..."
    aws ecr create-repository \
        --repository-name $ECR_REPOSITORY \
        --region $AWS_REGION \
        --image-scanning-configuration scanOnPush=true \
        --encryption-configuration encryptionType=AES256 \
        --tags Key=Project,Value=google-calendar-mcp Key=ManagedBy,Value=docker-build-push

    if [ $? -eq 0 ]; then
        log_info "✓ Repository created successfully"
    else
        log_error "Failed to create repository"
        exit 1
    fi
else
    log_info "✓ Repository already exists"
fi
echo ""

# Setup buildx for multi-platform builds
log_step "Configuring Docker buildx..."
if ! docker buildx version &> /dev/null; then
    log_error "Docker buildx is not available."
    log_info "Please update Docker to a newer version (20.10+)"
    exit 1
fi
log_info "✓ Docker buildx available"

# Create or use existing builder
BUILDER_NAME="mcp-multiarch-builder"
if ! docker buildx inspect $BUILDER_NAME &> /dev/null; then
    log_info "Creating new buildx builder: $BUILDER_NAME"
    docker buildx create --name $BUILDER_NAME --use
    log_info "✓ Builder created"
else
    log_info "Using existing buildx builder: $BUILDER_NAME"
    docker buildx use $BUILDER_NAME
fi

# Bootstrap the builder
log_info "Bootstrapping builder..."
docker buildx inspect --bootstrap > /dev/null
log_info "✓ Builder ready"
echo ""

# Build the project first
log_step "Building project..."
if [ -f "package.json" ]; then
    log_info "Running npm install and build..."
    npm install --silent
    npm run build --silent
    log_info "✓ Project built successfully"
else
    log_warning "Skipping npm build (package.json not found)"
fi
echo ""

# Build and push multi-platform image
log_step "Building and pushing Docker image..."
log_info "Platforms: $PLATFORMS"
log_info "Tags: $VERSION, $GIT_COMMIT, latest"
echo ""

docker buildx build \
    --platform $PLATFORMS \
    --tag $ECR_URL:$VERSION \
    --tag $ECR_URL:$GIT_COMMIT \
    --tag $ECR_URL:latest \
    --build-arg VERSION=$VERSION \
    --build-arg BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ') \
    --build-arg VCS_REF=$GIT_COMMIT \
    --push \
    --progress=plain \
    .

if [ $? -ne 0 ]; then
    log_error "Docker build and push failed"
    exit 1
fi

echo ""
log_info "✓ Docker images built and pushed successfully for all platforms"
echo ""

# Set lifecycle policy to keep only recent images
log_step "Setting lifecycle policy..."
LIFECYCLE_POLICY='{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Keep last 10 images",
      "selection": {
        "tagStatus": "any",
        "countType": "imageCountMoreThan",
        "countNumber": 10
      },
      "action": {
        "type": "expire"
      }
    }
  ]
}'

aws ecr put-lifecycle-policy \
    --repository-name $ECR_REPOSITORY \
    --region $AWS_REGION \
    --lifecycle-policy-text "$LIFECYCLE_POLICY" \
    &> /dev/null && log_info "✓ Lifecycle policy updated" || log_warning "Could not update lifecycle policy"

echo ""

# Success message
echo "╔════════════════════════════════════════════════════════════╗"
echo "║            Build and Push Completed Successfully!          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
log_info "Repository: $ECR_URL"
log_info "Platforms: $PLATFORMS"
echo ""
log_info "Tags pushed:"
echo "  • $VERSION"
echo "  • $GIT_COMMIT"
echo "  • latest"
echo ""
log_info "To pull this image:"
echo ""
echo "  # Login to ECR"
echo "  aws ecr get-login-password --region $AWS_REGION | \\"
echo "    docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
echo ""
echo "  # Pull specific version"
echo "  docker pull $ECR_URL:$VERSION"
echo ""
echo "  # Pull latest"
echo "  docker pull $ECR_URL:latest"
echo ""
log_info "To run locally:"
echo ""
echo "  docker run -d -p 3000:3000 \\"
echo "    -e GOOGLE_OAUTH_CREDENTIALS=/config/credentials.json \\"
echo "    -v /path/to/credentials:/config \\"
echo "    $ECR_URL:$VERSION"
echo ""

# Show image details
log_step "Image Details"
aws ecr describe-images \
    --repository-name $ECR_REPOSITORY \
    --region $AWS_REGION \
    --image-ids imageTag=$VERSION \
    --query 'imageDetails[0].[imageSizeInBytes,imagePushedAt,imageDigest]' \
    --output table 2>/dev/null || log_warning "Could not fetch image details"

echo ""
log_info "Build completed at: $(date)"
echo ""
