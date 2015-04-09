#!/bin/bash

# fail immediately on error
set -e

echo "$0 $*" > ~/provision.log

# Variables passed in from terraform, see aws-vpc.tf, the "remote-exec" provisioner
AWS_KEY_ID=${1}
AWS_ACCESS_KEY=${2}
REGION=${3}
VPC=${4}
BOSH_SUBNET=${5}
IPMASK=${6}
CF_IP=${7}
CF_SUBNET1=${8}
CF_SUBNET1_AZ=${9}
CF_SUBNET2=${10}
CF_SUBNET2_AZ=${11}
BASTION_AZ=${12}
BASTION_ID=${13}
LB_SUBNET1=${14}
CF_SG=${15}
CF_ADMIN_PASS=${16}
CF_DOMAIN=${17}
CF_BOSHWORKSPACE_VERSION=${18}
CF_SIZE=${19}
DOCKER_SUBNET=${20}
INSTALL_DOCKER=${21}

boshDirectorHost="${IPMASK}.1.4"
cfReleaseVersion="205"
cfStemcell="light-bosh-stemcell-2778-aws-xen-ubuntu-trusty-go_agent.tgz"

cd $HOME

# Generate the key that will be used to ssh between the bastion and the
# microbosh machine
ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa

# Install RVM
gpg --keyserver hkp://keys.gnupg.net --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3
curl -sSL https://get.rvm.io | bash -s stable
~/.rvm/bin/rvm  --static install ruby-2.1.5
~/.rvm/bin/rvm alias create default 2.1.5
source ~/.rvm/environments/default

# Prepare the jumpbox to be able to install ruby and git-based bosh and cf repos

