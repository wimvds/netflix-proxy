#!/bin/bash

# Note, this script assumes Ubuntu Linux and it will most likely fail on any other distribution.

# bomb on any error
set -e

# change to working directory
root="/opt/netflix-proxy"

# obtain the interface with the default gateway say
int=$(ip route | grep default | awk '{print $5}')

# obtain IP address of the Internet facing interface
ipaddr=$(ip addr show dev $int | grep inet | grep -v inet6 | awk '{print $2}' | grep -Po '[0-9]{1,3}+\.[0-9]{1,3}+\.[0-9]{1,3}+\.[0-9]{1,3}+(?=\/)')
extip=$($(which dig) +short myip.opendns.com @resolver1.opendns.com)

# obtain client (home) ip address
clientip=$(echo $SSH_CONNECTION | awk '{print $1}')

# get the current date
date=$(/bin/date +'%Y%m%d')

# display usage
usage() {
	echo "Usage: $0 [-r 0|1] [-b 0|1]" 1>&2; \
	printf "\t-r\tenable (1) or disable (0) DNS recursion (default: 1)\n"; \
        printf "\t-b\tgrab docker images from repository (0) or build locally (1) (default: 0)\n"; \
	exit 1;
}

# process options
while getopts ":r:b:" o; do
    case "${o}" in
        r)
            r=${OPTARG}
            ((r == 0|| r == 1)) || usage
            ;;
        b)
            b=${OPTARG}
            ((b == 0|| b == 1)) || usage
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

if [[ -z "${r}" ]]; then
	r=1
fi

if [[ -z "${b}" ]]; then
        b=0
fi

# prepare BIND config
if [[ ${r} == 0 ]]; then
	printf "disabling DNS recursion...\n"
	printf "\t\tallow-recursion { none; };\n\t\trecursion no;\n\t\tadditional-from-auth no;\n\t\tadditional-from-cache no;\n" > ${root}/docker-bind/named.recursion.conf
else
	printf "WARNING: enabling DNS recursion...\n"
	printf "\t\tallow-recursion { trusted; };\n\t\trecursion yes;\n\t\tadditional-from-auth yes;\n\t\tadditional-from-cache yes;\n" > ${root}/docker-bind/named.recursion.conf	
fi

# switch to working directory
pushd ${root}

# configure iptables
sudo iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A INPUT -p icmp -j ACCEPT
sudo iptables -A INPUT -i lo -j ACCEPT
sudo iptables -A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT
sudo iptables -A INPUT -s $clientip/32 -p tcp -m tcp --dport 80 -j ACCEPT
sudo iptables -A INPUT -s $clientip/32 -p tcp -m tcp --dport 443 -j ACCEPT
sudo iptables -A INPUT -j REJECT --reject-with icmp-host-prohibited
sudo iptables -A FORWARD -j REJECT --reject-with icmp-host-prohibited
sudo iptables -A DOCKER -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A DOCKER -p icmp -j ACCEPT
sudo iptables -A DOCKER -s $clientip/32 -p udp -m udp --dport 53 -j ACCEPT
sudo iptables -A DOCKER -j REJECT --reject-with icmp-host-prohibited
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
sudo apt-get -y install iptables-persistent

echo "Updating db.override with ipaddr"=$extip "and date="$date
sudo $(which sed) -i "s/127.0.0.1/${extip}/g" data/db.override
sudo $(which sed) -i "s/YYYYMMDD/${date}/g" data/db.override

if [[ "${b}" == "1" ]]; then
	echo "Building docker containers"
	$(which docker) build -t bind docker-bind
	$(which docker) build -t sniproxy docker-sniproxy

	echo "Starting Docker containers (local)"
	sudo $(which docker) run --name bind -d -v ${root}/data:/data -p 53:53/udp -t bind
	sudo $(which docker) run --name sniproxy -d -v ${root}/data:/data --net=host -t sniproxy
else
	echo "Starting Docker containersi (from repository)"
	sudo $(which docker) run --name bind -d -v ${root}/data:/data -p 53:53/udp -t ab77/bind
	sudo $(which docker) run --name sniproxy -d -v ${root}/data:/data --net=host -t ab77/sniproxy
fi

echo "Testing DNS"
$(which dig) netflix.com @$ipaddr

echo "Testing proxy"
echo "GET /" | $(which openssl) s_client -servername netflix.com -connect $ipaddr:443

# configure upstart
sudo cp init/* /etc/init

# change back to original directory
popd

echo "Change your DNS to" $extip "and start watching Netflix out of region."
echo "Done!"
