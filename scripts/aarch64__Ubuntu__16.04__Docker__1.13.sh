#!/bin/bash
set -e
set -o pipefail

###########################################################
###########################################################
# Initialization script for Shippable node on
#   - Architecture aarch64
#   - Ubuntu 16.04
#   - Docker 1.13.0
###########################################################
###########################################################

readonly DOCKER_VERSION="1.13.0"

# Indicates if docker service should be restarted
export docker_restart=false

setup_shippable_user() {
  if id -u 'shippable' >/dev/null 2>&1; then
    echo "User shippable already exists"
  else
    exec_cmd "sudo useradd -d /home/shippable -m -s /bin/bash -p shippablepwd shippable"
  fi

  exec_cmd "sudo echo 'shippable ALL=(ALL) NOPASSWD:ALL' | sudo tee -a /etc/sudoers"
  exec_cmd "sudo chown -R $USER:$USER /home/shippable/"
  exec_cmd "sudo chown -R shippable:shippable /home/shippable/"
}

install_prereqs() {
  echo "Installing prerequisite binaries"

  update_cmd="sudo apt-get update"
  exec_cmd "$update_cmd"

  install_prereqs_cmd="sudo apt-get -yy install apt-transport-https git python-pip software-properties-common ca-certificates curl"
  exec_cmd "$install_prereqs_cmd"

  update_cmd="sudo apt-get update"
  exec_cmd "$update_cmd"
}

check_swap() {
  echo "Checking for swap space"

  swap_available=$(free | grep Swap | awk '{print $2}')
  if [ $swap_available -eq 0 ]; then
    echo "No swap space available, adding swap"
    is_swap_required=true
  else
    echo "Swap space available, not adding"
  fi
}

add_swap() {
  echo "Adding swap file"
  echo "Creating Swap file at: $SWAP_FILE_PATH"
  add_swap_file="sudo touch $SWAP_FILE_PATH"
  exec_cmd "$add_swap_file"

  swap_size=$(cat /proc/meminfo | grep MemTotal | awk '{print $2}')
  swap_size=$(($swap_size/1024))
  echo "Allocating swap of: $swap_size MB"
  initialize_file="sudo dd if=/dev/zero of=$SWAP_FILE_PATH bs=1M count=$swap_size"
  exec_cmd "$initialize_file"

  echo "Updating Swap file permissions"
  update_permissions="sudo chmod -c 600 $SWAP_FILE_PATH"
  exec_cmd "$update_permissions"

  echo "Setting up Swap area on the device"
  initialize_swap="sudo mkswap $SWAP_FILE_PATH"
  exec_cmd "$initialize_swap"

  echo "Turning on Swap"
  turn_swap_on="sudo swapon $SWAP_FILE_PATH"
  exec_cmd "$turn_swap_on"

}

check_fstab_entry() {
  echo "Checking fstab entries"

  if grep -q $SWAP_FILE_PATH /etc/fstab; then
    exec_cmd "echo /etc/fstab updated, swap check complete"
  else
    echo "No entry in /etc/fstab, updating ..."
    add_swap_to_fstab="echo $SWAP_FILE_PATH none swap sw 0 0 | sudo tee -a /etc/fstab"
    exec_cmd "$add_swap_to_fstab"
    exec_cmd "echo /etc/fstab updated"
  fi
}

initialize_swap() {
  check_swap
  if [ "$is_swap_required" == true ]; then
    add_swap
  fi
  check_fstab_entry
}

install_docker_io() {
  install_docker_io=false
  {
    dpkg -s docker.io > /dev/null 2>&1
  } ||
  {
    install_docker_io=true
  }
  if [ "$install_docker_io" = true ]; then
    sudo apt-get install -q -yy --force-yes docker.io
  fi
}

build_docker_binary() {
  if [ ! -d /opt/docker ]; then
    pushd /tmp
    local tag_version="v$DOCKER_VERSION"
    git clone https://github.com/moby/moby.git
    cd moby
    git checkout $tag_version
    make tgz
    tar -xvf bundles/$DOCKER_VERSION/tgz/linux/arm64/docker-$DOCKER_VERSION.tgz -C /opt
    popd
  fi
}

docker_install() {
  echo "Installing docker"

  install_docker_io

  build_docker_binary

  docker_version=$(sudo docker version --format {{.Server.Version}})
  if [ "$DOCKER_VERSION" != "$docker_version" ]; then
    sudo cp -a /opt/docker/. /usr/bin/
    docker_restart=true
  fi
}

check_docker_opts() {
  # SHIPPABLE docker options required for every node
  echo "Checking docker options"

  SHIPPABLE_DOCKER_OPTS='DOCKER_OPTS="$DOCKER_OPTS -H unix:///var/run/docker.sock -g=/data --dns 8.8.8.8 --dns 8.8.4.4"'

  # DOCKER_OPTS do not exist or match.
  if [ -z "$opts_exist" ]; then
    echo "Removing existing DOCKER_OPTS in /etc/default/docker, if any"
    sudo sed -i '/^DOCKER_OPTS/d' "/etc/default/docker"

    echo "Appending DOCKER_OPTS to /etc/default/docker"
    sudo sh -c "echo '$SHIPPABLE_DOCKER_OPTS' >> /etc/default/docker"
    docker_restart=true
  else
    echo "Shippable docker options already present in /etc/default/docker"
  fi

  ## remove the docker option to listen on all ports
  echo "Disabling docker tcp listener"
  sudo sh -c "sed -e s/\"-H tcp:\/\/0.0.0.0:4243\"//g -i /etc/default/docker"
}

restart_docker_service() {
  echo "checking if docker restart is necessary"

  if [ "$docker_restart" = true ]; then
    echo "restarting docker service on reset"
    exec_cmd "sudo systemctl restart docker"
  else
    echo "docker_restart set to false, not restarting docker daemon"
  fi
}

install_ntp() {
  {
    check_ntp=$(sudo service --status-all 2>&1 | grep ntp)
  } || {
    true
  }

  if [ ! -z "$check_ntp" ]; then
    echo "NTP already installed, skipping."
  else
    echo "Installing NTP"
    exec_cmd "sudo apt-get install -y ntp"
    exec_cmd "sudo service ntp restart"
  fi
}

before_exit() {
  echo $1
  echo $2

  echo "Node init script completed"
}

main() {
  trap before_exit EXIT
  exec_grp "setup_shippable_user"

  trap before_exit EXIT
  exec_grp "install_prereqs"

  if [ "$IS_SWAP_ENABLED" == "true" ]; then
    trap before_exit EXIT
    exec_grp "initialize_swap"
  fi

  trap before_exit EXIT
  exec_grp "docker_install"

  trap before_exit EXIT
  exec_grp "check_docker_opts"

  trap before_exit EXIT
  exec_grp "restart_docker_service"

  trap before_exit EXIT
  exec_grp "install_ntp"
}

main