release=$(cat /etc/*release | tr -d '\n')
case "${release}" in
  (*Ubuntu*|*Debian*)
    sudo apt-get update -yq
    sudo apt-get install -yq aptitude
    sudo aptitude -yq install build-essential vim-nox git unzip tree \
      libxslt-dev libxslt1.1 libxslt1-dev libxml2 libxml2-dev \
      libpq-dev libmysqlclient-dev libsqlite3-dev \
      g++ gcc make libc6-dev libreadline6-dev zlib1g-dev libssl-dev libyaml-dev \
      libsqlite3-dev sqlite3 autoconf libgdbm-dev libncurses5-dev automake \
      libtool bison pkg-config libffi-dev
    ;;
  (*Centos*|*RedHat*|*Amazon*)
    sudo yum update -y
    sudo yum install -y epel-release
    sudo yum install -y git unzip xz tree rsync openssl openssl-devel \
    zlib zlib-devel libevent libevent-devel readline readline-devel cmake ntp \
    htop wget tmux gcc g++ autoconf pcre pcre-devel vim-enhanced gcc mysql-devel \
    postgresql-devel postgresql-libs sqlite-devel libxslt-devel libxml2-devel \
    yajl-ruby
    ;;
esac

# Install BOSH CLI, bosh-bootstrap, spiff and other helpful plugins/tools
gem install git -v 1.2.7  #1.2.9.1 is not backwards compatible
gem install bosh_cli -v 1.2915.0 --no-ri --no-rdoc --quiet
gem install bosh_cli_plugin_micro -v 1.2915.0 --no-ri --no-rdoc --quiet
gem install bosh_cli_plugin_aws -v 1.2915.0 --no-ri --no-rdoc --quiet
gem install bosh-bootstrap bosh-workspace --no-ri --no-rdoc --quiet


# We use fog below, and bosh-bootstrap uses it as well
cat <<EOF > ~/.fog
:default:
  :aws_access_key_id: $AWS_KEY_ID
  :aws_secret_access_key: $AWS_ACCESS_KEY
  :region: $REGION
EOF

# This volume is created using terraform in aws-bosh.tf
sudo /sbin/mkfs.ext4 /dev/xvdc
sudo /sbin/e2label /dev/xvdc workspace
echo 'LABEL=workspace /home/ubuntu/workspace ext4 defaults,discard 0 0' | sudo tee -a /etc/fstab
mkdir -p /home/ubuntu/workspace
sudo mount -a
sudo chown -R ubuntu:ubuntu /home/ubuntu/workspace

# As long as we have a large volume to work with, we'll move /tmp over there
# You can always use a bigger /tmp
sudo rsync -avq /tmp/ /home/ubuntu/workspace/tmp/
sudo rm -fR /tmp
sudo ln -s /home/ubuntu/workspace/tmp /tmp

# bosh-bootstrap handles provisioning the microbosh machine and installing bosh
# on it. This is very nice of bosh-bootstrap. Everyone make sure to thank bosh-bootstrap
mkdir -p {bin,workspace/deployments/microbosh,workspace/tools}
pushd workspace/deployments
pushd microbosh
cat <<EOF > settings.yml
---
bosh:
  name: bosh-${VPC}
provider:
  name: aws
  credentials:
    provider: AWS
    aws_access_key_id: ${AWS_KEY_ID}
    aws_secret_access_key: ${AWS_ACCESS_KEY}
  region: ${REGION}
address:
  vpc_id: ${VPC}
  subnet_id: ${BOSH_SUBNET}
  ip: ${boshDirectorHost}
EOF

bosh bootstrap deploy

# We've hardcoded the IP of the microbosh machine, because convenience
bosh -n target https://${boshDirectorHost}:25555
bosh login admin admin
popd

# There is a specific branch of cf-boshworkspace that we use for terraform. This
# may change in the future if we come up with a better way to handle maintaining
# configs in a git repo
git clone --branch  ${CF_BOSHWORKSPACE_VERSION} http://github.com/cloudfoundry-community/cf-boshworkspace
pushd cf-boshworkspace
mkdir -p ssh

# Pull out the UUID of the director - bosh_cli needs it in the deployment to
# know it's hitting the right microbosh instance
DIRECTOR_UUID=$(bosh status --uuid)

# If CF_DOMAIN is set to XIP, then use XIP.IO. Otherwise, use the variable
if [[ $CF_DOMAIN == "XIP" ]]; then
  CF_DOMAIN="${CF_IP}.xip.io"
fi

curl -sOL https://github.com/cloudfoundry-incubator/spiff/releases/download/v1.0.3/spiff_linux_amd64.zip
unzip spiff_linux_amd64.zip
sudo mv ./spiff /usr/local/bin/spiff
rm spiff_linux_amd64.zip

# This is some hackwork to get the configs right. Could be changed in the future
/bin/sed -i \
  -e "s/CF_SUBNET1_AZ/${CF_SUBNET1_AZ}/g" \
  -e "s/CF_SUBNET2_AZ/${CF_SUBNET2_AZ}/g" \
  -e "s/LB_SUBNET1_AZ/${CF_SUBNET1_AZ}/g" \
  -e "s/CF_ELASTIC_IP/${CF_IP}/g" \
  -e "s/CF_SUBNET1/${CF_SUBNET1}/g" \
  -e "s/CF_SUBNET2/${CF_SUBNET2}/g" \
  -e "s/LB_SUBNET1/${LB_SUBNET1}/g" \
  -e "s/DIRECTOR_UUID/${DIRECTOR_UUID}/g" \
  -e "s/CF_DOMAIN/${CF_DOMAIN}/g" \
  -e "s/CF_ADMIN_PASS/${CF_ADMIN_PASS}/g" \
  -e "s/IPMASK/${IPMASK}/g" \
  -e "s/CF_SG/${CF_SG}/g" \
  -e "s/LB_SUBNET1_AZ/${CF_SUBNET1_AZ}/g" \
  deployments/cf-aws-${CF_SIZE}.yml


# Upload the bosh release, set the deployment, and execute
bundle install
bosh upload release https://bosh.io/d/github.com/cloudfoundry/cf-release?v=${cfReleaseVersion}
bosh deployment cf-aws-${CF_SIZE}
bosh prepare deployment || bosh prepare deployment  #Seems to always fail on the first run...

# We locally commit the changes to the repo, so that errant git checkouts don't
# cause havok
git commit -am 'commit of the local deployment configs'

# Keep trying until there is a successful BOSH deploy.
for i in {0..2}
do bosh -n deploy
done

echo "Install Traveling CF"
curl -s https://raw.githubusercontent.com/cloudfoundry-community/traveling-cf-admin/master/scripts/installer | bash
echo 'export PATH=$PATH:$HOME/bin/traveling-cf-admin' >> ~/.bashrc

# Now deploy docker services if requested
if [[ $INSTALL_DOCKER == "true" ]]; then

  cd ~/workspace/deployments
  git clone https://github.com/cloudfoundry-community/docker-services-boshworkspace.git

  echo "Update the docker-aws-vpc.yml with cf-boshworkspace parameters"
  /home/ubuntu/workspace/deployments/docker-services-boshworkspace/shell/populate-docker-aws-vpc
  dockerDeploymentManifest="/home/ubuntu/workspace/deployments/docker-services-boshworkspace/deployments/docker-aws-vpc.yml"
  /bin/sed -i "s/SUBNET_ID/${DOCKER_SUBNET}/g" "${dockerDeploymentManifest}"

  cd ~/workspace/deployments/docker-services-boshworkspace
  bundle install
  bosh deployment docker-aws-vpc
  bosh prepare deployment

  # Keep trying until there is a successful BOSH deploy.
  for i in {0..2}
  do bosh -n deploy
  done

fi

# FIXME: enable this again when smoke_tests work
# bosh run errand smoke_tests
