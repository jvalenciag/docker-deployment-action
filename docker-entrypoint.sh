#!/bin/sh
set -eu

execute_ssh(){
  echo "Execute Over SSH: $@"
  ssh -q -t -i "$HOME/.ssh/id_ed25519" \
      -J $INPUT_PROXY_HOST \
      -o UserKnownHostsFile=/dev/null \
      -p $INPUT_REMOTE_DOCKER_PORT \
      -o StrictHostKeyChecking=no "$INPUT_REMOTE_DOCKER_HOST" "$@"
}

if [ -z "$INPUT_REMOTE_DOCKER_PORT" ]; then
  INPUT_REMOTE_DOCKER_PORT=22
fi

if [ -z "$INPUT_REMOTE_DOCKER_HOST" ]; then
    echo "Input remote_docker_host is required!"
    exit 1
fi

if [ -z "$INPUT_SSH_PUBLIC_KEY" ]; then
    echo "Input ssh_public_key is required!"
    exit 1
fi

if [ -z "$INPUT_SSH_PRIVATE_KEY" ]; then
    echo "Input ssh_private_key is required!"
    exit 1
fi

if [ -z "$INPUT_ARGS" ]; then
  echo "Input input_args is required!"
  exit 1
fi

if [ -z "$INPUT_DEPLOY_PATH" ]; then
  INPUT_DEPLOY_PATH=~/docker-deployment
fi

if [ -z "$INPUT_STACK_FILE_NAME" ]; then
  INPUT_STACK_FILE_NAME=docker-compose.yaml
fi

if [ -z "$INPUT_KEEP_FILES" ]; then
  INPUT_KEEP_FILES=4
else
  INPUT_KEEP_FILES=$((INPUT_KEEP_FILES+1))
fi

STACK_FILE=${INPUT_STACK_FILE_NAME}
DEPLOYMENT_COMMAND_OPTIONS=""


if [ "$INPUT_COPY_STACK_FILE" == "true" ]; then
  STACK_FILE="$INPUT_DEPLOY_PATH/$STACK_FILE"
else
  DEPLOYMENT_COMMAND_OPTIONS="--host ssh://$INPUT_REMOTE_DOCKER_HOST:$INPUT_REMOTE_DOCKER_PORT"
fi

case $INPUT_DEPLOYMENT_MODE in

  docker-swarm)
    DEPLOYMENT_COMMAND="docker $DEPLOYMENT_COMMAND_OPTIONS stack deploy --compose-file $STACK_FILE"
  ;;

  *)
    INPUT_DEPLOYMENT_MODE="docker-compose"
    DEPLOYMENT_COMMAND="docker compose -f $STACK_FILE"
  ;;
esac

mkdir -p "$HOME/.ssh"

