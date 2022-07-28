# Решения задач лекции 8.3 Использование Yandex Cloud

В качестве инфраструктуры используется **Яндекс.Облако**.
Разворачивание автоматизировано при помощи **Terraform** с использованием провайдера и интерфейса командной строки **Яндекс.Облака**: [main.tf](main.tf)

Большинство используемых действий (например, разворачивание, настройка и уничтожение инфраструктуры) внесены в **Bash** скрипт: [go.sh](go.sh)

Для настройки хостов предварительно подготовлены статические файлы:
- Настройки **Clickhouse** для подключения со всех хостов: [files/clickhouse.yml](files/clickhouse.yml)
- Настройка пользователя **logger** для СУБД **Clickhouse**: [files/logger.yml](files/logger.yml)
- Настройка web сервера **Lighthouse** для демона **nginx**: [files/lighthouse.conf](files/lighthouse.conf)

А также шаблоны:
- Настройки **Vector** как сервиса: [templates/vector.service.j2](templates/vector.service.j2)
- Конфигурационный файл **Vector** с настройков хоста **Clickhouse**: [templates/vector.toml.j2](templates/vector.toml.j2)

Доступны следующие переменные:
- `clickhouse_version` - Версия **Clickhouse**, которая будет использоваться ([group_vars/clickhouse.yml](group_vars/clickhouse.yml))
- `clickhouse_packages` - Список пакетов, которые нужно скачать и установить для функционирования **Clickhouse** ([group_vars/clickhouse.yml](group_vars/clickhouse.yml))
- `file_log_structure` - Структура таблицы, в которую будут сохраняться данные метрик от **Vector** ([group_vars/clickhouse.yml](group_vars/clickhouse.yml))
- `vector_version` - Версия **Vector**, которая будет использоваться ([group_vars/vector.yml](group_vars/vector.yml))
- `vector_datadir` - Каталог для хранения данных **Vector** ([group_vars/vector.yml](group_vars/vector.yml))
- `vector_config` - Путь к конфигурационному файлу **Vector** ([group_vars/vector.yml](group_vars/vector.yml))
- `vector_test_dir` - Каталог, где **Vector** будет искать файлы в качестве **sources** ([group_vars/vector.yml](group_vars/vector.yml))
- `lighthouse_repo` - Адрес репозитория **VK Lighthouse** ([group_vars/lighthouse.yml](group_vars/lighthouse.yml))
- `lighthouse_branch` - Ветка, которая будет извлекаться для **VK Lighthouse** ([group_vars/lighthouse.yml](group_vars/lighthouse.yml))
- `lighthouse_path` - Путь, где будут расположены файлы **VK Lighthouse** ([group_vars/lighthouse.yml](group_vars/lighthouse.yml))

**Inventory** будет генерироваться динамически, поэтому соответствующий файл представлен только шаблоном групп:

```yaml
---
clickhouse:
  hosts:
vector:
  hosts:
lighthouse:
  hosts:
...
```
Проект состоит из 6 **play**:

1. Генерирование диманического **inventory**: `Generate dynamic inventory`
1. Добавление хостов в список известных: `Approve SSH fingerprint`
1. Установка **Clickhouse**: `Install Clickhouse`
1. Установка **Vector**: `Install Vector`
1. Установка **Lighthouse** включая **nginx**: `Install Lighthouse`
1. Вывод IP адресов сервисов: `Echo instances hint`

## Генерирование диманического **inventory** `Generate dynamic inventory`

Для получения списка хостов используется интерфейс **Yandex.Cloud CLI**, а именно команда получения списка **instance** в формате **YAML**, который можно прочитать внутри **Ansible**
Логично, выполнение шага производится только для **localhost**

Команда получения хостов выглядит следующим образом: `yc compute instance list --format=yaml`, соответственно для её выполнения используется модуль `ansible.builtin.command`:
```yaml
    - name: Get instances from Yandex.Cloud CLI
      ansible.builtin.command: "yc compute instance list --format=yaml"
      register: yc_instances
      failed_when: yc_instances.rc != 0
      changed_when: false
```
Её вывод регистрируется в переменную `yc_instances`.
Успешность определяется кодом возврата (`yc_instances.rc`).
Считается, что данный шаг может быть либо `ok`, либо `failed`

---

