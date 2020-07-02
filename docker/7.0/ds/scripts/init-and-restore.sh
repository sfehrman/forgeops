#!/usr/bin/env bash
# Simple script to automatically restore DS from backups
# Note: This script assumes it runs in a k8s init-container with the proper volumes and environment variables attached.

# Required environmental variables: 
# AUTORESTORE_FROM_DSBACKUP: Set to true to restore from backup. Defaults to false
# GOOGLE_CREDENTIALS_JSON: Contents of the service account JSON, if using GCP. The SA must have write privileges in the desired bucket
# AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY: Access key and secret for AWS, if using S3. 
# AZURE_ACCOUNT_NAME, AZURE_ACCOUNT_KEY: Storage account name and key, if using Azure
# POD_NAME: Name of the current pod

set -e

if [ -n "$(ls -A /opt/opendj/data -I lost+found)" ]; then
  echo "Found data present in /opt/opendj/data before DS initialization"
  DATA_PRESENT_BEFORE_INIT="true"
  ls -A /opt/opendj/data -I lost+found
fi

# Initialize DS regarless of dsbackup restore settings
/opt/opendj/docker-entrypoint.sh initialize-only;

if [ -z "${AUTORESTORE_FROM_DSBACKUP}" ] || [ "${AUTORESTORE_FROM_DSBACKUP}" != "true" ]; then
    echo "AUTORESTORE_FROM_DSBACKUP is missing or not set to true. Skipping restore"
    exit 0
else
    echo "AUTORESTORE_FROM_DSBACKUP is set to true. Will attempt to recover from backup"
fi

if [ -z "${DSBACKUP_DIRECTORY}" ]; then
    echo "If AUTORESTORE_FROM_DSBACKUP is enabled, DSBACKUP_DIRECTORY must be specified. "
    echo "DSBACKUP_DIRECTORY can be set to: /local/path | s3://bucket/path | az://bucket/path | gs://bucket/path "
    exit -1
else
    echo "DSBACKUP_DIRECTORY is set to $DSBACKUP_DIRECTORY"
fi

if [ -n "${DATA_PRESENT_BEFORE_INIT}" ] && [ "${DATA_PRESENT_BEFORE_INIT}" != "false" ]; then
   echo "****"
   echo "There's data already present in /opt/opendj/data. Skipping restore operation." 
   echo "****"
   exit 0
fi

AWS_PARAMS="--storageProperty s3.keyId.env.var:AWS_ACCESS_KEY_ID  --storageProperty s3.secret.env.var:AWS_SECRET_ACCESS_KEY"
AZ_PARAMS="--storageProperty az.accountName.env.var:AZURE_ACCOUNT_NAME  --storageProperty az.accountKey.env.var:AZURE_ACCOUNT_KEY"
GCP_CREDENTIAL_PATH="/var/run/secrets/cloud-credentials-cache/gcp-credentials.json"
GCP_PARAMS="--storageProperty gs.credentials.path:${GCP_CREDENTIAL_PATH}"
EXTRA_PARAMS=""

# Always restore from first pod's backup. i.e. replace ds-cts-2 with ds-cts-0
BACKUP_NAME="$(printf '%s' $POD_NAME | sed 's/[0-9]\+$//')0"

case "$DSBACKUP_DIRECTORY" in 
  s3://* )
    echo "S3 Bucket detected. Restoring backups from AWS S3"
    EXTRA_PARAMS="${AWS_PARAMS}"
    BACKUP_LOCATION="${DSBACKUP_DIRECTORY}/${BACKUP_NAME}"
    ;;
  az://* )
    echo "Azure Bucket detected. Restoring backups from Azure block storage"
    EXTRA_PARAMS="${AZ_PARAMS}"
    BACKUP_LOCATION="${DSBACKUP_DIRECTORY}/${BACKUP_NAME}"
    ;;
  gs://* )
    echo "GCP Bucket detected. Restoring backups from GCP block storage"
    printf %s "$GOOGLE_CREDENTIALS_JSON" > ${GCP_CREDENTIAL_PATH}
    EXTRA_PARAMS="${GCP_PARAMS}"
    BACKUP_LOCATION="${DSBACKUP_DIRECTORY}/${BACKUP_NAME}"
    ;;
  *)
    EXTRA_PARAMS=""
    BACKUP_LOCATION="${DSBACKUP_DIRECTORY}"
    ;;
esac  

echo "Attempting to restore backup from: ${BACKUP_LOCATION}"

if [ ${POD_NAME} = ${BACKUP_NAME} ]; then
  # If this pod is the owner of the backup tasks, restore the tasks. Else, skip the "tasks" backend
  BACKEND_NAMES=$(dsbackup list --last --verify --noPropertiesFile --backupLocation ${BACKUP_LOCATION} ${EXTRA_PARAMS} | 
      grep -i "backend name" | awk '{printf "%s %s ","--backendName", $3}')
else
  BACKEND_NAMES=$(dsbackup list --last --verify --noPropertiesFile --backupLocation ${BACKUP_LOCATION} ${EXTRA_PARAMS} | 
      grep -i "backend name" | grep -v "tasks" | awk '{printf "%s %s ","--backendName", $3}')
fi

if [ ! -z "${BACKEND_NAMES}" ]; then
    echo "Restore operation starting"
    echo "Restoring ${BACKEND_NAMES}"
    dsbackup restore --offline --noPropertiesFile --backupLocation ${BACKUP_LOCATION} ${EXTRA_PARAMS} ${BACKEND_NAMES} 
    echo "Restore operation complete"
else
    echo "No Backup found in ${BACKUP_LOCATION}. There's nothing to restore"
fi