SSH_HOST=${INPUT_REMOTE_DOCKER_HOST#*@}
SSH_USER=${INPUT_REMOTE_DOCKER_HOST%@*}

if [ "$INPUT_PROXY_HOST" ]; then

  JUMP_HOST=${INPUT_PROXY_HOST#*@}

  echo "Setuping ProxyJump"
  printf '\n' >> "/etc/ssh/ssh_config"
  printf '%s\n' "Host dockerhost" >> "/etc/ssh/ssh_config"
  printf '  %s\n' "HostName $SSH_HOST" >> "/etc/ssh/ssh_config"
  printf '  %s\n' "User $SSH_USER" >> "/etc/ssh/ssh_config"
  printf '  %s\n' "ProxyJump $INPUT_PROXY_HOST" >> "/etc/ssh/ssh_config"
  
  # cat /etc/ssh/ssh_config

  ssh-keyscan -t ed25519 $JUMP_HOST dockerhost >> /etc/ssh/ssh_known_hosts
  DOCKER_REMOTE_HOST=dockerhost
  echo "192.168.1.242 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJtJ+/7v9JuOQNbMZDbsWizOo6pgBRnuohc0F0Fp14sw" >> /etc/ssh/ssh_known_hosts 
  echo "192.168.1.242 ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBPNEf8lsMM3YJ183WXJMyB42oCJQcMx6ej7QfvVFSKrkzJdkYToJLNZlDxzXkQl6/5YMSBXOz5zRzeBDYRouqrA=" >> /etc/ssh/ssh_known_hosts
else
  DOCKER_REMOTE_HOST=$INPUT_REMOTE_DOCKER_HOST
  ssh-keyscan -t ed25519 $SSH_HOST >> /etc/ssh/ssh_known_hosts
fi

echo "Registering SSH keys..."

# register the private key with the agent.

printf '%s\n' "$INPUT_SSH_PRIVATE_KEY" > "$HOME/.ssh/id_ed25519"
chmod 600 "$HOME/.ssh/id_ed25519"
eval $(ssh-agent)
ssh-add "$HOME/.ssh/id_ed25519"

echo "Add known hosts"
# ssh-keyscan -t ed25519 $SSH_HOST >> /etc/ssh/ssh_known_hosts
# cat /etc/ssh/ssh_known_hosts

export DOCKER_HOST="ssh://$DOCKER_REMOTE_HOST:$INPUT_REMOTE_DOCKER_PORT"

if ! [ -z "$INPUT_DOCKER_PRUNE" ] && [ $INPUT_DOCKER_PRUNE = 'true' ] ; then
  yes | docker --log-level debug --host "ssh://$INPUT_REMOTE_DOCKER_HOST:$INPUT_REMOTE_DOCKER_PORT" system prune -a 2>&1
fi

if ! [ -z "$INPUT_COPY_STACK_FILE" ] && [ $INPUT_COPY_STACK_FILE = 'true' ] ; then
  execute_ssh "mkdir -p $INPUT_DEPLOY_PATH/stacks || true"
  FILE_NAME="docker-stack-$(date +%Y%m%d%s).yaml"

  scp -i "$HOME/.ssh/id_ed25519" \
      -J $INPUT_PROXY_HOST \
      -o UserKnownHostsFile=/dev/null \
      -o StrictHostKeyChecking=no \
      -P $INPUT_REMOTE_DOCKER_PORT \
      $INPUT_STACK_FILE_NAME "$INPUT_REMOTE_DOCKER_HOST:$INPUT_DEPLOY_PATH/stacks/$FILE_NAME"

  execute_ssh "ln -nfs $INPUT_DEPLOY_PATH/stacks/$FILE_NAME $INPUT_DEPLOY_PATH/$INPUT_STACK_FILE_NAME"
  execute_ssh "ls -t $INPUT_DEPLOY_PATH/stacks/docker-stack-* 2>/dev/null |  tail -n +$INPUT_KEEP_FILES | xargs rm --  2>/dev/null || true"

  if ! [ -z "$INPUT_PULL_IMAGES_FIRST" ] && [ $INPUT_PULL_IMAGES_FIRST = 'true' ] && [ $INPUT_DEPLOYMENT_MODE = 'docker-compose' ] ; then
    execute_ssh ${DEPLOYMENT_COMMAND} "pull"
  fi

  if ! [ -z "$INPUT_PRE_DEPLOYMENT_COMMAND_ARGS" ] && [ $INPUT_DEPLOYMENT_MODE = 'docker-compose' ] ; then
    execute_ssh "${DEPLOYMENT_COMMAND}  $INPUT_PRE_DEPLOYMENT_COMMAND_ARGS" 2>&1
  fi

  execute_ssh ${DEPLOYMENT_COMMAND} "$INPUT_ARGS" 2>&1
else
  echo "Connecting to $INPUT_REMOTE_DOCKER_HOST... Command: ${DEPLOYMENT_COMMAND} ${INPUT_ARGS}"
  ${DEPLOYMENT_COMMAND} ${INPUT_ARGS} 2>&1
  # yes | docker system prune 2>&1
  if [ -z "$INPUT_AFTER_DEPLOY_CMD" ]; then
    ${DEPLOYMENT_COMMAND} ${AFTER_DEPLOY_CMD} 2>&1
  fi
fi