На следующем шаге выполняется преобразование вывода комманды **Yandex.Cloud CLI** в блок **YAML**
```yaml
    - name: Set instances to facts
      ansible.builtin.set_fact:
        _yc_instances: "{{ yc_instances.stdout | from_yaml }}"
```
Результат фиксируется в фактах с именем `_yc_instances`

---

Далее для каждого элемента из `_yc_instance` выполняется добавление хоста в группу на основе имени машины (`group: "{{ item['name'] }}"`)
```yaml
    - name: Add instances IP to hosts
      ansible.builtin.add_host:
        name: "{{ item['network_interfaces'][0]['primary_v4_address']['one_to_one_nat']['address'] }}"
        group: "{{ item['name'] }}"
        ansible_ssh_user: "centos"
      loop: "{{ _yc_instances }}"
      changed_when: false
```
При этом используется модуль `ansible.builtin.add_host` где в качестве группы передаётся название хоста. А также устанавливается пользователь (`ansible_ssh_user`) для подключения по SSH.
Считается, что шаг всегда завершается со статусом `ok`.

---

Последний шаг служит индикатором успеха формирования динамического **inventory** на основе числа полученных **instance**
```yaml
    - name: Check instance count
      ansible.builtin.debug:
        msg: "Total instance count: {{ _yc_instances | length }}"
      failed_when: _yc_instances | length == 0
```

---

## Добавление хостов в список известных `Approve SSH fingerprint`

**Play** предназначен для автоматизации процесса добавления хостов в список известных без изменения настроек SSH клиентиа. Следовательно, выполняется для всех полученных хостов.
Сбор артефактов всегда приводит к подключению к хостам, а значит для данного **play** ег осбор нужно отключить (`gather_facts: false`)

Первый шаг выполняет запрос поиска отпечатка сервера в базе известных командой `ssh-keygen -F <хост>`, где `<хост>` - IP адрес сервиса
```yaml
    - name: Check known_hosts for
      ansible.builtin.command: ssh-keygen -F {{ inventory_hostname }}
      register: check_entry_in_known_hosts
      failed_when: false
      changed_when: false
      ignore_errors: true
      delegate_to: localhost
```
Так как команда должны быть выполнена на управляющей ноде, то присутствует делегирование на **localhost** (опция `delegate_to:`)
Во избежания краха всего playbook при отсутствии отпечатка ошибки на в данной **task** игнорируются (`ignore_errors: true`).
Также считается что команда всегда выполняется успешно (комбинация `failed_when: false` и `changed_when: false`). Результат фиксируется в переменной `check_entry_in_known_hosts`

Если отпечатка хоста нет в списке известных, то команда `ssh-keygen -F` выполнится с кодом завершения `1`.
В этом случае нужно отключить запрос на добавление хоста в список известных дабовив опцию `-o StrictHostKeyChecking=no` для клиента SSH.
Данные действия выполняются в следующей **task**
```yaml
    - name: Skip question for adding host key
      ansible.builtin.set_fact:
        # StrictHostKeyChecking can be "accept-new"
        ansible_ssh_common_args: "-o StrictHostKeyChecking=no"
      when: check_entry_in_known_hosts.rc == 1
```

Последнй шаг - запуск сбора артефактов с целью добавления хостов в список известных в ходе подключения к ним
```yaml
    - name: Add SSH fingerprint to known host
      ansible.builtin.setup:
      when: check_entry_in_known_hosts.rc == 1
```

---

## Установка **Clickhouse**: `Install Clickhouse`

**Play** содержит один **handler** предназначенный для перезапуска демона **Clickhouse-server**:

```yaml
    - name: Start clickhouse service
      become: true
      ansible.builtin.service:
        name: clickhouse-server
        enabled: true
        state: restarted
```

Все задачи данного **play** разделены на две группы: `tasks` для непосредственно установка **Clickhouse** и `post_tasks` для создания структуры БД

### Основные задачи (`tasks`):

