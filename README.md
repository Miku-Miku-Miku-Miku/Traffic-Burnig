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
# 运行效果
![contents](https://github.com/Miku-Miku-Miku-Miku/Traffic-Burnig/blob/main/demo.png)

# 关于后台运行
本项目采用了对于小白而言通俗易懂的screen运行
亦可采用Systemctl等方式，在此不过多赘述

# 如果觉得本项目对你有所帮助的话，欢迎点一个Star
