#!/bin/bash

set -e

# --- Configuration ---
# YOU MUST BE LOGGED IN TO AZURE CLI: az login
AZURE_REGION="eastus"
RESOURCE_GROUP_NAME="fairscape-demo-rg-$(openssl rand -hex 3)"
VM_NAME="fairscape-vm-$(openssl rand -hex 3)"
VM_IMAGE="UbuntuLTS"
VM_SIZE="Standard_B2s" # 2 vCPUs, 4 GiB RAM
ADMIN_USERNAME="fairscape"

# --- VM Authentication Configuration ---
# For simplicity in this demo, we will use password authentication.
# IMPORTANT: For any non-demo or more secure setup, SSH key authentication is STRONGLY recommended.
# To use SSH keys:
# 1. Generate a key pair: ssh-keygen -t rsa -b 4096 -f ~/.ssh/fairscape_demo_azure_key (no passphrase for full automation)
# 2. In az vm create, use: --ssh-key-values "$(cat ~/.ssh/fairscape_demo_azure_key.pub)"
# 3. And remove --admin-password parameter.
VM_ADMIN_PASSWORD="YourComplexPassword123!"
                                         # Azure requires: 12-123 chars, 1 lowercase, 1 uppercase, 1 digit, 1 special char (not \ or -)

DEPLOY_REPO_URL="https://github.com/fairscape/fairscape_deployment.git"
CLONED_REPO_DIR_NAME="fairscape_deployment"


# --- Functions ---
cleanup_resources() {
  echo "-----------------------------------------------------"
  echo "To delete all created resources, run:"
  echo "az group delete --name ${RESOURCE_GROUP_NAME} --yes --no-wait"
  echo "-----------------------------------------------------"
}

# --- Main Script ---

echo "Starting Fairscape Demo Deployment on Azure..."
echo "Resource Group: ${RESOURCE_GROUP_NAME}"
echo "VM Name: ${VM_NAME}"
echo "Admin Username: ${ADMIN_USERNAME}"
echo "Region: ${AZURE_REGION}"