Первый шаг - блок из двух **taks**, одна из которых (`rescue`) выполняется при провале выполнения первой.
Основная **task** выполняет загрузку файлов из списка `clickhouse_packages` и если что-то загрузить не удастся будет выполняться загрузка альтернативного пакета.
```yaml
    - name: Download clickhouse distrib
      block:
        - name: Get clickhouse noarch distrib
          ansible.builtin.get_url:
            url: "https://packages.clickhouse.com/rpm/stable/{{ item }}-{{ clickhouse_version }}.noarch.rpm"
            dest: "./{{ item }}-{{ clickhouse_version }}.rpm"
            mode: +rw
          loop: "{{ clickhouse_packages }}"
      rescue:
        - name: Get clickhouse static distrib
          ansible.builtin.get_url:
            url: "https://packages.clickhouse.com/rpm/stable/clickhouse-common-static-{{ clickhouse_version }}.x86_64.rpm"
            dest: "./clickhouse-common-static-{{ clickhouse_version }}.rpm"
            mode: +rw
```

Шаг установка скаченных пакетов через пакетный менеджер `yum`.
При успехе устанавливается запрос на исполнение **handler**.
```yaml
    - name: Install clickhouse packages
      become: true
      ansible.builtin.yum:
        name:
          - clickhouse-common-static-{{ clickhouse_version }}.rpm
          - clickhouse-client-{{ clickhouse_version }}.rpm
          - clickhouse-server-{{ clickhouse_version }}.rpm
      notify: Start clickhouse service
```

Шаг конфигурирования **Clickhouse** путём копирования (модуль `ansible.builtin.copy`) подготовленных файлов на целевую машину.
Скопированным файлам устанавливается владелец (`owner:`), группа (`group:`) и права доступа (`mode:`).
Применяется параметризрованный цикл **loop**.
При успехе устанавливается запрос на исполнение **handler**.
```yaml
    - name: Configure clickhouse host bind
      become: true
      ansible.builtin.copy:
        src: "{{ item.src }}"
        dest: "{{ item.dest }}"
        mode: "0644"
        owner: "clickhouse"
        group: "clickhouse"
      loop:
        - { src: 'clickhouse.yml', dest: '/etc/clickhouse-server/config.d/all-hosts.yml' }
        - { src: 'logger.yml', dest: '/etc/clickhouse-server/users.d/logger.yml' }
      notify: Start clickhouse service
```

### Дополнительные задачи (`post_tasks`):

В некоторых случаях после старта демона **Clickhouse-server** СУБД какое-то время может быть недоступна для подключения.
Чтобы невилировать данную особенность введена первая **task**, задача которой состоит только в ожидании успешного подключения к СУБД.
Для этого используется повтор выполнения задачи (`retries: 3`) с паузой в **5** секунд (`delay: 5`) между попытками.
Повтор выполняется до тех пор, пока результат выполнения команды, зарегистрированный в переменной `check_db` не станет равер нуля, то есть выполнится успешно.
```yaml
    - name: Check clickhouse active
      ansible.builtin.command: "clickhouse-client --host 127.0.0.1 -q 'SHOW DATABASES;'"
      register: check_db
      failed_when: check_db.rc != 0
      changed_when: false
      retries: 3
      delay: 5
      until: check_db.rc == 0
```

Создание базы используя клиента **clickhouse-client**.
Успех определяется по коду возврата команды.
Успешное выполнение **SQL** команды (код `0`) говорит о том, что база создана - статус `changed`.
Если база уже существует, то код возврата будет равен `82`.
Любой другой код возврата автоматически говорит о какой-то ошибке СУБД.
Следовательно крах задачи должен включать оба последних условия, то есть `create_db.rc != 0` и `create_db.rc != 82`.
```yaml
    - name: Create database
      ansible.builtin.command: "clickhouse-client --host 127.0.0.1 -q 'CREATE DATABASE logs;'"
      register: create_db
      failed_when: create_db.rc != 0 and create_db.rc != 82
      changed_when: create_db.rc == 0
```

Создание таблицы используя клиент **clickhouse-client**.
Успех также определяется по коду возврата команды.
Успешное выполнение **SQL** команды (код `0`) говорит о том, что таблица отсутствовала и была успешно создана - статус `changed`.
Если таблица уже существовала, то код возврата будет равен `57` (проверено опытным путём).
Любой другой код возврата автоматически говорит о какой-то ошибке СУБД.
Следовательно крах задачи должен включать оба последних условия, то есть `create_tbl.rc != 0` и `create_tbl.rc != 57`.
```yaml
    - name: Create tables
      ansible.builtin.command: "clickhouse-client --host 127.0.0.1 -q 'CREATE TABLE logs.file_log ({{ file_log_structure }}) ENGINE = Log();'"
      register: create_tbl
      failed_when: create_tbl.rc != 0 and create_tbl.rc != 57
      changed_when: create_tbl.rc == 0
```

