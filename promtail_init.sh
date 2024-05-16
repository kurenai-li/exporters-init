#!/bin/bash

# Initialization
IP=127.0.0.1:3100
INSTALLPATH=/data/exporters/promtail
PORT=0
HOSTNAME=$(echo `hostname` | sed 's/\b[a-z]/\U&/g')
HOSTIP=$(curl ifconfig.me)

helpinfo () {
    printf "Usage:  bash promtail_init.sh [OPTIONS]\n\n"
    printf "Auto install & config promtail and register it into systemd\n\n"
    printf "Options:\n"
    printf "%-2s%-16s %s\n" "" "-h, --help" "Show help"
    printf "%-2s%-16s %s\n" "" "-u, --url" "Url of promtail package"
    printf "%-2s%-16s %s\n" "" "-i, --ip" "Server address of loki, (default \"127.0.0.1:3100\")"
    printf "%-2s%-16s %s\n" "" "-p, --port" "Port of promtail service (default \"0\" for not use http server)"
    printf "%-6s%-12s %s\n" "" "--path" "Location of promtail install path, (default \"/data/exporters/prometail\")"
    printf "%-6s%-12s %s\n" "" "--hostname" "Hostname of server, (default use titled hostname)"
    printf "%-6s%-12s %s\n" "" "--hostip" "Location of promtail install path, (default use ifconfig.me ip)"
    printf "%-2s%-16s %s\n" "" "-a, --auth" "Basic auth string of Loki server, string likes 'user,passed' split with comma, default with no basic auth"
}

# Parse args
SHORTOPTS="h,u:i::p::a::"
LONGOPTS="help,url:,ip::,path::,port::,hostname::,hostip::,auth::"
ARGS=$(getopt --options $SHORTOPTS --longoptions $LONGOPTS -- "$@" )

if [ $? != 0 ] ; then echo "Parse error! Terminating..." >&2 ; exit 1 ; fi

eval set -- "$ARGS"

while true ; do
    case "$1" in
        -h|--help) helpinfo ; exit ;;
        -u|--url) URL="$2" ; shift 2 ;;
        -i|--ip) IP="$2"; shift 2 ;;
        -p|--port) PORT="$2" ; shift 2 ;;
        --path) INSTALLPATH="$2" ; shift 2 ;;
        --hostname) HOSTNAME="$2" ; shift 2 ;;
        --hostip) HOSTIP="$2" ; shift 2 ;;
        -a|--auth) BASICAUTH="$2" ; shift 2 ;;
        --) shift ; break ;;
        *) echo "Args error!" ; exit 1 ;;
    esac
done

# Make path and download binary package
mkdir -p /downloads
mkdir -p /data
mkdir -p $INSTALLPATH
curl $URL -o /downloads/promtail.zip
unzip /downloads/promtail.zip -d $INSTALLPATH
INSTALLPATH=$(find $INSTALLPATH -name "promtail*" -size +1M | sed "s/\/promtail[^\/].*$//g")

# Create config file
cat << EOF > $INSTALLPATH/config.yaml
server:
  http_listen_port: $PORT
  grpc_listen_port: 0
positions:
  filename: $INSTALLPATH/positions.yaml
clients:
  - url: http://$IP/loki/api/v1/push
scrape_configs:
  - job_name: journal
    journal:
      json: false
      max_age: 72h
      path: /var/log/journal
      labels:
        os_varlogs: journal
        hostname: $HOSTNAME
        hostip: $HOSTIP
        __path__: /var/log/journal
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: 'unit'
EOF

# Config basic auth to config.yaml is exist
if [ $BASICAUTH ]; then
    AUTH=(`echo ${BASICAUTH} | tr ',' ' '`)
    sed -i "7a\    basic_auth:\n      username: ${AUTH[0]}\n      password: ${AUTH[1]}" $INSTALLPATH/config.yaml
fi

# Create user and config systemd file
useradd -rs /bin/false promtail
usermod -a -G systemd-journal promtail
chown -R promtail:promtail $INSTALLPATH
cat << EOF > /lib/systemd/system/promtail.service
[Unit]
Description=Promtail
After=network.target
 
[Service]
User=promtail
Group=promtail
Type=simple
ExecStart=$INSTALLPATH/promtail-linux-amd64 -config.file=$INSTALLPATH/config.yaml
ExecReload=/bin/kill -s HUP
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TimeoutStartSec=0
Delegate=yes
KillMode=process
Restart=on-failure
StartLimitBurst=3
StartLimitInterval=60s

[Install]
WantedBy=multi-user.target
EOF

# Enable and start service
systemctl daemon-reload
systemctl enable promtail
systemctl restart promtail
systemctl status promtail
