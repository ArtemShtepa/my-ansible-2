# Решения задач лекции 8.2 Работа с Playbook

**Playbook** (`site.yml`) состоит из трех **play**.

## Первый **play** (`Install sudo and systemctl`)

Из-за особенности работы связки **Ansible**, контейнеров и самого **Docker** в режиме **rootless** функционирование **systemctl** внури контейнера ограничено, поэтому его функционал частично заменяется скриптом [docker-systemctl-replacement](https://github.com/gdraheim/docker-systemctl-replacement).
Также используемый образ `centos:7` не содержит пакета `sudo`.

Поэтому данный **play** выполняет подготовку образов, а именно:
- Установку пакета `sudo`
- Установка скрипта обеспечения функционала `systemctl` внутри контейнера **Docker**
- Создаёт директорию `/run/systemd/system` для однозначного определения модулем `ansible.builtin.service` использовать пакет `systemd`

## Второй **play** (`Install Clickhouse`) производит установку **Clickhouse**:

Все задачи разделены на обычные (`tasks`) и пост-задачи (`post_tasks`).

Обычные `tasks` выполняют установку **Clickhouse**, а именно:
- Скачивание пакетов дистрибутива (`Download clickhouse distrib`) в блоке с функционалом `rescue`
- Установку загруженных пакетов (`Install clickhouse packages`)
- Копирование конфигурационных файлов хоста и пользователя для **Clickhouse** (`Configure clickhouse host bind`)

После установки **Clickhouse** и перед его использованием нужно запустить демона `clickhouse-server`,
для чего остальные задачи перенесены в `post_tasks`, а последние два шага **tasks** требуют выполнения соответствующего **handler** перезапуска демона `Start clickhouse service`.
Данное разделение можно избежать добавив отдельную **task** с модулем `ansible.builtin.meta` следующим образом:

```yaml
- name: Force all notified handlers to run
  ansible.builtin.meta: flush_handlers
```

Следующие **post_tasks** выполняют:
- Проверку функционирования демона `clickhouse-server` и если он не запущен, запускает (`Bring clickhouse alive if docker restart`). Выполняется только при использовании подключения **docker**, так как при перезапуске контейнеров демон не стартует автоматически.
- Создание базы `logs` в **Clickhouse** (`Create database`)
- Создание таблицы `file_log` в **Clickhouse** (`Create tables`)

## Третий **play** (`Install Vector`) выполняет установку **Vector**:

Задачи также разделены на обычные (`tasks`) и пост-задачи (`post_tasks`).

Основные **tasks**:
- Загружают архив дистрибутива **Vector** нужной версии (`Download distrib`)
- Создаёт в системе группу `vector` для запуска **Vector** в **rootless** режиме (`Create vector group`)
- Создаёт пользователя `vector` и добавляет его в группу `vector`. Также используется для запуска **Vector** в **rootless** режиме (`Create vector user`)
- Распаковывает архив **Vector** по-сути во временный каталог (`Unpack vector distrib`). Файлы в этом каталоге в дальнейшей работе не будут использоваться, поэтому загрузку дистрибутива можно [делегировать](https://docs.ansible.com/ansible/latest/user_guide/playbooks_delegation.html) на управляющую машину (**control node**)
- Устанавливает исполняемый файл и файл демоны по системным путям (`Install vector executable`)
- Создаёт каталоги для данных **Vector** и отслеживаемых изменений в файлах (`Create vector directories`)
- Создаёт конфигурационный файл **Vector** на основе шаблона `vector.toml.j2` с использованием модуля `ansible.builtin.template` (`Install vector configuration`)

Единственная пост-задача производит проверку функционирования демона `vector` и если он не запущен, запускает (`Bring vector alive if docker restart`). Выполняется только при использовании подключения **docker**, так как при перезапуске контейнеров демон не стартует автоматически.

## Параметры

Для группы **clickhouse** применяются:

- `clickhouse_version` - версия **Clickhouse**, которую нужно использовать
- `clickhouse_packages` - список архивов компонентов **Clickhouse**, которые нужно скачать и установить
- `file_log_structure` - структура таблицы логов, которая будет использоваться для хранения поступающих от **Vector** данных

Для группы **vector** применяются:

- `vector_version` - версия **Vector**, которую нужно использовать
- `vector_datadir` - каталог, который будет использовать **Vector** для хранения своих данных

## Теги

В данном **playbook** используются теги:

- `docker`, **tasks** которых нужны только при использовании подключения `docker`
- Тегом `db` помечены **tasks** связанные с созданием базы данных и таблицы **Clickhouse**