---

## Установка **Vector**: `Install Vector`

**Play** содержит один **handler** предназначенный для перезапуска демона **Vector**:
```yaml
    - name: Start vector service
      become: true
      ansible.builtin.service:
        name: "vector"
        enabled: true
        state: restarted
```

Задачи (`tasks`):

Загрузка архива дистрибутива:
```yaml
    - name: Download distrib
      ansible.builtin.get_url:
        url: "https://packages.timber.io/vector/{{ vector_version }}/vector-{{ vector_version }}-x86_64-unknown-linux-musl.tar.gz"
        dest: "~/vector-{{ vector_version }}.tar.gz"
        mode: +rw
```

Создание каталога с использованием модуля `ansible.builtin.file`:
```yaml
    - name: Create distrib directory
      ansible.builtin.file:
        path: "~/vector"
        state: directory
        mode: "u+rwx,g+r,o+r"
```

Распаковка архива - выполняется модулем `ansible.builtin.unarchive` с передачей дополнительных параметров (`extra_opts`).
Для того чтобы определить получившийся в итоге путь результат выполнения команды регистрируется в переменной `unpack_res`.
```yaml
    - name: Unpack vector distrib
      ansible.builtin.unarchive:
        src: "~/vector-{{ vector_version }}.tar.gz"
        remote_src: true
        dest: "~/vector"
        extra_opts: ["--strip-components=2"]
      register: unpack_res
```

Копирование исполняемого файла из каталога распакованного архива в каталог `/usr/bin`.
Путь директории составляется из переменной, полученной при распаковке архива (`unpack_res['dest']`).
При успехе устанавливается запрос на исполнение **handler**.
```yaml
    - name: Install vector executable
      become: true
      ansible.builtin.copy:
        src: "{{ unpack_res['dest'] }}/bin/vector"
        remote_src: true
        dest: "/usr/bin/vector"
        mode: "+x"
      notify: Start vector service
```

Создание необходимых для функционирования **vector** каталогов.
Шаг выполняется с повышенными правами (`become: true`), так как каталоги расположены в системных областях.
```yaml
    - name: Create vector directories
      become: true
      ansible.builtin.file:
        path: "{{ item }}"
        state: directory
        recurse: true
      loop:
        - "{{ vector_datadir }}"
        - "/etc/vector"
```

Создание каталога для входного **Vector source**.
Шаг отделён от предыдущего, так как повышенных прав он не требует.
```yaml
    - name: Create test directory
      ansible.builtin.file:
        path: "{{ vector_test_dir }}"
        state: directory
        mode: "u+rwx,g+rx,o+r"
```

Создание конфигурационного файла **Vector** на основе шаблона `vector.toml.j2`.
Используется модуль `ansible.builtin.template`.
При успехе устанавливается запрос на исполнение **handler**.
```yaml
    - name: Install vector configuration
      become: true
      ansible.builtin.template:
        src: vector.toml.j2
        dest: "{{ vector_config }}"
        mode: "0644"
      notify: Start vector service
```

Создание файла сервиса на основе шаблона `vector.service.j2`.
Используется модуль `ansible.builtin.template`.
```yaml
    - name: Install vector service file
      become: true
      ansible.builtin.template:
        src: vector.service.j2
        dest: "/usr/lib/systemd/system/vector.service"
        mode: "0644"
```

Установка автозапуска (`state: enabled`) сервиса **Vector** с использованием модуля `ansible.builtin.service`.
```yaml
    - name: Enable vector service
      become: true
      ansible.builtin.service:
        name: "vector"
        enabled: true
        state: started
```

---

## Установка **Lighthouse** включая **nginx**: `Install Lighthouse`

**Play** содержит один **handler** предназначенный для перезапуска демона **nginx**:

```yaml
    - name: Restart nginx
      become: true
      ansible.builtin.service:
        name: nginx
        state: restarted
```

Все задачи данного **play** разделены на две группы: `pre_tasks` для подготовки машины (установки пакетов) и `tasks` для установки и настройки **Lighthouse**

### Подготовительные задачи (`pre_tasks`):