# Validate password (simple check, Azure will do more)
if [[ ${#VM_ADMIN_PASSWORD} -lt 12 || !("$VM_ADMIN_PASSWORD" =~ [A-Z]) || !("$VM_ADMIN_PASSWORD" =~ [a-z]) || !("$VM_ADMIN_PASSWORD" =~ [0-9]) ]]; then
    echo "Error: VM_ADMIN_PASSWORD does not meet Azure complexity requirements."
    echo "It must be 12-123 characters and include an uppercase letter, a lowercase letter, and a digit."
    echo "Please update the VM_ADMIN_PASSWORD variable in the script."
    exit 1
fi


# 1. Create Resource Group
echo "Creating resource group..."
az group create --name "${RESOURCE_GROUP_NAME}" --location "${AZURE_REGION}" -o table

# 2. Create Virtual Machine
echo "Creating virtual machine (${VM_NAME})... This may take a few minutes."

# User-data / cloud-init script to run on the VM at first boot
VM_USER_DATA=$(cat <<EOF
#!/bin/bash
sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common git docker.io docker-compose wget

sudo systemctl start docker
sudo systemctl enable docker

# cd to admin user's home directory
cd /home/${ADMIN_USERNAME}/

# Clone the deployment repository
echo "Cloning repository: ${DEPLOY_REPO_URL}..."
git clone ${DEPLOY_REPO_URL}
if [ ! -d "/home/${ADMIN_USERNAME}/${CLONED_REPO_DIR_NAME}" ]; then
    echo "Failed to clone deployment repository: ${DEPLOY_REPO_URL}"
    exit 1
fi
echo "Repository cloned successfully."

cd /home/${ADMIN_USERNAME}/${CLONED_REPO_DIR_NAME}/

echo "Starting Docker Compose stack from /home/${ADMIN_USERNAME}/${CLONED_REPO_DIR_NAME}/docker-compose.yaml..."
if [ ! -f "./docker-compose.yaml" ]; then
    echo "docker-compose.yaml not found in the root of the cloned repository."
    exit 1
fi

sudo docker-compose -f docker-compose.yaml up -d
echo "Docker Compose up -d command issued."
EOF
)


echo "Attempting to create VM with password authentication (for demo purposes only)."
echo "For production or secure environments, use SSH key authentication."
az vm create \
  --resource-group "${RESOURCE_GROUP_NAME}" \
  --name "${VM_NAME}" \
  --image "${VM_IMAGE}" \
  --size "${VM_SIZE}" \
  --admin-username "${ADMIN_USERNAME}" \
  --admin-password "${VM_ADMIN_PASSWORD}" \
  --custom-data "$VM_USER_DATA" \
  -o json

# 3. Get Public IP Address
echo "Fetching Public IP Address..."
PUBLIC_IP_ADDRESS=$(az vm show -d -g "${RESOURCE_GROUP_NAME}" -n "${VM_NAME}" --query publicIps -o tsv)

if [ -z "$PUBLIC_IP_ADDRESS" ]; then
  echo "Failed to get public IP address. VM might still be provisioning."
  echo "You can try: az vm show -d -g ${RESOURCE_GROUP_NAME} -n ${VM_NAME} --query publicIps -o tsv"
  cleanup_resources
  exit 1
fi

echo "-----------------------------------------------------"
echo "Fairscape Demo VM is deploying!"
echo "Public IP Address: ${PUBLIC_IP_ADDRESS}"
echo ""
echo "It might take a 5-10 minutes for the VM to fully initialize, clone the repo, and services to start."
echo ""
echo "Access services (assuming default ports from a typical fairscape_deployment/docker-compose.yaml):"
echo " - Fairscape Frontend: http://${PUBLIC_IP_ADDRESS} (if frontend is on port 80)"
echo " - Fairscape Backend API: http://${PUBLIC_IP_ADDRESS}:8080/api/ (e.g., /api/health)"
echo " - Minio Console: http://${PUBLIC_IP_ADDRESS}:9001"
echo " - Mongo Express: http://${PUBLIC_IP_ADDRESS}:8081"
echo ""
echo "To SSH into the VM (if needed, password will be prompted): ssh ${ADMIN_USERNAME}@${PUBLIC_IP_ADDRESS}"
echo "   VM Admin Username: ${ADMIN_USERNAME}"
echo "   VM Admin Password: ${VM_ADMIN_PASSWORD} (This was set in the script)"
echo ""
echo "The cloned repository is at /home/${ADMIN_USERNAME}/${CLONED_REPO_DIR_NAME}/"
echo "Docker logs: sudo docker-compose -f /home/${ADMIN_USERNAME}/${CLONED_REPO_DIR_NAME}/docker-compose.yaml logs -f <service_name>"
echo "-----------------------------------------------------"

# 4. Open necessary ports in the Network Security Group (NSG)
NSG_NAME="${VM_NAME}NSG"
echo "Configuring Network Security Group (${NSG_NAME}) rules..."
az network nsg rule create -g "${RESOURCE_GROUP_NAME}" --nsg-name "${NSG_NAME}" -n AllowHTTP --priority 100 --access Allow --protocol Tcp --destination-port-ranges 80 -o table
az network nsg rule create -g "${RESOURCE_GROUP_NAME}" --nsg-name "${NSG_NAME}" -n AllowFairscapeAPI --priority 110 --access Allow --protocol Tcp --destination-port-ranges 8080 -o table
az network nsg rule create -g "${RESOURCE_GROUP_NAME}" --nsg-name "${NSG_NAME}" -n AllowMinioAPI --priority 120 --access Allow --protocol Tcp --destination-port-ranges 9000 -o table
az network nsg rule create -g "${RESOURCE_GROUP_NAME}" --nsg-name "${NSG_NAME}" -n AllowMinioConsole --priority 130 --access Allow --protocol Tcp --destination-port-ranges 9001 -o table
az network nsg rule create -g "${RESOURCE_GROUP_NAME}" --nsg-name "${NSG_NAME}" -n AllowMongoExpress --priority 150 --access Allow --protocol Tcp --destination-port-ranges 8081 -o table
# SSH port 22 is typically opened by default with password auth as well.

echo "-----------------------------------------------------"
echo "Deployment script finished."
echo "Please wait a few minutes for all services to come online on the VM."
echo "Verify with: curl http://${PUBLIC_IP_ADDRESS}:8080/api/health (or similar endpoint)"
echo "And: curl http://${PUBLIC_IP_ADDRESS} (if frontend is on port 80)"
echo "-----------------------------------------------------"

cleanup_resources