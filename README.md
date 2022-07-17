# Решения задач лекуии 8.2

В качестве инфраструктуры были выбраны контейнеры **Docker**, а именно две машины на основе образа `centos:7`

```yaml
clickhouse:
  hosts:
    clickhouse-01:
      ansible_connection: docker
vector:
  hosts:
    vector-01:
      ansible_connection: docker
```
В образах `centos:7` нет покета `sudo`, поэтому он устанавливается для всех хостов

Из-за особенности работы связки **Ansible**, контейнеров и самого **Docker** в режиме **rootless** функционирование **systemctl** внури контейнера ограничено, поэтому его функционал заменён скриптом [docker-systemctl-replacement](https://github.com/gdraheim/docker-systemctl-replacement)