Установка обновлений для ОС **Centos7** (используется условие из собранных фактов - `when`).
Без установки данного обновления не получится установить пакет **nginx**, так как в репозиториях по умолчанию его нет.
```yaml
    - name: Install epel-release for centos7
      become: true
      ansible.builtin.yum:
        name: "epel-release"
        state: present
      when: ansible_facts['distribution'] == "CentOS"
```

Установка пакетов **nginx** и **git** стандартным способом (`ansible.builtin.package`) с использованием консирукции `loop`
```yaml
    - name: Install NGinX and Git
      become: true
      ansible.builtin.package:
        name: "{{ item }}"
        state: present
      loop:
        - "nginx"
        - "git"
```

### Основные задачи (`tasks`):

**Task** проверки клонировали до этого репозиторий **Lighthouse**.
Проверяется наличия файла `app.js` по пути установки **Lighthouse**.
Чтобы весь **play** не завершался из-за отсутствия файла, ошибки на данном этапе игнорируются (`ignore_errors: true`)
```yaml
    - name: Check lighthouse files
      ansible.builtin.file:
        path: "{{ lighthouse_path }}/app.js"
        state: file
      register: lh_exists
      ignore_errors: true
```

Клонирование репозитория **Lighthouse** с версией/меткой `lighthouse_branch` через модуль `ansible.builtin.git`.
Шаг выполняется по условию (`when:`) и только тогда, когда один из файлов **Lighthouse** отсутствует (`lh_exists.state == "absent"`).
```yaml
    - name: Clone VK Lighthouse
      become: true
      ansible.builtin.git:
        repo: "{{ lighthouse_repo }}"
        dest: "{{ lighthouse_path }}"
        version: "{{ lighthouse_branch }}"
        force: false
      when: lh_exists.state == "absent"
```

Корректировка одного из скриптов **Lighthouse** с целью замены стандартного адреса `127.0.0.1` на IP адрес хоста машины с **clickhouse**.
Используется модуль `ansible.builtin.replace`, который позволяет заменять части строк, удовлетворяющих регулярному выражению из `regexp:` на значением из `replace:`.
```yaml
    - name: Change lighthouse default host
      become: true
      ansible.builtin.replace:
        path: "{{ lighthouse_path }}/app.js"
        regexp: '127\.0\.0\.1'
        replace: "{{ groups['clickhouse'][0] }}"
```

Корректировка конфигурационного файла **nginx** с целью замены стандартного каталога `/usr/share/nginx/html` на директорию статики **Lighthouse**.
Используется модуль `ansible.builtin.replace`, который позволяет заменять части строк, удовлетворяющих регулярному выражению из `regexp:` на значением из `replace:`.
```yaml
    - name: Configure NGinX
      become: true
      ansible.builtin.replace:
        path: "/etc/nginx/nginx.conf"
        regexp: '/usr/share/nginx/html'
        replace: "{{ lighthouse_path }}"
      notify: Restart nginx
```

Корректировка конфигурационного файла **nginx** с целью возврата стандартного каталога `/usr/share/nginx/html`.
Этот шаг, является обратным для предыдущего и поэтому снабжен тегом `never`, который запрещает выполнять эту **task** если явно не указано обратное.
```yaml
    - name: Restore NGinX configuration
      become: true
      ansible.builtin.replace:
        path: "/etc/nginx/nginx.conf"
        regexp: "{{ lighthouse_path }}"
        replace: '/usr/share/nginx/html'
      tags:
        - never
```

Последний шаг - установка сервиса **nginx** на автозапуск при старте ОС.
Используется универсальный модуль `ansible.builtin.service`.
```yaml
    - name: Enable NGinX autostart
      become: true
      ansible.builtin.service:
        name: "nginx"
        enabled: true
        state: started
```

---

## Вывод IP адресов сервисов: `Echo instances hint`

**Play** предназначен для упрощения понимания какой сервис на каком IP располагается.
Состоит из трёх одинаковых **task**, использующих модуль `ansible.builtin.debug` для вывода части переменных известных групп

```yaml
    - name: Clickhouse IP
      ansible.builtin.debug:
        msg: "Clickhouse IP: {{ groups['clickhouse'][0] }}"
    - name: Vector IP
      ansible.builtin.debug:
        msg: "Vector IP    : {{ groups['vector'][0] }}"
    - name: Lighthouse IP
      ansible.builtin.debug:
        msg: "Clickhouse IP: {{ groups['lighthouse'][0] }}"
```