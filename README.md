# Traffic-Burnig
一个基于Speedtest的流量燃烧器，帮助你消耗闲置小鸡的流量

原理基于[speedtest](https://github.com/sivel/speedtest-cli)

# 使用方法
Debian/Ubuntu
```
apt update -y && apt install wget bash curl screen -y
screen -S Traffic-Buring
bash <(curl -Ls https://raw.githubusercontent.com/Miku-Miku-Miku-Miku/Traffic-Burnig/main/traffic-burning.sh)
Ctrl + A + D
```

Centos
```
yum update -y && yum install wget bash curl screen -y
screen -S Traffic-Buring
bash <(curl -Ls https://raw.githubusercontent.com/Miku-Miku-Miku-Miku/Traffic-Burnig/main/traffic-burning.sh)
Ctrl + A + D
```
#关于后台运行
本项目采用了对于小白而言通俗易懂的screen运行
亦可采用Systemctl等方式，在此不过多赘述
