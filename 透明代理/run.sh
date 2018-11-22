#!/bin/bash

if ! [ -e ss.json ]; then
	echo "Missing SS config file"
	exit 1
fi

if [ -e /tmp/ss-tunnel.pid ]; then
	echo "Kill ss-tunnel"
	kill -9 `cat /tmp/ss-tunnel.pid`
	rm -rf /tmp/ss-tunnel.pid
fi

if [ -e /tmp/ss-redir.pid ]; then
	echo "kill ss-redir"
	kill -9 `cat /tmp/ss-redir.pid`
	rm -rf /tmp/ss-redir.pid
fi

sudo sysctl -w net.ipv4.ip_forward=1

ss-redir -c ss.json -b 0.0.0.0  -u -f /tmp/ss-redir.pid
ss-tunnel -c ss.json  -b 0.0.0.0 -l 5353 -L 8.8.8.8:53 -u -f /tmp/ss-tunnel.pid 

sudo iptables -F
sudo iptables -t  nat  -F

sudo ipset create gfwlist hash:ip family inet timeout 86400
echo "gfwlist creat success"
rm -rf dnsmasq.conf
./gfwlist2dnsmasq.sh -p 5353 -s gfwlist -o dnsmasq.conf 
echo "server=114.114.114.114" >> dnsmasq.conf
echo "interface=wlan0" >> dnsmasq.conf
echo "dhcp-range=192.168.13.2,192.168.13.31,12h"
echo "dnsmasq gen sucess"
sudo cp dnsmasq.conf /etc/
sudo service dnsmasq restart

echo "Fetch China ip set"
curl -sL http://f.ip.cn/rt/chnroutes.txt | egrep -v '^$|^#' > cidr_cn
sudo ipset destroy cidr_cn
echo "seting ipset addr"
sudo ipset -N cidr_cn hash:net
echo "ipset hash success"
rm -rf ipset.sh
for i in `cat cidr_cn`; do echo ipset -A cidr_cn $i >> ipset.sh; done
chmod +x ipset.sh && sudo ./ipset.sh
echo "finish ipset"

#config WLAN
#sudo hostapd `$(pwd)`/hostapd.conf
sudo ifconfig wlan0 192.168.13.1/24

#set dns on wlan
#sudo dnsmasq --listen-address=192.168.13.1 --dhcp-range=192.168.13.2,192.168.13.31,2h --dhcp-option=3,192.168.13.1 #--dhcp-option=option:dns-server,8.8.8.8,114.114.114.114

echo "setup forward for eth0 and wlan0" 
sudo iptables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT

#accecpt all net data 
sudo iptables -A FORWARD -j ACCEPT

sudo iptables -t nat -N shadowsocks
#jump to shadowsocks config except icmp
sudo iptables -t nat -A PREROUTING ! -p icmp -j shadowsocks

#jump private address
sudo iptables -t nat -A shadowsocks -d 0.0.0.0/8 -j RETURN
sudo iptables -t nat -A shadowsocks -d 10.0.0.0/8 -j RETURN
sudo iptables -t nat -A shadowsocks -d 127.0.0.0/8 -j RETURN
sudo iptables -t nat -A shadowsocks -d 169.254.0.0/16 -j RETURN
sudo iptables -t nat -A shadowsocks -d 172.16.0.0/12 -j RETURN
sudo iptables -t nat -A shadowsocks -d 192.168.0.0/15 -j RETURN
sudo iptables -t nat -A shadowsocks -d 224.0.0.0/4 -j RETURN
sudo iptables -t nat -A shadowsocks -d 240.0.0.0/4 -j RETURN

#jump the ss-server address
sudo iptables -t nat -A shadowsocks -d ss-server-ip -j RETURN

#set data routing
sudo iptables -t nat -A shadowsocks -m set --match-set cidr_cn dst -j RETURN
sudo iptables -t nat -A shadowsocks ! -p icmp -m set --match-set gfwlist dst -j  REDIRECT --to-ports 1082

#routing non proxy data to WAN
sudo iptables -t nat -A POSTROUTING -o usb0 -j MASQUERADE

echo "finish config iptables"

sudo cp ./hostap.conf /etc/hostapd/
PWD=`pwd`
sudo hostapd $PWD/hostap.conf &
sudo service dnsmasq restart

echo "hostap start"
